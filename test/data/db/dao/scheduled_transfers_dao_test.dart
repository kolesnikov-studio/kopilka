// Тесты DAO отложенных переводов (M7-шаг A, D-115/D-116): валидации
// create/update (D-17-суммы, пара комиссии), watchDue, идемпотентный
// markExecuted и запреты удаления D-115.г на счетах и категориях —
// по образцу debts_dao_test/budgets_dao_test.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;

  setUp(() {
    f = DataLayerFixture();
  });

  tearDown(() => f.dispose());

  Future<({Account card, Account cash})> accounts() async => (
    card: await f.seedAccount(name: 'Карта'),
    cash: await f.seedAccount(name: 'Наличные'),
  );

  Future<ScheduledTransfer> seedScheduled({
    String? accountId,
    String? targetAccountId,
    int amountMinor = 500000,
    int? targetAmountMinor,
    DateTime? executeAt,
    int? commissionMinor,
    String? commissionCategoryId,
  }) async {
    final ({Account card, Account cash}) a = await accounts();
    return f.scheduled.create(
      accountId: accountId ?? a.card.id,
      targetAccountId: targetAccountId ?? a.cash.id,
      amountMinor: amountMinor,
      targetAmountMinor: targetAmountMinor,
      executeAt: executeAt ?? DateTime.utc(2026, 10, 3),
      commissionMinor: commissionMinor,
      commissionCategoryId: commissionCategoryId,
    );
  }

  /// Категория расходов, живая — для комиссии.
  Future<Category> seedExpenseCategory() =>
      f.seedCategory(name: 'Комиссии', kind: CategoryKind.expense);

  group('create: валидации (D-115.г/D-116)', () {
    test(
      'перевод создаётся: суммы фиксируются, execute_at в TEXT UTC',
      () async {
        final ScheduledTransfer row = await seedScheduled();

        expect(row.id, 'sched-1');
        expect(row.amountMinor, 500000);
        expect(row.targetAmountMinor, isNull);
        expect(row.executeAt, '2026-10-03T00:00:00.000Z');
        expect(row.commissionMinor, isNull);
        expect(row.commissionCategoryId, isNull);
        expect(row.executedAt, isNull);
        expect(row.executedTransactionId, isNull);
        expect(row.deletedAt, isNull);
        expect(row.createdAt.toUtc(), f.clock.read());
      },
    );

    test('amountMinor <= 0 — отказ invalidInput', () async {
      for (final int amount in <int>[0, -1]) {
        await expectLater(
          seedScheduled(amountMinor: amount),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.invalidInput,
            ),
          ),
        );
      }
    });

    test('счёт списания и зачисления совпадают — отказ invalidInput', () async {
      final ({Account card, Account cash}) a = await accounts();
      await expectLater(
        f.scheduled.create(
          accountId: a.card.id,
          targetAccountId: a.card.id,
          amountMinor: 500000,
          executeAt: DateTime.utc(2026, 10, 3),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('неживой счёт — отказ notFound', () async {
      final ({Account card, Account cash}) a = await accounts();
      await expectLater(
        f.scheduled.create(
          accountId: 'нет-такого',
          targetAccountId: a.cash.id,
          amountMinor: 500000,
          executeAt: DateTime.utc(2026, 10, 3),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('execute_at не в UTC — отказ invalidInput (§3)', () async {
      await expectLater(
        seedScheduled(executeAt: DateTime(2026, 10, 3)),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });
  });

  group('правило D-17: суммы фиксируются при планировании', () {
    test('разные валюты без target — отказ; с target — ок', () async {
      await f.ensureRub();
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 79.375);
      final Account rub = await f.seedAccount(name: 'Карта');
      final Account usd = await f.seedAccount(name: 'USD', currencyCode: 'USD');

      await expectLater(
        f.scheduled.create(
          accountId: rub.id,
          targetAccountId: usd.id,
          amountMinor: 500000,
          executeAt: DateTime.utc(2026, 10, 3),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );

      final ScheduledTransfer row = await f.scheduled.create(
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 500000,
        targetAmountMinor: 6300,
        executeAt: DateTime.utc(2026, 10, 3),
      );
      expect(row.targetAmountMinor, 6300);
    });

    test('одна валюта с target_amount_minor — отказ (D-17)', () async {
      final ({Account card, Account cash}) a = await accounts();
      await expectLater(
        seedScheduled(
          accountId: a.card.id,
          targetAccountId: a.cash.id,
          targetAmountMinor: 500000,
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('target_amount_minor <= 0 у мультивалютного — отказ', () async {
      await f.ensureRub();
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 79.375);
      final Account rub = await f.seedAccount(name: 'Карта');
      final Account usd = await f.seedAccount(name: 'USD', currencyCode: 'USD');
      for (final int target in <int>[0, -5]) {
        await expectLater(
          f.scheduled.create(
            accountId: rub.id,
            targetAccountId: usd.id,
            amountMinor: 500000,
            targetAmountMinor: target,
            executeAt: DateTime.utc(2026, 10, 3),
          ),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.invalidInput,
            ),
          ),
        );
      }
    });
  });

  group('пара комиссии «обе или ни одной» (D-115.г)', () {
    test('комиссия создаётся парой: сумма и категория расходов', () async {
      final Category fees = await seedExpenseCategory();
      final ScheduledTransfer row = await seedScheduled(
        commissionMinor: 2500,
        commissionCategoryId: fees.id,
      );
      expect(row.commissionMinor, 2500);
      expect(row.commissionCategoryId, fees.id);
    });

    test('только сумма или только категория — отказ invalidInput', () async {
      final Category fees = await seedExpenseCategory();
      await expectLater(
        seedScheduled(commissionMinor: 2500),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      await expectLater(
        seedScheduled(commissionCategoryId: fees.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('отрицательная комиссия — отказ invalidInput', () async {
      final Category fees = await seedExpenseCategory();
      await expectLater(
        seedScheduled(commissionMinor: -1, commissionCategoryId: fees.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('неживая категория комиссии — отказ notFound', () async {
      final Category fees = await seedExpenseCategory();
      await f.categories.softDelete(fees.id);
      await expectLater(
        seedScheduled(commissionMinor: 2500, commissionCategoryId: fees.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('категория комиссии доходная — отказ invalidInput', () async {
      final Category salary = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );
      await expectLater(
        seedScheduled(commissionMinor: 2500, commissionCategoryId: salary.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });
  });

  group('watchAlive / watchDue и update', () {
    test(
      'watchAlive отдаёт живые по execute_at; soft delete скрывает',
      () async {
        final ScheduledTransfer late = await seedScheduled(
          executeAt: DateTime.utc(2026, 11, 1),
        );
        final ScheduledTransfer early = await seedScheduled(
          executeAt: DateTime.utc(2026, 10, 1),
        );
        final List<ScheduledTransfer> alive = await f.scheduled
            .watchAlive()
            .first;
        expect(alive.map((ScheduledTransfer r) => r.id), <String>[
          early.id,
          late.id,
        ]);

        await f.scheduled.softDelete(late.id);
        expect(
          (await f.scheduled.watchAlive().first).map(
            (ScheduledTransfer r) => r.id,
          ),
          <String>[early.id],
        );
        await expectLater(
          f.scheduled.requireAliveById(late.id),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.notFound,
            ),
          ),
        );
      },
    );

    test('watchDue: только неисполненные с execute_at <= now', () async {
      final ScheduledTransfer due = await seedScheduled(
        executeAt: DateTime.utc(2026, 10, 1),
      );
      final ScheduledTransfer nowExactly = await seedScheduled(
        executeAt: DateTime.utc(2026, 10, 5),
      );
      await seedScheduled(executeAt: DateTime.utc(2026, 10, 6));
      final ScheduledTransfer deleted = await seedScheduled(
        executeAt: DateTime.utc(2026, 9, 30),
      );
      await f.scheduled.softDelete(deleted.id);

      final List<ScheduledTransfer> rows = await f.scheduled
          .watchDue(now: DateTime.utc(2026, 10, 5))
          .first;
      expect(rows.map((ScheduledTransfer r) => r.id), <String>[
        due.id,
        nowExactly.id,
      ]);
    });

    test('update правит поля по итоговым валидациям (D-116)', () async {
      final ScheduledTransfer row = await seedScheduled();
      f.clock.advance(const Duration(minutes: 5));
      final ScheduledTransfer updated = await f.scheduled
          .updateScheduledTransfer(
            row.id,
            amountMinor: const Value<int>(700000),
            executeAt: Value<DateTime>(DateTime.utc(2026, 10, 10)),
          );
      expect(updated.amountMinor, 700000);
      expect(updated.executeAt, '2026-10-10T00:00:00.000Z');
      expect(updated.updatedAt.toUtc(), isNot(updated.createdAt.toUtc()));

      // Правка, нарушающая пару комиссии, — отказ.
      await expectLater(
        f.scheduled.updateScheduledTransfer(
          row.id,
          commissionMinor: const Value<int?>(100),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });
  });

  group('markExecuted: идемпотентная отметка (D-116/D-119)', () {
    Future<Transaction> seedTransfer() async {
      final ({Account card, Account cash}) a = await accounts();
      return f.transactions.create(
        type: TransactionType.transfer,
        accountId: a.card.id,
        targetAccountId: a.cash.id,
        amountMinor: 500000,
        date: DateTime.utc(2026, 10, 3),
      );
    }

    test(
      'отметка записывает executed_at и операцию; watchDue скрывает',
      () async {
        final ScheduledTransfer row = await seedScheduled();
        final Transaction transfer = await seedTransfer();

        await f.scheduled.markExecuted(
          row.id,
          transactionId: transfer.id,
          executedAt: f.clock.read(),
        );

        final ScheduledTransfer? executed = await f.scheduled.getById(row.id);
        expect(executed?.executedAt, f.clock.read().toIso8601String());
        expect(executed?.executedTransactionId, transfer.id);
        expect(
          await f.scheduled.watchDue(now: DateTime.utc(2026, 10, 5)).first,
          isEmpty,
        );
      },
    );

    test('повторная отметка — no-op (идемпотентность D-119)', () async {
      final ScheduledTransfer row = await seedScheduled();
      final Transaction transfer = await seedTransfer();
      await f.scheduled.markExecuted(
        row.id,
        transactionId: transfer.id,
        executedAt: f.clock.read(),
      );
      // Второй вызов не падает и не меняет отметку.
      await f.scheduled.markExecuted(
        row.id,
        transactionId: transfer.id,
        executedAt: DateTime.utc(2026, 10, 10),
      );
      final ScheduledTransfer? executed = await f.scheduled.getById(row.id);
      expect(executed?.executedAt, f.clock.read().toIso8601String());
    });

    test('отсутствующая операция — отказ notFound, отметки нет', () async {
      final ScheduledTransfer row = await seedScheduled();
      await expectLater(
        f.scheduled.markExecuted(
          row.id,
          transactionId: 'нет-такой',
          executedAt: f.clock.read(),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
      expect((await f.scheduled.getById(row.id))?.executedAt, isNull);
    });

    test('executedAt не в UTC — отказ invalidInput', () async {
      final ScheduledTransfer row = await seedScheduled();
      final Transaction transfer = await seedTransfer();
      await expectLater(
        f.scheduled.markExecuted(
          row.id,
          transactionId: transfer.id,
          executedAt: DateTime(2026, 10, 3),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('исполненный перевод не правится (D-119)', () async {
      final ScheduledTransfer row = await seedScheduled();
      final Transaction transfer = await seedTransfer();
      await f.scheduled.markExecuted(
        row.id,
        transactionId: transfer.id,
        executedAt: f.clock.read(),
      );
      await expectLater(
        f.scheduled.updateScheduledTransfer(
          row.id,
          amountMinor: const Value<int>(1),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });
  });

  group('запреты удаления D-115.г: счёт и категория комиссии', () {
    test(
      'счёт списания и зачисления с живым отложенным не удаляются',
      () async {
        final ScheduledTransfer row = await seedScheduled();
        final ScheduledTransfer? stored = await f.scheduled.getById(row.id);
        expect(stored, isNotNull);
        await expectLater(
          f.accounts.softDelete(stored!.accountId),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.accountHasScheduledTransfers,
            ),
          ),
        );
        await expectLater(
          f.accounts.softDelete(stored.targetAccountId),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.accountHasScheduledTransfers,
            ),
          ),
        );
      },
    );

    test(
      'исполненный и удалённый отложенный удалению счёта не мешают',
      () async {
        await f.ensureRub();
        final Account card = await f.seedAccount(name: 'Карта A');
        final Account cash = await f.seedAccount(name: 'Наличные A');
        final Account feeCard = await f.seedAccount(name: 'Карта B');
        final Account feeCash = await f.seedAccount(name: 'Наличные B');

        // Исполненный отложенный ссылается на пару A — она должна удалиться.
        final ScheduledTransfer executedRow = await f.scheduled.create(
          accountId: card.id,
          targetAccountId: cash.id,
          amountMinor: 500000,
          executeAt: DateTime.utc(2026, 10, 3),
        );
        final Transaction transfer = await f.transactions.create(
          type: TransactionType.transfer,
          accountId: feeCard.id,
          targetAccountId: feeCash.id,
          amountMinor: 500000,
          date: DateTime.utc(2026, 10, 3),
        );
        await f.scheduled.markExecuted(
          executedRow.id,
          transactionId: transfer.id,
          executedAt: f.clock.read(),
        );
        await f.accounts.softDelete(card.id);
        expect(await f.accounts.findById(card.id), isNull);

        // Мягко удалённый отложенный тоже не блокирует удаление счетов.
        final Account delCard = await f.seedAccount(name: 'Карта C');
        final Account delCash = await f.seedAccount(name: 'Наличные C');
        final ScheduledTransfer deletedRow = await f.scheduled.create(
          accountId: delCard.id,
          targetAccountId: delCash.id,
          amountMinor: 100,
          executeAt: DateTime.utc(2026, 10, 3),
        );
        await f.scheduled.softDelete(deletedRow.id);
        await f.accounts.softDelete(delCard.id);
        expect(await f.accounts.findById(delCard.id), isNull);
      },
    );

    test('категория комиссии с живым отложенным не удаляется', () async {
      final Category fees = await seedExpenseCategory();
      await seedScheduled(commissionMinor: 2500, commissionCategoryId: fees.id);
      await expectLater(
        f.categories.softDelete(fees.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.categoryHasScheduledTransfers,
          ),
        ),
      );
    });

    test(
      'скрытие системной категории комиссии с живым отложенным — отказ',
      () async {
        final Category fees = await f.categories.create(
          name: 'Комиссии системная',
          kind: CategoryKind.expense,
          isSystem: true,
        );
        await seedScheduled(
          commissionMinor: 2500,
          commissionCategoryId: fees.id,
        );
        await expectLater(
          f.categories.hide(fees.id),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.categoryHasScheduledTransfers,
            ),
          ),
        );
      },
    );

    test('исполненный отложенный категорию комиссии не блокирует', () async {
      final Category fees = await seedExpenseCategory();
      final ScheduledTransfer row = await seedScheduled(
        commissionMinor: 2500,
        commissionCategoryId: fees.id,
      );
      final ({Account card, Account cash}) a = await accounts();
      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: a.card.id,
        targetAccountId: a.cash.id,
        amountMinor: 500000,
        date: DateTime.utc(2026, 10, 3),
      );
      await f.scheduled.markExecuted(
        row.id,
        transactionId: transfer.id,
        executedAt: f.clock.read(),
      );
      await f.categories.softDelete(fees.id);
      expect(await f.categories.findById(fees.id), isNull);
    });
  });
}
