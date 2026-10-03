// Тесты исполнения отложенных переводов (M7-шаг B, D-119): in-memory
// drift-БД + фиксированные часы. Проверяются: создание перевода с суммами
// записи и датой execute_at, атомарность (сбой на второй строке откатывает
// первую), идемпотентность по executed_at, комиссия и «комиссия 0 — нет
// расхода» (D-123), заморозка суммы зачисления, отсев будущих и мягко
// удалённых строк, уведомление после успешной транзакции.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/scheduled/scheduled_transfers_service.dart';

import '../db/dao/dao_test_utils.dart';

void main() {
  late DataLayerFixture f;

  setUp(() async {
    f = DataLayerFixture();
    await f.ensureRub();
  });

  tearDown(() => f.dispose());

  ScheduledTransfersService buildService(List<ScheduledTransfer> notified) =>
      ScheduledTransfersService(
        db: f.db,
        scheduledDao: f.scheduled,
        transactionsDao: f.transactions,
        onExecuted: (ScheduledTransfer transfer) async {
          notified.add(transfer);
        },
        clock: f.clock.read,
      );

  test('исполнение: перевод с суммами записи, дата = execute_at, отметка '
      'и уведомление', () async {
    final Account source = await f.seedAccount(name: 'Основной');
    final Account target = await f.seedAccount(name: 'Копилка');
    final DateTime executeAt = DateTime.utc(2026, 9, 22, 12);
    final ScheduledTransfer row = await f.scheduled.create(
      accountId: source.id,
      targetAccountId: target.id,
      amountMinor: 5000,
      executeAt: executeAt,
    );
    final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
    final ScheduledTransfersService service = buildService(notified);

    await service.executeDue();

    final List<Transaction> transactions = await f.transactions.getFiltered();
    expect(transactions, hasLength(1));
    expect(
      TransactionType.fromDb(transactions.single.type),
      TransactionType.transfer,
    );
    expect(transactions.single.accountId, source.id);
    expect(transactions.single.targetAccountId, target.id);
    expect(transactions.single.amountMinor, 5000);
    // Дата операции — плановая (execute_at), не момент запуска (D-119).
    expect(transactions.single.date.toUtc(), executeAt);
    final ScheduledTransfer executed = (await f.scheduled.getById(row.id))!;
    expect(executed.executedAt, isNotNull);
    expect(executed.executedTransactionId, transactions.single.id);
    expect(notified.single.id, row.id);
  });

  test(
    'идемпотентность: повторный запуск — no-op (ни операций, ни показов)',
    () async {
      final Account source = await f.seedAccount(name: 'Основной');
      final Account target = await f.seedAccount(name: 'Копилка');
      await f.scheduled.create(
        accountId: source.id,
        targetAccountId: target.id,
        amountMinor: 1000,
        executeAt: DateTime.utc(2026, 9, 22, 12),
      );
      final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
      final ScheduledTransfersService service = buildService(notified);

      await service.executeDue();
      await service.executeDue();

      expect(await f.transactions.getFiltered(), hasLength(1));
      expect(notified, hasLength(1));
    },
  );

  test('будущая строка не исполняется', () async {
    final Account source = await f.seedAccount(name: 'Основной');
    final Account target = await f.seedAccount(name: 'Копилка');
    await f.scheduled.create(
      accountId: source.id,
      targetAccountId: target.id,
      amountMinor: 1000,
      // Часы фикстуры — 2026-09-25 12:00: строка заметно позже.
      executeAt: DateTime.utc(2026, 9, 26, 12),
    );
    final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
    final ScheduledTransfersService service = buildService(notified);

    await service.executeDue();

    expect(await f.transactions.getFiltered(), isEmpty);
    expect(notified, isEmpty);
  });

  test('мягко удалённая строка не исполняется', () async {
    final Account source = await f.seedAccount(name: 'Основной');
    final Account target = await f.seedAccount(name: 'Копилка');
    final ScheduledTransfer row = await f.scheduled.create(
      accountId: source.id,
      targetAccountId: target.id,
      amountMinor: 1000,
      executeAt: DateTime.utc(2026, 9, 22, 12),
    );
    await f.scheduled.softDelete(row.id);
    final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
    final ScheduledTransfersService service = buildService(notified);

    await service.executeDue();

    expect(await f.transactions.getFiltered(), isEmpty);
    expect(notified, isEmpty);
    expect((await f.scheduled.getById(row.id)), isNull);
  });

  group('комиссия (D-115.г/D-123)', () {
    test('расход комиссии — в категорию комиссии со счёта списания, '
        'дата = execute_at', () async {
      final Account source = await f.seedAccount(name: 'Основной');
      final Account target = await f.seedAccount(name: 'Копилка');
      final Category fees = await f.seedCategory(name: 'Комиссии');
      final DateTime executeAt = DateTime.utc(2026, 9, 22, 12);
      await f.scheduled.create(
        accountId: source.id,
        targetAccountId: target.id,
        amountMinor: 5000,
        executeAt: executeAt,
        commissionMinor: 250,
        commissionCategoryId: fees.id,
      );
      final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
      final ScheduledTransfersService service = buildService(notified);

      await service.executeDue();

      final List<Transaction> transactions = await f.transactions.getFiltered();
      expect(transactions, hasLength(2));
      final Transaction commission = transactions.firstWhere(
        (Transaction t) =>
            TransactionType.fromDb(t.type) == TransactionType.expense,
      );
      expect(commission.amountMinor, 250);
      expect(commission.accountId, source.id);
      expect(commission.categoryId, fees.id);
      expect(commission.date.toUtc(), executeAt);
    });

    test(
      'комиссия 0 = отсутствие комиссии: нулевого расхода нет (D-123)',
      () async {
        final Account source = await f.seedAccount(name: 'Основной');
        final Account target = await f.seedAccount(name: 'Копилка');
        final Category fees = await f.seedCategory(name: 'Комиссии');
        await f.scheduled.create(
          accountId: source.id,
          targetAccountId: target.id,
          amountMinor: 5000,
          executeAt: DateTime.utc(2026, 9, 22, 12),
          commissionMinor: 0,
          commissionCategoryId: fees.id,
        );
        final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
        final ScheduledTransfersService service = buildService(notified);

        await service.executeDue();

        final List<Transaction> transactions = await f.transactions
            .getFiltered();
        expect(transactions, hasLength(1));
        expect(
          TransactionType.fromDb(transactions.single.type),
          TransactionType.transfer,
        );
      },
    );
  });

  test('мультивалютный перевод: сумма зачисления заморожена при планировании '
      'и не пересчитывается', () async {
    await f.seedCurrency('USD', symbol: r'$', rateToBase: 2);
    final Account rub = await f.seedAccount(name: 'Рублёвый');
    final Account usd = await f.accounts.create(
      name: 'Долларовый',
      kind: AccountKind.card,
      currencyCode: 'USD',
    );
    await f.scheduled.create(
      accountId: rub.id,
      targetAccountId: usd.id,
      amountMinor: 10000,
      targetAmountMinor: 2000,
      executeAt: DateTime.utc(2026, 9, 22, 12),
    );
    // Курс изменился после планирования — суммы записи не пересчитываются.
    await f.currencies.updateCurrency(
      'USD',
      rateToBase: const Value<double>(3),
    );
    final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
    final ScheduledTransfersService service = buildService(notified);

    await service.executeDue();

    final Transaction transfer = (await f.transactions.getFiltered()).single;
    expect(transfer.amountMinor, 10000);
    expect(transfer.targetAmountMinor, 2000);
  });

  test('атомарность: сбой на второй строке откатывает первую — частичных '
      'данных нет', () async {
    final Account source = await f.seedAccount(name: 'Основной');
    final Account good = await f.seedAccount(name: 'Живая цель');
    final Account dead = await f.seedAccount(name: 'Удалённая цель');
    // Счёт мягко удалён до появления отложенных строк (позже DAO не даст):
    // строка на него исполниться не может — transactionsDao ответит отказом.
    await f.accounts.softDelete(dead.id);
    final ScheduledTransfer first = await f.scheduled.create(
      accountId: source.id,
      targetAccountId: good.id,
      amountMinor: 100,
      executeAt: DateTime.utc(2026, 9, 23, 12),
    );
    await f.db
        .into(f.db.scheduledTransfers)
        .insert(
          ScheduledTransfersCompanion.insert(
            id: 'sched-dead',
            accountId: source.id,
            targetAccountId: dead.id,
            amountMinor: 200,
            executeAt: DateTime.utc(2026, 9, 24, 12).toIso8601String(),
            createdAt: f.clock.read(),
            updatedAt: f.clock.read(),
          ),
        );
    final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
    final ScheduledTransfersService service = buildService(notified);

    await expectLater(
      service.executeDue(),
      throwsA(isA<DataValidationException>()),
    );

    // Откат: ни одной операции, ни одной отметки, ни одного показа.
    expect(await f.transactions.getFiltered(), isEmpty);
    expect((await f.scheduled.getById(first.id))!.executedAt, isNull);
    expect((await f.scheduled.getById('sched-dead'))!.executedAt, isNull);
    expect(notified, isEmpty);
  });

  group('краевые дедлайны executeDue (D-126)', () {
    test(
      'ровно 00:00 UTC дня execute_at исполняется, секунду раньше — нет',
      () async {
        final Account source = await f.seedAccount(name: 'Основной');
        final Account target = await f.seedAccount(name: 'Копилка');
        final DateTime executeAt = DateTime.utc(2026, 9, 26);
        final ScheduledTransfer row = await f.scheduled.create(
          accountId: source.id,
          targetAccountId: target.id,
          amountMinor: 1000,
          executeAt: executeAt,
        );
        final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
        final ScheduledTransfersService service = buildService(notified);

        // Часы фикстуры — 2026-09-25 12:00: уводим на секунду до дедлайна.
        f.clock.advance(
          executeAt
              .subtract(const Duration(seconds: 1))
              .difference(f.clock.read()),
        );
        await service.executeDue();
        expect(await f.transactions.getFiltered(), isEmpty);
        expect(notified, isEmpty);

        f.clock.advance(const Duration(seconds: 1)); // ровно полночь UTC
        await service.executeDue();
        final List<Transaction> transactions = await f.transactions
            .getFiltered();
        expect(transactions, hasLength(1));
        expect(transactions.single.date.toUtc(), executeAt);
        expect((await f.scheduled.getById(row.id))!.executedAt, isNotNull);
        expect(notified, hasLength(1));
      },
    );

    test(
      'границы месяца и года UTC: до границы — нет, ровно на границе — да',
      () async {
        final Account source = await f.seedAccount(name: 'Основной');
        final Account target = await f.seedAccount(name: 'Копилка');
        final DateTime monthEdge = DateTime.utc(2026, 10, 1);
        final DateTime yearEdge = DateTime.utc(2027, 1, 1);
        final ScheduledTransfer byMonth = await f.scheduled.create(
          accountId: source.id,
          targetAccountId: target.id,
          amountMinor: 1000,
          executeAt: monthEdge,
        );
        final ScheduledTransfer byYear = await f.scheduled.create(
          accountId: source.id,
          targetAccountId: target.id,
          amountMinor: 2000,
          executeAt: yearEdge,
        );
        final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
        final ScheduledTransfersService service = buildService(notified);

        // Последняя секунда сентября: октябрьская строка ещё не назрела.
        f.clock.advance(
          DateTime.utc(2026, 9, 30, 23, 59, 59).difference(f.clock.read()),
        );
        await service.executeDue();
        expect(await f.transactions.getFiltered(), isEmpty);

        f.clock.advance(const Duration(seconds: 1)); // 2026-10-01 00:00:00 UTC
        await service.executeDue();
        List<Transaction> transactions = await f.transactions.getFiltered();
        expect(transactions, hasLength(1));
        expect(transactions.single.date.toUtc(), monthEdge);
        expect((await f.scheduled.getById(byMonth.id))!.executedAt, isNotNull);
        expect((await f.scheduled.getById(byYear.id))!.executedAt, isNull);

        // Последняя секунда года: годовая строка ещё не назрела.
        f.clock.advance(
          DateTime.utc(2026, 12, 31, 23, 59, 59).difference(f.clock.read()),
        );
        await service.executeDue();
        expect(await f.transactions.getFiltered(), hasLength(1));

        f.clock.advance(const Duration(seconds: 1)); // 2027-01-01 00:00:00 UTC
        await service.executeDue();
        transactions = await f.transactions.getFiltered();
        expect(transactions, hasLength(2));
        expect(
          transactions.map((Transaction t) => t.date.toUtc()).toSet(),
          <DateTime>{monthEdge, yearEdge},
        );
        expect((await f.scheduled.getById(byYear.id))!.executedAt, isNotNull);
        expect(notified, hasLength(2));
      },
    );

    test('пачка в один запуск: даты операций = execute_at у всех, комиссия — '
        'ровно один расход, повтор без дублей', () async {
      final Account source = await f.seedAccount(name: 'Основной');
      final Account target = await f.seedAccount(name: 'Копилка');
      final Category fees = await f.seedCategory(name: 'Комиссии');
      final DateTime firstAt = DateTime.utc(2026, 9, 20, 9);
      final DateTime commissionAt = DateTime.utc(2026, 9, 23, 8, 30);
      final DateTime thirdAt = DateTime.utc(2026, 9, 24, 23, 59, 59);
      final ScheduledTransfer first = await f.scheduled.create(
        accountId: source.id,
        targetAccountId: target.id,
        amountMinor: 1000,
        executeAt: firstAt,
      );
      final ScheduledTransfer withCommission = await f.scheduled.create(
        accountId: source.id,
        targetAccountId: target.id,
        amountMinor: 2000,
        executeAt: commissionAt,
        commissionMinor: 150,
        commissionCategoryId: fees.id,
      );
      final ScheduledTransfer third = await f.scheduled.create(
        accountId: source.id,
        targetAccountId: target.id,
        amountMinor: 3000,
        executeAt: thirdAt,
      );
      final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
      final ScheduledTransfersService service = buildService(notified);

      await service.executeDue();

      // 3 перевода + ровно один расход комиссии.
      final List<Transaction> transactions = await f.transactions.getFiltered();
      expect(transactions, hasLength(4));
      expect(
        transactions
            .where(
              (Transaction t) =>
                  TransactionType.fromDb(t.type) == TransactionType.transfer,
            )
            .map((Transaction t) => t.date.toUtc())
            .toSet(),
        <DateTime>{firstAt, commissionAt, thirdAt},
      );
      final Transaction commission = transactions.singleWhere(
        (Transaction t) =>
            TransactionType.fromDb(t.type) == TransactionType.expense,
      );
      expect(commission.amountMinor, 150);
      expect(commission.categoryId, fees.id);
      expect(commission.date.toUtc(), commissionAt);
      expect(notified.map((ScheduledTransfer t) => t.id).toList(), <String>[
        first.id,
        withCommission.id,
        third.id,
      ]);

      // Идемпотентность повтора: дублей операций и показов нет.
      await service.executeDue();
      expect(await f.transactions.getFiltered(), hasLength(4));
      expect(notified, hasLength(3));
      for (final ScheduledTransfer row in <ScheduledTransfer>[
        first,
        withCommission,
        third,
      ]) {
        expect((await f.scheduled.getById(row.id))!.executedAt, isNotNull);
      }
    });

    test(
      'два одновременных прохода executeDue — без дублей операций',
      () async {
        final Account source = await f.seedAccount(name: 'Основной');
        final Account target = await f.seedAccount(name: 'Копилка');
        for (final int amount in <int>[1000, 2000]) {
          await f.scheduled.create(
            accountId: source.id,
            targetAccountId: target.id,
            amountMinor: amount,
            executeAt: DateTime.utc(2026, 9, 22, 12),
          );
        }
        final ScheduledTransfersService service = buildService(
          <ScheduledTransfer>[],
        );

        // Binding гоняет проход по каждому событию потока — пересечённые
        // вызовы обязаны сойтись к одной операции на строку (D-119).
        await Future.wait(<Future<void>>[
          service.executeDue(),
          service.executeDue(),
        ]);

        expect(await f.transactions.getFiltered(), hasLength(2));
      },
    );
  });
}
