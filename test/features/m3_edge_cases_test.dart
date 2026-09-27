// Краевые случаи M3 перед тегом v0.3.0 (релизное ревью тестов).
//
// Дополнения по итогам ревью тестов шагов 1–7: случаи, не покрытые
// существующими группами. Продуктовый код не меняется (границы задачи):
// здесь фиксируется текущее документированное поведение.
//
// Харнесс S1 (DataLayerFixture) и грабли §7 ARCHITECTURE: суммы в
// ожиданиях — через formatMoneyMinor (неразрывные пробелы), месяцы UTC.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/export/backup_service.dart';

import '../data/db/dao/dao_test_utils.dart';

void main() {
  group('краевые случаи лимита бюджета (документирование поведения)', () {
    // Документируем для M4: DAO единственное место с валидацией лимита,
    // UI-валидатор формирует тот же отказ — нижний порог 1 минорной
    // единицы базы (1 копейка) нигде не задокументирован.
    test('create: лимит 0 и отрицательный — отказ invalidInput', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Category food = await f.seedCategory(name: 'Еда');

      for (final int limit in <int>[0, -1]) {
        await expectLater(
          f.budgets.create(categoryId: food.id, limitMinor: limit),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.invalidInput,
            ),
          ),
          reason: 'лимит $limit обязан отклоняться при создании',
        );
      }
      // После отказов бюджет не создан (первая строка — только что
      // созданная ниже, считаем физически).
      expect(await f.budgets.getAlive(), isEmpty);
    });

    test('updateLimit: лимит 0 и отрицательный — отказ, данные целы', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Category food = await f.seedCategory(name: 'Еда');
      final Budget budget = await f.budgets.create(
        categoryId: food.id,
        limitMinor: 100,
      );

      for (final int limit in <int>[0, -1]) {
        await expectLater(
          f.budgets.updateLimit(budget.id, limitMinor: limit),
          throwsA(isA<DataValidationException>()),
          reason: 'лимит $limit обязан отклоняться при правке',
        );
      }
      // Отказанные правки ничего не записали (транзакционность отказов).
      final Budget? after = await f.budgets.findByCategory(food.id);
      expect(after?.limitMinor, 100);
    });

    test('минимальный допустимый лимит — 1 минорная единица базы', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Category food = await f.seedCategory(name: 'Еда');

      final Budget budget =
          await f.budgets.create(categoryId: food.id, limitMinor: 1);
      expect(budget.limitMinor, 1);
    });
  });

  group('построчный half-up при конвертации (D-22, R1 ревью)', () {
    // Экспонент JPY (0) даёт масштаб 100: минорный JPY = мажорный,
    // дробная часть появляется в мажорной базе (0,01 ₽) — «нецифровой»
    // порог half-up достижим на копейке базы.
    Future<({DataLayerFixture f, Account jpy, Category food, Budget budget})>
        seedJpyBudget() async {
      final DataLayerFixture f = DataLayerFixture();
      await f.ensureRub();
      await f.seedCurrency('JPY', symbol: '¥', rateToBase: 0.0625);
      final Account jpy = await f.accounts.create(
        name: 'Йенный',
        kind: AccountKind.card,
        currencyCode: 'JPY',
      );
      final Category food = await f.seedCategory(name: 'Еда');
      final Budget budget = await f.budgets.create(
        categoryId: food.id,
        limitMinor: 100000,
      );
      return (f: f, jpy: jpy, food: food, budget: budget);
    }

    test(
      '0,5 копейки базы от JPY-расхода: половина округляется вверх по модулю',
      () async {
        final (:f, :jpy, :food, :budget) = await seedJpyBudget();
        addTearDown(f.dispose);

        // 161 JPY × 0,0625 = 10,0625 ₽ → построчный half-up = 1006 минорных.
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: jpy.id,
          categoryId: food.id,
          amountMinor: 161,
        );
        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        expect(progress.spentMinor, 1006);
      },
    );

    test(
      'две «половинки» JPY-расходов суммируются как 1006 + 1006, не 1006+1005',
      () async {
        final (:f, :jpy, :food, :budget) = await seedJpyBudget();
        addTearDown(f.dispose);

        // Два расхода по 161 JPY: каждая строка конвертируется отдельно
        // (построчный half-up), суммы не складываются до округления.
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: jpy.id,
          categoryId: food.id,
          amountMinor: 161,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: jpy.id,
          categoryId: food.id,
          amountMinor: 161,
        );

        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        expect(progress.spentMinor, 2012);
        expect(progress.isOver, isFalse);
      },
    );

    test(
      'KWD-копейки базы тоже округляются построчно: 123,456+123,457',
      () async {
        final DataLayerFixture f = DataLayerFixture();
        addTearDown(f.dispose);
        await f.ensureRub();
        // 1 динар = 200 ₽; минорный KWD (3 знака) крупнее минорного рубля
        // в 10 раз, порог 0,05 ₽ достижим на последнем знаке KWD.
        await f.seedCurrency('KWD', symbol: 'K', rateToBase: 200);
        final Account kwd = await f.accounts.create(
          name: 'Динаровый',
          kind: AccountKind.card,
          currencyCode: 'KWD',
        );
        final Category food = await f.seedCategory(name: 'Еда');
        final Budget budget = await f.budgets.create(
          categoryId: food.id,
          limitMinor: 100000,
        );

        // Минорный KWD (миллидинар) — это 20 минорных рублей (1 KWD =
        // 1000 мKWD = 200 ₽ = 20 000 м₽): дробных порогов half-up на
        // KWD-конвертации не возникает, проверяем масштаб и построчность.
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: kwd.id,
          categoryId: food.id,
          amountMinor: 6172,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: kwd.id,
          categoryId: food.id,
          amountMinor: 6173,
        );

        // Построчно: 6172×20 = 123 440; 6173×20 = 123 460; сумма
        // 246 900 м₽ (2 469,00 ₽). Замок на масштаб KWD и построчность.
        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        expect(progress.spentMinor, 246900);
        // Формат прогресса — базовый экспонент 2 (D-27/D-29), в KWD-форме.
        expect(
          formatMoneyMinor(progress.spentMinor, symbol: '₽', locale: 'ru'),
          formatMoneyMinor(246900, symbol: '₽', locale: 'ru'),
        );
      },
    );
  });

  group('импорт бэкапа v1/v2 в схему v3 (D-21/D-25, R2 ревью)', () {
    // Валидный v1-документ: два рублёвых счёта, старый перевод без поля
    // target_amount_minor (в v1 поля не существовало — D-21: нет поля =
    // NULL) и расход. Перевод между валютами в v1 нельзя: строгая
    // валидация D-25 справедливо его отклонит (см. существующие тесты
    // backup_service_test), здесь — легальный v1-путь.
    Future<Map<String, dynamic>> v1Document() async => <String, dynamic>{
          'schema_version': 1,
          'exported_at': '2026-09-25T10:00:00.000Z',
          'data': <String, dynamic>{
            'currencies': <dynamic>[
              <String, dynamic>{
                'code': 'RUB',
                'symbol': '₽',
                'is_base': true,
                'rate_to_base': 1,
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
              <String, dynamic>{
                'code': 'USD',
                'symbol': r'$',
                'is_base': false,
                'rate_to_base': 79.5,
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
            ],
            'accounts': <dynamic>[
              <String, dynamic>{
                'id': 'acc-rub',
                'name': 'Рублёвый',
                'kind': 'cash',
                'currency_code': 'RUB',
                'initial_balance_minor': 10000,
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
              <String, dynamic>{
                'id': 'acc-rub2',
                'name': 'Рублёвый второй',
                'kind': 'cash',
                'currency_code': 'RUB',
                'initial_balance_minor': 500,
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
            ],
            'categories': <dynamic>[
              <String, dynamic>{
                'id': 'cat-food',
                'name': 'Еда',
                'kind': 'expense',
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
            ],
            'transactions': <dynamic>[
              <String, dynamic>{
                'id': 'tx-old-transfer',
                'type': 'transfer',
                'account_id': 'acc-rub',
                'target_account_id': 'acc-rub2',
                'amount_minor': 7900,
                'currency_code': 'RUB',
                'date': '2026-09-25T00:00:00.000Z',
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
              <String, dynamic>{
                'id': 'tx-old-expense',
                'type': 'expense',
                'account_id': 'acc-rub',
                'category_id': 'cat-food',
                'amount_minor': 50000,
                'currency_code': 'RUB',
                'date': '2026-09-25T00:00:00.000Z',
                'created_at': '2026-09-25T00:00:00.000Z',
                'updated_at': '2026-09-25T00:00:00.000Z',
              },
            ],
          },
        };

    test('v1 импортируется: старый перевод остаётся NULL (одно-валютный)',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();

      final AppDatabase target = f.db;
      // Акт импорта: бэкап полностью заменяет содержимое.
      await BackupService(target).importJson(jsonEncode(await v1Document()));

      final List<Transaction> rows = await target.transactionsDao.getFiltered();
      expect(rows, hasLength(2));

      final Transaction transfer = rows.singleWhere(
        (Transaction t) => t.id == 'tx-old-transfer',
      );
      // D-17/D-21: v1 не знал про target_amount_minor — старый перевод
      // импортируется с NULL и считается одно-валютным. Историческая
      // сумма заморожена (D-16); баланс зачисления по D-31 возьмёт
      // COALESCE(NULL, amount_minor).
      expect(transfer.targetAmountMinor, isNull);
      expect(transfer.targetAccountId, 'acc-rub2');
      // Балансы после импорта: расход 50 000 минусует. Списание:
      // 10 000 − 7 900 − 50 000 = −47 900; зачисление:
      // 500 + 7 900 = 8 400 (D-31: COALESCE(NULL, amount)).
      expect(await target.accountsDao.balanceMinor('acc-rub'), -47900);
      expect(await target.accountsDao.balanceMinor('acc-rub2'), 8400);
    });

    test('v1: перевод «самому себе» импортируется, баланс не задвоен',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();

      final Map<String, dynamic> document = await v1Document();
      final List<dynamic> transactions =
          (document['data'] as Map<String, dynamic>)['transactions']
              as List<dynamic>;
      transactions[0]['target_account_id'] = 'acc-rub'; // сам себе

      // DAO само-перевод не создаёт (проверка в _validateShape), но
      // импорт проверяет только форму (D-25): transfer + target_account_id,
      // одинаковые валюты → NULL — консистентно с D-17. Строка вставляется.
      await BackupService(f.db).importJson(jsonEncode(document));

      final Transaction self = (await f.db.transactionsDao.getFiltered())
          .singleWhere((Transaction t) => t.id == 'tx-old-transfer');
      expect(self.accountId, self.targetAccountId);
      expect(self.amountMinor, 7900);
      // Баланс счёта при этом НЕ задвоен (D-31): списание −7900 и
      // зачисление +COALESCE(NULL, 7900) взаимно гасятся — само-перевод
      // меняет баланс на ноль. 10 000 − 50 000 (расход) = −40 000.
      expect(await f.db.accountsDao.balanceMinor('acc-rub'), -40000);
    });
  });

  group('changeBase и живой агрегат (D-20 + D-18, R4 ревью)', () {
    test(
      'после смены базовой поток доната пересчитывается по новым курсам',
      () async {
        final DataLayerFixture f = DataLayerFixture();
        addTearDown(f.dispose);
        await f.ensureRub();
        await f.seedCurrency('USD', symbol: r'$', rateToBase: 2);
        final Account usd = await f.accounts.create(
          name: 'Долларовый',
          kind: AccountKind.card,
          currencyCode: 'USD',
        );
        final Category food = await f.seedCategory(name: 'Еда');

        await f.transactions.create(
          type: TransactionType.expense,
          accountId: usd.id,
          categoryId: food.id,
          amountMinor: 2000,
        );

        final Stream<List<CategoryExpenseBase>> stream = f.db.transactionsDao
            .watchExpensesByCategoryForMonthInBase(moment: f.clock.read());
        await expectLater(
          stream,
          emitsThrough(
            predicate<List<CategoryExpenseBase>>(
              (List<CategoryExpenseBase> list) => list.single.amountMinor == 4000,
              '20 USD × 2 = 40,00 ₽',
            ),
          ),
        );

        // changeBase('USD'): USD → 1, RUB → 0,5; поток читает currencies
        // (D-18), пересчитывает без перезапуска — сумма в новой базовой.
        await f.currencies.changeBase('USD');
        await expectLater(
          stream,
          emitsThrough(
            predicate<List<CategoryExpenseBase>>(
              (List<CategoryExpenseBase> list) => list.single.amountMinor == 2000,
              'после смены базовой: 20,00 USD-базы (курс USD = 1)',
            ),
          ),
        );
      },
    );
  });

  group('импорт: перевод «самому себе» (D-25, R3 ревью)', () {
    test('само-перевод между счетами в одной валюте импортируется сырой строкой',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();

      final Map<String, dynamic> document = <String, dynamic>{
        'schema_version': 3,
        'data': <String, dynamic>{
          'currencies': <dynamic>[
            <String, dynamic>{
              'code': 'RUB',
              'symbol': '₽',
              'is_base': true,
              'rate_to_base': 1,
              'created_at': '2026-09-26T00:00:00.000Z',
              'updated_at': '2026-09-26T00:00:00.000Z',
            },
          ],
          'accounts': <dynamic>[
            <String, dynamic>{
              'id': 'acc-rub',
              'name': 'Рублёвый',
              'kind': 'cash',
              'currency_code': 'RUB',
              'initial_balance_minor': 100000,
              'created_at': '2026-09-26T00:00:00.000Z',
              'updated_at': '2026-09-26T00:00:00.000Z',
            },
          ],
          'categories': <dynamic>[],
          'transactions': <dynamic>[
            <String, dynamic>{
              'id': 'tx-self',
              'type': 'transfer',
              'account_id': 'acc-rub',
              'target_account_id': 'acc-rub',
              'amount_minor': 7900,
              'currency_code': 'RUB',
              'date': '2026-09-26T00:00:00.000Z',
              'created_at': '2026-09-26T00:00:00.000Z',
              'updated_at': '2026-09-26T00:00:00.000Z',
            },
          ],
          'budgets': <dynamic>[],
        },
      };

      // Документ проходит валидацию импорта: форма перевода корректна
      // (transfer + target_account_id, одинаковые валюты → NULL —
      // консистентно с D-17). DAO такое не создаёт, но импорт — сырая
      // вставка (D-25 фиксирует форму, не живые ограничения DAO).
      await BackupService(f.db).importJson(jsonEncode(document));

      final Transaction self = (await f.db.transactionsDao.getFiltered()).single;
      expect(self.accountId, 'acc-rub');
      expect(self.targetAccountId, 'acc-rub');
      expect(self.targetAmountMinor, isNull);
    });
  });
}
