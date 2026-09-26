// Тесты DAO бюджетов (M2, D-14): валидация создания, единственность на
// категорию, soft delete, прогресс месяца одним SQL-агрегатом и поток
// прогресса. drift импортируется с hide isNotNull/isNull — конфликт
// с матчерами flutter_test; даты сравниваются через toUtc.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
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

    test('бюджет на доходную категорию — отказ budgetCategoryInvalid',
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
    });

    test('второй бюджет на ту же категорию — отказ budgetAlreadyExists',
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
    });

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
    test('мягко удалённый бюджет исчезает из живых, категория освобождается',
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
    });

    test('несуществующий бюджет: update/softDelete — отказ notFound',
        () async {
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
    test('считает только живые расходы категории за месяц, без переводов',
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
      final String targetId =
          (await f.accounts.create(name: 'Вторая', kind: AccountKind.card, currencyCode: 'RUB'))
              .id;
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
    });

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

    test('расход без категории и удалённая категория не роняют агрегат',
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
    });
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
      expect((await stream.first).map((BudgetProgress p) => p.budget.id),
          containsAll(<String>[keptBudget.id, deadBudget.id]));

      await f.budgets.softDelete(deadBudget.id);
      List<BudgetProgress> visible = await stream.first;
      expect(visible.map((BudgetProgress p) => p.budget.id), <String>[keptBudget.id]);

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
}
