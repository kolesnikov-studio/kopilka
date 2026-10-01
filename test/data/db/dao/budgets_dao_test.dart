// Тесты DAO бюджетов (M2, D-14): валидация создания, единственность на
// категорию, soft delete, прогресс месяца одним SQL-агрегатом и поток
// прогресса. drift импортируется с hide isNotNull/isNull — конфликт
// с матчерами flutter_test; даты сравниваются через toUtc.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

import 'package:kopilka/data/db/dao/budgets_dao.dart';

void main() {
  late DataLayerFixture f;

  setUp(() {
    f = DataLayerFixture();
  });

  tearDown(() => f.dispose());

  group('создание', () {
    test('бюджет создаётся на категорию расходов', () async {
      final Category category = await f.seedCategory(name: 'Еда');
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 2000000,
      );

      expect(budget.id, 'bud-1');
      expect(budget.categoryId, category.id);
      expect(budget.limitMinor, 2000000);
      expect(budget.deletedAt, isNull);
      expect(budget.createdAt.toUtc(), f.clock.read());
      expect(budget.updatedAt.toUtc(), f.clock.read());
    });

    test('лимит ноль или отрицательный — отказ invalidInput', () async {
      final Category category = await f.seedCategory();
      for (final int limit in <int>[0, -1]) {
        await expectLater(
          f.budgets.create(categoryId: category.id, limitMinor: limit),
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

    test('несуществующая категория — отказ notFound', () async {
      await expectLater(
        f.budgets.create(categoryId: 'nope', limitMinor: 100),
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
      'бюджет на доходную категорию — отказ budgetCategoryInvalid',
      () async {
        final Category income = await f.seedCategory(
          name: 'Зарплата',
          kind: CategoryKind.income,
        );
        await expectLater(
          f.budgets.create(categoryId: income.id, limitMinor: 100),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.budgetCategoryInvalid,
            ),
          ),
        );
      },
    );

    test(
      'второй бюджет на ту же категорию — отказ budgetAlreadyExists',
      () async {
        final Category category = await f.seedCategory();
        await f.budgets.create(categoryId: category.id, limitMinor: 100);
        await expectLater(
          f.budgets.create(categoryId: category.id, limitMinor: 200),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.budgetAlreadyExists,
            ),
          ),
        );
      },
    );

    test('бюджет на мягко удалённую категорию — отказ notFound', () async {
      final Category category = await f.seedCategory();
      await f.categories.softDelete(category.id);
      await expectLater(
        f.budgets.create(categoryId: category.id, limitMinor: 100),
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

  group('чтение и удаление', () {
    test(
      'мягко удалённый бюджет исчезает из живых, категория освобождается',
      () async {
        final Category category = await f.seedCategory();
        final Budget budget = await f.budgets.create(
          categoryId: category.id,
          limitMinor: 100,
        );
        expect(await f.budgets.getAlive(), hasLength(1));

        f.clock.advance(const Duration(hours: 1));
        await f.budgets.softDelete(budget.id);

        expect(await f.budgets.getAlive(), isEmpty);
        expect(await f.budgets.findByCategory(category.id), isNull);
        // Физически строка осталась (soft delete, §3).
        expect(await rawRowCount(f.db, 'budgets'), 1);
        // Категория снова принимает бюджет: старый мягко удалён.
        final Budget recreated = await f.budgets.create(
          categoryId: category.id,
          limitMinor: 500,
        );
        expect(recreated.id, 'bud-2');
      },
    );

    test('несуществующий бюджет: update/softDelete — отказ notFound', () async {
      await expectLater(
        f.budgets.updateLimit('nope', limitMinor: 100),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
      await expectLater(
        f.budgets.softDelete('nope'),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('updateLimit меняет лимит и updatedAt', () async {
      final Category category = await f.seedCategory();
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 100,
      );
      f.clock.advance(const Duration(hours: 2));

      final Budget updated = await f.budgets.updateLimit(
        budget.id,
        limitMinor: 777,
      );
      expect(updated.limitMinor, 777);
      expect(updated.updatedAt.toUtc(), f.clock.read());
      expect(updated.createdAt.toUtc(), budget.createdAt.toUtc());

      await expectLater(
        f.budgets.updateLimit(budget.id, limitMinor: 0),
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

  group('прогресс месяца', () {
    test('границы месяца: первая секунда попадает в свой месяц (P3)', () async {
      final Account account = await f.seedAccount();
      final Category category = await f.seedCategory();
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 1000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 555,
        // Ровно 00:00:00 первого дня месяца (UTC, §3).
        date: DateTime.utc(2026, 9, 1),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 666,
        date: DateTime.utc(2026, 8, 31, 23, 59, 59),
      );

      final BudgetProgress progress = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 9, 15),
      );
      expect(progress.spentMinor, 555);
      expect(progress.isOver, isFalse);

      final BudgetProgress august = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 8, 20),
      );
      expect(august.spentMinor, 666);
    });

    test('границы месяца: последняя секунда (23:59:59) остаётся в своём месяце (P3)', () async {
      final Account account = await f.seedAccount();
      final Category category = await f.seedCategory();
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 1000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 777,
        date: DateTime.utc(2026, 9, 30, 23, 59, 59),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 888,
        date: DateTime.utc(2026, 10, 1),
      );

      final BudgetProgress september = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 9, 30, 23, 59, 59),
      );
      expect(september.spentMinor, 777);

      final BudgetProgress october = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 10, 5),
      );
      expect(october.spentMinor, 888);
    });

    test(
      'считает только живые расходы категории за месяц, без переводов',
      () async {
        final Account account = await f.seedAccount();
        final Category groceries = await f.seedCategory(name: 'Продукты');
        final Category other = await f.seedCategory(name: 'Транспорт');
        final Category incomeCat = await f.seedCategory(
          name: 'Зарплата',
          kind: CategoryKind.income,
        );
        final Budget budget = await f.budgets.create(
          categoryId: groceries.id,
          limitMinor: 100000,
        );

        // Расходы бюджета: внутри месяца.
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: account.id,
          categoryId: groceries.id,
          amountMinor: 30000,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: account.id,
          categoryId: groceries.id,
          amountMinor: 2500,
        );
        // Чужая категория, доход, перевод: в прогресс не попадают.
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: account.id,
          categoryId: other.id,
          amountMinor: 999999,
        );
        await f.transactions.create(
          type: TransactionType.income,
          accountId: account.id,
          categoryId: incomeCat.id,
          amountMinor: 500000,
        );
        final String targetId = (await f.accounts.create(
          name: 'Вторая',
          kind: AccountKind.card,
          currencyCode: 'RUB',
        )).id;
        await f.transactions.create(
          type: TransactionType.transfer,
          accountId: account.id,
          targetAccountId: targetId,
          amountMinor: 123456,
        );
        // Мягко удалённый расход бюджета — не считается.
        final Transaction deleted = await f.transactions.create(
          type: TransactionType.expense,
          accountId: account.id,
          categoryId: groceries.id,
          amountMinor: 10000,
        );
        await f.transactions.softDelete(deleted.id);

        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        expect(progress.spentMinor, 32500);
        expect(progress.limitMinor, 100000);
        expect(progress.isOver, isFalse);
        expect(progress.ratio, closeTo(0.325, 1e-9));
      },
    );

    test('операции соседних месяцев не смешиваются', () async {
      final Account account = await f.seedAccount();
      final Category category = await f.seedCategory();
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 1000,
      );

      // Прошлый месяц (TestClock: 2026-09-25 UTC) и следующий.
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 100,
        date: DateTime.utc(2026, 8, 20),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 300,
        date: DateTime.utc(2026, 10, 2),
      );

      final BudgetProgress september = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 9, 15),
      );
      expect(september.spentMinor, 0);

      final BudgetProgress august = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 8, 20),
      );
      expect(august.spentMinor, 100);

      final BudgetProgress october = await f.budgets.progressOf(
        budget,
        moment: DateTime.utc(2026, 10, 5),
      );
      expect(october.spentMinor, 300);
    });

    test('категория без операций: прогресс нулевой, не NULL', () async {
      final Category category = await f.seedCategory();
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 1000,
      );
      final BudgetProgress progress = await f.budgets.progressOf(
        budget,
        moment: f.clock.read(),
      );
      expect(progress.spentMinor, 0);
      expect(progress.ratio, 0);
    });

    test(
      'расход без категории и удалённая категория не роняют агрегат',
      () async {
        final Account account = await f.seedAccount();
        final Category category = await f.seedCategory();
        await f.budgets.create(categoryId: category.id, limitMinor: 1000);
        // Расход вообще без категории (для бюджета не важен, но не должен
        // ломать GROUP BY).
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: account.id,
          amountMinor: 500,
        );
        final List<BudgetProgress> progress = await f.budgets
            .watchProgress(moment: f.clock.read())
            .first;
        expect(progress.single.spentMinor, 0);
      },
    );
  });

  group('поток прогресса', () {
    test('обновляется при изменении операций и лимита', () async {
      final Account account = await f.seedAccount();
      final Category category = await f.seedCategory();
      final Budget budget = await f.budgets.create(
        categoryId: category.id,
        limitMinor: 1000,
      );

      final Stream<List<BudgetProgress>> stream = f.budgets.watchProgress(
        moment: f.clock.read(),
      );
      expect(await stream.first, hasLength(1));
      expect((await stream.first).single.spentMinor, 0);

      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 1500,
      );
      final List<BudgetProgress> afterSpend = await stream.first;
      expect(afterSpend.single.spentMinor, 1500);
      expect(afterSpend.single.isOver, isTrue);
      expect(afterSpend.single.budget.id, budget.id);
    });

    test('мягко удалённые бюджеты и категории исчезают из потока', () async {
      final Account account = await f.seedAccount();
      final Category kept = await f.seedCategory(name: 'Живой');
      final Category removed = await f.seedCategory(name: 'Мёртвый');
      final Budget keptBudget = await f.budgets.create(
        categoryId: kept.id,
        limitMinor: 100,
      );
      final Budget deadBudget = await f.budgets.create(
        categoryId: removed.id,
        limitMinor: 200,
      );
      final Stream<List<BudgetProgress>> stream = f.budgets.watchProgress(
        moment: f.clock.read(),
      );
      expect(
        (await stream.first).map((BudgetProgress p) => p.budget.id),
        containsAll(<String>[keptBudget.id, deadBudget.id]),
      );

      await f.budgets.softDelete(deadBudget.id);
      List<BudgetProgress> visible = await stream.first;
      expect(visible.map((BudgetProgress p) => p.budget.id), <String>[
        keptBudget.id,
      ]);

      // Категорию с живым бюджетом DAO удалить не даёт.
      await expectLater(
        f.categories.softDelete(kept.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.categoryHasBudget,
          ),
        ),
      );
      // Операция появляется — запрет остаётся на месте, прогресс живёт.
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: kept.id,
        amountMinor: 10,
      );
      visible = await stream.first;
      expect(visible.single.spentMinor, 10);
    });
  });

  group('прогресс в базовой валюте (M3-шаг 6, D-18/D-19)', () {
    test(
      'смешанные расходы: построчная конвертация RUB, USD и JPY в базовую',
      () async {
        final DataLayerFixture f = DataLayerFixture();
        addTearDown(f.dispose);
        await f.ensureRub();
        // Курсы — степени двойки: произведение точно в double, проверяется
        // правило построчного half-up, а не хвосты float (как в шаге 5).
        await f.seedCurrency('USD', symbol: r'$', rateToBase: 2);
        await f.seedCurrency('JPY', symbol: '¥', rateToBase: 0.0625);
        final Account rub = await f.seedAccount(name: 'Рублёвый');
        final Account usd = await f.accounts.create(
          name: 'Долларовый',
          kind: AccountKind.card,
          currencyCode: 'USD',
        );
        final Account jpy = await f.accounts.create(
          name: 'Йенный',
          kind: AccountKind.card,
          currencyCode: 'JPY',
        );
        final Category food = await f.seedCategory(name: 'Еда');
        final Budget budget = await f.budgets.create(
          categoryId: food.id,
          limitMinor: 15000,
        );

        // RUB 100,00 → 10000; USD 20,00 × курс 2 → 4000; JPY 320
        // (экспонент 0) → 320 × 0,0625 = 20,00 → 2000. Итого 16000.
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: rub.id,
          categoryId: food.id,
          amountMinor: 10000,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: usd.id,
          categoryId: food.id,
          amountMinor: 2000,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: jpy.id,
          categoryId: food.id,
          amountMinor: 320,
        );

        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        expect(progress.spentMinor, 16000);
        // Лимит не конвертируется (D-19): он уже в минорных единицах базовой,
        // сравнение идёт с конвертированной суммой расходов.
        expect(progress.limitMinor, 15000);
        expect(progress.isOver, isTrue);

        // progressOf и watchProgress согласованы (одна семантика сумм).
        final List<BudgetProgress> watched = await f.budgets
            .watchProgress(moment: f.clock.read())
            .first;
        expect(watched.single.budget.id, budget.id);
        expect(watched.single.spentMinor, 16000);
      },
    );

    test(
      'смена курса пересчитывает прогресс без перезапуска (watch, D-18)',
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
        await f.budgets.create(categoryId: food.id, limitMinor: 10000);

        final Stream<List<BudgetProgress>> stream = f.budgets.watchProgress(
          moment: f.clock.read(),
        );

        await f.transactions.create(
          type: TransactionType.expense,
          accountId: usd.id,
          categoryId: food.id,
          amountMinor: 2000,
        );
        await expectLater(
          stream,
          emitsThrough(
            predicate<List<BudgetProgress>>(
              (List<BudgetProgress> list) => list.single.spentMinor == 4000,
              '40,00 ₽ по курсу 2',
            ),
          ),
        );

        // readsFrom включает currencies: поток пересчитывается сам (D-18),
        // без кэша и перезапуска.
        await f.currencies.updateCurrency(
          'USD',
          rateToBase: const Value<double>(4),
        );
        await expectLater(
          stream,
          emitsThrough(
            predicate<List<BudgetProgress>>(
              (List<BudgetProgress> list) => list.single.spentMinor == 8000,
              '80,00 ₽ по курсу 4 без перезапуска',
            ),
          ),
        );
      },
    );

    test(
      'операция с валютой без строки справочника — курс 1, не выпадает',
      () async {
        final DataLayerFixture f = DataLayerFixture();
        addTearDown(f.dispose);
        await f.ensureRub();
        final Account account = await f.seedAccount();
        final Category food = await f.seedCategory(name: 'Еда');
        final Budget budget = await f.budgets.create(
          categoryId: food.id,
          limitMinor: 100000,
        );

        // Несогласованный импорт: операция ссылается на валюту, которой нет
        // в справочнике. DAO такое не создаёт (FK) — вставляем сырой строкой.
        final int epoch = f.clock.read().millisecondsSinceEpoch ~/ 1000;
        await f.db.customStatement('PRAGMA foreign_keys = OFF');
        await f.db.customInsert(
          'INSERT INTO transactions (id, type, account_id, category_id, '
          'amount_minor, target_amount_minor, currency_code, date, note, '
          'created_at, updated_at, deleted_at) '
          'VALUES (?, ?, ?, ?, ?, NULL, ?, ?, NULL, ?, ?, NULL)',
          variables: <Variable>[
            Variable<String>('tx-x'),
            Variable<String>(TransactionType.expense.dbValue),
            Variable<String>(account.id),
            Variable<String>(food.id),
            Variable<int>(12345),
            Variable<String>('XXX'),
            Variable<int>(epoch),
            Variable<int>(epoch),
            Variable<int>(epoch),
          ],
        );
        await f.db.customStatement('PRAGMA foreign_keys = ON');

        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        // COALESCE(rate, 1.0): сумма остаётся без конвертации, операция
        // не выпадает из прогресса (как в шаге 5).
        expect(progress.spentMinor, 12345);
      },
    );

    test(
      'экспоненты JPY и KWD: ожидания через formatMoneyMinor (D-27)',
      () async {
        final DataLayerFixture f = DataLayerFixture();
        addTearDown(f.dispose);
        await f.ensureRub();
        await f.seedCurrency('JPY', symbol: '¥', rateToBase: 0.0625);
        // 1 динар = 200 ₽: минорный KWD крупнее минорного рубля в 10 раз.
        await f.seedCurrency('KWD', symbol: 'K', rateToBase: 200);
        final Account jpy = await f.accounts.create(
          name: 'Йенный',
          kind: AccountKind.card,
          currencyCode: 'JPY',
        );
        final Account kwd = await f.accounts.create(
          name: 'Динаровый',
          kind: AccountKind.card,
          currencyCode: 'KWD',
        );
        final Category food = await f.seedCategory(name: 'Еда');
        final Budget budget = await f.budgets.create(
          categoryId: food.id,
          limitMinor: 300000,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: jpy.id,
          categoryId: food.id,
          amountMinor: 320,
        );
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: kwd.id,
          categoryId: food.id,
          amountMinor: 12345,
        );

        final BudgetProgress progress = await f.budgets.progressOf(
          budget,
          moment: f.clock.read(),
        );
        // JPY 320 → 2000; KWD 12345 → 123,45 динара × 200 = 246900; итого
        // 248900. База — экспонент 2 (D-27): сумма показывается как рублёвая
        // с копейками независимо от экспонентов валют-источников.
        String money(int minor) =>
            formatMoneyMinor(minor, symbol: '₽', locale: 'ru');
        expect(money(progress.spentMinor), money(248900));
        expect(progress.isOver, isFalse);
      },
    );
  });
}
