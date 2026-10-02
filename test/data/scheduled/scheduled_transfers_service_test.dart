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

  ScheduledTransfersService buildService(
    List<ScheduledTransfer> notified,
  ) => ScheduledTransfersService(
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

  test('идемпотентность: повторный запуск — no-op (ни операций, ни показов)',
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
  });

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

    test('комиссия 0 = отсутствие комиссии: нулевого расхода нет (D-123)',
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

      final List<Transaction> transactions = await f.transactions.getFiltered();
      expect(transactions, hasLength(1));
      expect(
        TransactionType.fromDb(transactions.single.type),
        TransactionType.transfer,
      );
    });
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
}
