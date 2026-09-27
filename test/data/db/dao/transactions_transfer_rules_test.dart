// Тесты правил переводов D-17 (M3-шаг 1): вторая сумма перевода.
//
// Дерево правил (D-17):
// - валюты живых счетов перевода различаются ⇔ обе суммы обязательны
//   (target_amount_minor не NULL) и правятся только вместе;
// - валюты совпадают (и любой не-перевод) ⇔ target_amount_minor обязана
//   быть NULL;
// - отказы — DataValidationException с машиночитаемым kind.
//
// Дополнение TransactionView (шаг 1): коды валют обоих счётов.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;
  late Account rubCash;
  late Account rubCard;
  late Account usdCash;

  setUp(() async {
    f = DataLayerFixture();
    await f.ensureRub();
    await f.seedCurrency('USD', symbol: r'$', rateToBase: 79.5);
    rubCash = await f.seedAccount(name: 'Рублевые наличные');
    rubCard = await f.seedAccount(
      name: 'Рублевая карта',
      kind: AccountKind.card,
    );
    usdCash = await f.seedAccount(
      name: 'Долларовые наличные',
      currencyCode: 'USD',
    );
  });

  tearDown(() async {
    await f.dispose();
  });

  group('create (D-17)', () {
    test('перевод в одной валюте: target_amount_minor обязана быть NULL',
        () async {
      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: rubCard.id,
        amountMinor: 1000,
      );
      expect(transfer.targetAmountMinor, isNull);
      expect(transfer.currencyCode, 'RUB');

      // Передача значения при одинаковых валютах — отказ.
      await expectLater(
        f.transactions.create(
          type: TransactionType.transfer,
          accountId: rubCash.id,
          targetAccountId: rubCard.id,
          amountMinor: 1000,
          targetAmountMinor: 900,
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

    test('перевод между валютами: обе суммы обязательны', () async {
      await expectLater(
        f.transactions.create(
          type: TransactionType.transfer,
          accountId: rubCash.id,
          targetAccountId: usdCash.id,
          amountMinor: 7900,
          // targetAmountMinor не задана — отказ.
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );

      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: usdCash.id,
        amountMinor: 7900,
        targetAmountMinor: 100,
      );
      expect(transfer.amountMinor, 7900);
      expect(transfer.targetAmountMinor, 100);
      // Валюта операции — валюта счёта списания; валюта зачисления —
      // валюта целевого счёта (в view, см. ниже).
      expect(transfer.currencyCode, 'RUB');
      expect(transfer.targetAccountId, usdCash.id);
    });

    test('мультивалютный перевод: неположительная сумма зачисления — отказ',
        () async {
      await expectLater(
        f.transactions.create(
          type: TransactionType.transfer,
          accountId: rubCash.id,
          targetAccountId: usdCash.id,
          amountMinor: 7900,
          targetAmountMinor: 0,
        ),
        throwsA(isA<DataValidationException>()),
      );
      await expectLater(
        f.transactions.create(
          type: TransactionType.transfer,
          accountId: rubCash.id,
          targetAccountId: usdCash.id,
          amountMinor: 7900,
          targetAmountMinor: -5,
        ),
        throwsA(isA<DataValidationException>()),
      );
    });

    test('не-перевод с суммой зачисления — отказ', () async {
      await expectLater(
        f.transactions.create(
          type: TransactionType.expense,
          accountId: rubCash.id,
          amountMinor: 100,
          targetAmountMinor: 50,
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      await expectLater(
        f.transactions.create(
          type: TransactionType.income,
          accountId: rubCash.id,
          amountMinor: 100,
          targetAmountMinor: 50,
        ),
        throwsA(isA<DataValidationException>()),
      );
    });
  });

  group('updateTransaction (D-17)', () {
    test('мультивалютный перевод: суммы правятся только вместе', () async {
      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: usdCash.id,
        amountMinor: 7900,
        targetAmountMinor: 100,
      );

      // Правка только amount — отказ.
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          amountMinor: const Value<int>(8000),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );

      // Правка только targetAmount — отказ (в т.ч. на NULL).
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          targetAmountMinor: const Value<int?>(110),
        ),
        throwsA(isA<DataValidationException>()),
      );
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          targetAmountMinor: const Value<int?>(null),
        ),
        throwsA(isA<DataValidationException>()),
      );

      // Обе суммы вместе — успех; отказанные правки ничего не записали.
      final Transaction both = await f.transactions.updateTransaction(
        transfer.id,
        amountMinor: const Value<int>(8000),
        targetAmountMinor: const Value<int?>(102),
      );
      expect(both.amountMinor, 8000);
      expect(both.targetAmountMinor, 102);
    });

    test('одно-валютный перевод: target_amount_minor обязана остаться NULL',
        () async {
      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: rubCard.id,
        amountMinor: 1000,
      );

      // Появление суммы зачисления — отказ.
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          targetAmountMinor: const Value<int?>(100),
        ),
        throwsA(isA<DataValidationException>()),
      );

      // amount правится один раз — допустимо (валюты совпадают).
      final Transaction amountOnly = await f.transactions.updateTransaction(
        transfer.id,
        amountMinor: const Value<int>(2000),
      );
      expect(amountOnly.amountMinor, 2000);
      expect(amountOnly.targetAmountMinor, isNull);
    });

    test('мультивалютный перевод нельзя сделать одно-валютным одной правкой',
        () async {
      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: usdCash.id,
        amountMinor: 7900,
        targetAmountMinor: 100,
      );

      // Обнуление target без amount — отказ: у мультивалютного перевода
      // суммы правятся только вместе.
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          targetAmountMinor: const Value<int?>(null),
        ),
        throwsA(isA<DataValidationException>()),
      );

      // Одна amount без target — тоже отказ.
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          amountMinor: const Value<int>(8000),
        ),
        throwsA(isA<DataValidationException>()),
      );
    });

    test('не-переводу сумму зачисления поставить нельзя', () async {
      final Transaction expense = await f.transactions.create(
        type: TransactionType.expense,
        accountId: rubCash.id,
        amountMinor: 100,
      );
      await expectLater(
        f.transactions.updateTransaction(
          expense.id,
          targetAmountMinor: const Value<int?>(50),
        ),
        throwsA(isA<DataValidationException>()),
      );
    });

    test('неположительная сумма в паре — отказ, прежние данные целы',
        () async {
      final Transaction transfer = await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: usdCash.id,
        amountMinor: 7900,
        targetAmountMinor: 100,
      );
      await expectLater(
        f.transactions.updateTransaction(
          transfer.id,
          amountMinor: const Value<int>(8000),
          targetAmountMinor: const Value<int?>(0),
        ),
        throwsA(isA<DataValidationException>()),
      );
      final Transaction? raw = await f.transactions.findById(transfer.id);
      expect(raw?.amountMinor, 7900, reason: 'отказ не записал amount');
      expect(raw?.targetAmountMinor, 100, reason: 'отказ не записал target');
    });
  });

  group('TransactionView: валюты обоих счётов', () {
    test('перевод несёт коды валют списания и зачисления', () async {
      await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rubCash.id,
        targetAccountId: usdCash.id,
        amountMinor: 7900,
        targetAmountMinor: 100,
      );

      final TransactionView row =
          await f.transactions.watchFilteredView().first.then(
                (List<TransactionView> rows) => rows.single,
              );
      expect(row.accountCurrencyCode, 'RUB');
      expect(row.targetCurrencyCode, 'USD');
      expect(row.transaction.targetAmountMinor, 100);
    });

    test('у не-перевода целевая валюта null', () async {
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: rubCash.id,
        amountMinor: 100,
      );

      final TransactionView row =
          await f.transactions.watchFilteredView().first.then(
                (List<TransactionView> rows) => rows.single,
              );
      expect(row.accountCurrencyCode, 'RUB');
      expect(row.targetCurrencyCode, isNull);
      expect(row.targetAccountName, isNull);
    });
  });
}
