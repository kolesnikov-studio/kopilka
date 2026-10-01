// Тесты DAO долгов (M6-шаг A, D-82): валидации create/update, отказы
// requireAliveById, soft delete без каскадов, платежи и сводка одним
// SQL-агрегатом — по образцу attachments_dao_test/budgets_dao_test.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;

  setUp(() {
    f = DataLayerFixture();
  });

  tearDown(() => f.dispose());

  Future<Debt> seedDebt({
    String person = 'Алексей',
    DebtDirection direction = DebtDirection.theyOweMe,
    int amountMinor = 500000,
    int extraMinor = 0,
    String? currencyCode,
    DateTime? dueDate,
    String? note,
  }) async {
    await f.ensureRub();
    return f.debts.create(
      person: person,
      direction: direction,
      amountMinor: amountMinor,
      extraMinor: extraMinor,
      currencyCode: currencyCode ?? 'RUB',
      dueDate: dueDate,
      note: note,
    );
  }

  group('create: валидации (D-82)', () {
    test('долг создаётся, поля дословно, штампы по часам', () async {
      final Debt debt = await seedDebt(
        extraMinor: 25000,
        dueDate: DateTime.utc(2026, 11, 1),
        note: '  под расписку  ',
      );

      expect(debt.person, 'Алексей');
      expect(debt.direction, 'they_owe_me');
      expect(debt.amountMinor, 500000);
      expect(debt.extraMinor, 25000);
      expect(debt.currencyCode, 'RUB');
      expect(debt.dueDate, '2026-11-01T00:00:00.000Z');
      expect(debt.note, 'под расписку');
      expect(debt.deletedAt, isNull);
      expect(debt.createdAt.toUtc(), f.clock.read());
    });

    test('пустое person (и из одних пробелов) — отказ invalidInput', () async {
      for (final String person in <String>['', '   ']) {
        await expectLater(
          seedDebt(person: person),
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

    test('amount_minor <= 0 — отказ invalidInput', () async {
      for (final int amount in <int>[0, -1]) {
        await expectLater(
          seedDebt(amountMinor: amount),
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

    test('extra_minor < 0 — отказ invalidInput', () async {
      await expectLater(
        seedDebt(extraMinor: -1),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('неизвестная валюта — отказ invalidInput', () async {
      await expectLater(
        seedDebt(currencyCode: 'XYZ'),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('оба направления валидны и хранятся каноническими строками', () async {
      final Debt they = await seedDebt();
      final Debt me = await seedDebt(
        person: 'Мария',
        direction: DebtDirection.iOweThem,
      );
      expect(they.direction, 'they_owe_me');
      expect(me.direction, 'i_owe_them');
    });
  });

  group('update: валидации и точечная правка', () {
    test('правит только переданные поля, updatedAt обновляется', () async {
      final Debt debt = await seedDebt(note: 'заметка');
      f.clock.advance(const Duration(hours: 1));

      final Debt updated = await f.debts.updateDebt(
        debt.id,
        extraMinor: const Value(10000),
        note: const Value<String?>(null),
      );

      expect(updated.person, 'Алексей');
      expect(updated.amountMinor, 500000);
      expect(updated.extraMinor, 10000);
      expect(updated.note, isNull);
      expect(updated.updatedAt.toUtc(), f.clock.read());
    });

    test(
      'пустое person, суммы и валюта — те же отказы, что в create',
      () async {
        final Debt debt = await seedDebt();

        await expectLater(
          f.debts.updateDebt(debt.id, person: const Value('  ')),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.invalidInput,
            ),
          ),
        );
        await expectLater(
          f.debts.updateDebt(debt.id, amountMinor: const Value(0)),
          throwsA(isA<DataValidationException>()),
        );
        await expectLater(
          f.debts.updateDebt(debt.id, extraMinor: const Value(-5)),
          throwsA(isA<DataValidationException>()),
        );
        await expectLater(
          f.debts.updateDebt(debt.id, currencyCode: const Value('XYZ')),
          throwsA(isA<DataValidationException>()),
        );
      },
    );

    test('мягко удалённый долг не правится — notFound', () async {
      final Debt debt = await seedDebt();
      await f.debts.softDelete(debt.id);

      await expectLater(
        f.debts.updateDebt(debt.id, person: const Value('Кто-то')),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });
  });

  group('чтение и мягкое удаление', () {
    test(
      'findById — только живые, requireAliveById — отказ notFound',
      () async {
        final Debt debt = await seedDebt();

        expect((await f.debts.findById(debt.id))?.id, debt.id);
        expect((await f.debts.requireAliveById(debt.id)).id, debt.id);
        await f.debts.softDelete(debt.id);
        expect(await f.debts.findById(debt.id), isNull);
        await expectLater(
          f.debts.requireAliveById(debt.id),
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

    test(
      'watchAlive отдаёт живые, мягкое удаление убирает из потока',
      () async {
        final Debt first = await seedDebt(person: 'А');
        final Debt second = await seedDebt(person: 'Б');

        final List<Debt> alive = await f.debts.watchAlive().first;
        expect(
          alive.map((Debt d) => d.id),
          containsAll(<String>[first.id, second.id]),
        );

        await f.debts.softDelete(first.id);
        final List<Debt> after = await f.debts.watchAlive().first;
        expect(after.map((Debt d) => d.id), contains(second.id));
        expect(after.map((Debt d) => d.id), isNot(contains(first.id)));
        // Строка осталась физически (§3).
        expect(await rawRowCount(f.db, 'debts'), 2);
      },
    );

    test('повторный softDelete — notFound (_requireAlive)', () async {
      final Debt debt = await seedDebt();
      await f.debts.softDelete(debt.id);

      await expectLater(
        f.debts.softDelete(debt.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test(
      'мягкое удаление долга не трогает платежи (без каскада, §3)',
      () async {
        final Debt debt = await seedDebt();
        await f.debts.addPayment(
          debt.id,
          amountMinor: 100,
          paidAt: f.clock.read(),
        );
        await f.debts.softDelete(debt.id);

        expect(await rawRowCount(f.db, 'debt_payments'), 1);
      },
    );
  });

  group('платежи (D-82)', () {
    test('платёж создаётся на живой долг, с переводом и без', () async {
      final Debt debt = await seedDebt();
      await f.seedAccount();
      final Transaction tx = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: (await f.accounts.getAlive()).first.id,
        targetAccountId: (await f.accounts.create(
          name: 'Второй',
          kind: AccountKind.cash,
          currencyCode: 'RUB',
        )).id,
        amountMinor: 100000,
      );

      final DebtPayment linked = await f.debts.addPayment(
        debt.id,
        transactionId: tx.id,
        amountMinor: 100000,
        paidAt: DateTime.utc(2026, 10, 2),
      );
      final DebtPayment unlinked = await f.debts.addPayment(
        debt.id,
        amountMinor: 50000,
        paidAt: DateTime.utc(2026, 10, 3),
      );

      expect(linked.transactionId, tx.id);
      expect(linked.amountMinor, 100000);
      expect(unlinked.transactionId, isNull);
      expect(unlinked.paidAt, '2026-10-03T00:00:00.000Z');
    });

    test('платёж на мягко удалённый долг — notFound', () async {
      final Debt debt = await seedDebt();
      await f.debts.softDelete(debt.id);

      await expectLater(
        f.debts.addPayment(debt.id, amountMinor: 100, paidAt: f.clock.read()),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('сумма <= 0 — отказ invalidInput; битый перевод — notFound', () async {
      final Debt debt = await seedDebt();

      await expectLater(
        f.debts.addPayment(debt.id, amountMinor: 0, paidAt: f.clock.read()),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      await expectLater(
        f.debts.addPayment(
          debt.id,
          transactionId: 'tx-нет-такой',
          amountMinor: 100,
          paidAt: f.clock.read(),
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

    test('watchPayments отдаёт живые платежи долга, свежие сверху', () async {
      final Debt debt = await seedDebt();
      final DebtPayment first = await f.debts.addPayment(
        debt.id,
        amountMinor: 100,
        paidAt: DateTime.utc(2026, 10, 1),
      );
      final DebtPayment second = await f.debts.addPayment(
        debt.id,
        amountMinor: 200,
        paidAt: DateTime.utc(2026, 10, 2),
      );
      // Чужой долг не подмешивается.
      final Debt other = await seedDebt(person: 'Мария');
      await f.debts.addPayment(
        other.id,
        amountMinor: 5,
        paidAt: f.clock.read(),
      );

      final List<DebtPayment> payments = await f.debts
          .watchPayments(debt.id)
          .first;
      expect(payments.map((DebtPayment p) => p.id), <String>[
        second.id,
        first.id,
      ]);

      await f.debts.softDeletePayment(second.id);
      final List<DebtPayment> alive = await f.debts
          .watchPayments(debt.id)
          .first;
      expect(alive.map((DebtPayment p) => p.id), <String>[first.id]);
      // Строка осталась физически (§3).
      expect(await rawRowCount(f.db, 'debt_payments'), 3);
    });

    test('softDeletePayment: повторный и чужой id — notFound', () async {
      final Debt debt = await seedDebt();
      final DebtPayment payment = await f.debts.addPayment(
        debt.id,
        amountMinor: 100,
        paidAt: f.clock.read(),
      );
      await f.debts.softDeletePayment(payment.id);

      await expectLater(
        f.debts.softDeletePayment(payment.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
      await expectLater(
        f.debts.softDeletePayment('nope'),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });
  });

  group('сводка (D-82): одним SQL-агрегатом', () {
    test(
      'к возврату = тело + переплата, погашено = SUM живых, остаток',
      () async {
        final Debt debt = await seedDebt(
          amountMinor: 500000,
          extraMinor: 25000,
        );
        await f.debts.addPayment(
          debt.id,
          amountMinor: 200000,
          paidAt: f.clock.read(),
        );
        f.clock.advance(const Duration(minutes: 1));
        await f.debts.addPayment(
          debt.id,
          amountMinor: 125000,
          paidAt: f.clock.read(),
        );

        final DebtSummary? summary = await f.debts.watchSummary(debt.id).first;
        expect(summary, isNotNull);
        expect(summary!.totalMinor, 525000);
        expect(summary.paidMinor, 325000);
        expect(summary.remainingMinor, 200000);
      },
    );

    test(
      'мягко удалённый платёж выпадает из SUM, долг не ломается (D-25)',
      () async {
        final Debt debt = await seedDebt(amountMinor: 100000);
        final DebtPayment payment = await f.debts.addPayment(
          debt.id,
          amountMinor: 40000,
          paidAt: f.clock.read(),
        );
        await f.debts.softDeletePayment(payment.id);

        final DebtSummary? summary = await f.debts.watchSummary(debt.id).first;
        expect(summary!.paidMinor, 0);
        expect(summary.remainingMinor, 100000);
      },
    );

    test(
      'мягкое удаление долга убирает его из потока (watchSummary → NULL)',
      () async {
        final Debt debt = await seedDebt();
        expect(await f.debts.watchSummary(debt.id).first, isNotNull);
        await f.debts.softDelete(debt.id);
        expect(await f.debts.watchSummary(debt.id).first, isNull);
      },
    );

    test('поток живёт: новый платёж пересчитывает сводку', () async {
      final Debt debt = await seedDebt(amountMinor: 100000);
      final Stream<DebtSummary?> summaryStream = f.debts.watchSummary(debt.id);

      expect((await summaryStream.first)!.paidMinor, 0);
      await f.debts.addPayment(
        debt.id,
        amountMinor: 30000,
        paidAt: f.clock.read(),
      );
      final DebtSummary? after = await summaryStream.first;
      expect(after!.paidMinor, 30000);
      expect(after.remainingMinor, 70000);
    });
  });
}
