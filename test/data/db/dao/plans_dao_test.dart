// Тесты DAO планов (M7-шаг A, D-115/D-116): валидации create/update,
// правило «пересекающиеся живые планы одной категории невозможны», soft
// delete без каскадов, watchAlive и план-факт одним SQL-запросом
// с построчной конвертацией в базовую — по образцу budgets_dao_test.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;

  setUp(() {
    f = DataLayerFixture();
  });

  tearDown(() => f.dispose());

  Future<Category> seedExpenseCategory() =>
      f.seedCategory(name: 'Продукты', kind: CategoryKind.expense);

  Future<Plan> seedPlan({
    required String categoryId,
    int amountMinor = 4000000,
    DateTime? periodStart,
    DateTime? periodEnd,
  }) => f.plans.create(
    categoryId: categoryId,
    periodStart: periodStart ?? DateTime.utc(2026, 10, 1),
    periodEnd: periodEnd ?? DateTime.utc(2026, 11, 1),
    amountMinor: amountMinor,
  );

  group('create: валидации (D-115/D-116)', () {
    test('план создаётся: период в TEXT UTC, сумма, штампы по часам', () async {
      final Category food = await seedExpenseCategory();
      final Plan plan = await seedPlan(categoryId: food.id);

      expect(plan.id, 'plan-1');
      expect(plan.categoryId, food.id);
      expect(plan.periodStart, '2026-10-01T00:00:00.000Z');
      expect(plan.periodEnd, '2026-11-01T00:00:00.000Z');
      expect(plan.amountMinor, 4000000);
      expect(plan.deletedAt, isNull);
      expect(plan.createdAt.toUtc(), f.clock.read());
      expect(plan.updatedAt.toUtc(), f.clock.read());
    });

    test('amountMinor <= 0 — отказ invalidInput', () async {
      final Category food = await seedExpenseCategory();
      for (final int amount in <int>[0, -1]) {
        await expectLater(
          seedPlan(categoryId: food.id, amountMinor: amount),
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

    test('end <= start — отказ invalidInput', () async {
      final Category food = await seedExpenseCategory();
      for (final (DateTime start, DateTime end) in <(DateTime, DateTime)>[
        (DateTime.utc(2026, 10, 1), DateTime.utc(2026, 10, 1)),
        (DateTime.utc(2026, 10, 1), DateTime.utc(2026, 9, 30)),
      ]) {
        await expectLater(
          seedPlan(categoryId: food.id, periodStart: start, periodEnd: end),
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

    test('даты не в UTC — отказ invalidInput (§3, D-115.а)', () async {
      final Category food = await seedExpenseCategory();
      await expectLater(
        seedPlan(categoryId: food.id, periodStart: DateTime(2026, 10, 1)),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      await expectLater(
        seedPlan(categoryId: food.id, periodEnd: DateTime(2026, 11, 1)),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });

    test('неживая категория — отказ notFound', () async {
      final Category food = await seedExpenseCategory();
      await f.categories.softDelete(food.id);
      await expectLater(
        seedPlan(categoryId: food.id),
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
      'доходная категория допустима: направление — производная D-115.а',
      () async {
        final Category salary = await f.seedCategory(
          name: 'Зарплата',
          kind: CategoryKind.income,
        );
        final Plan plan = await seedPlan(categoryId: salary.id);
        expect(plan.categoryId, salary.id);
      },
    );
  });

  group('пересечение живых планов одной категории (D-115.в)', () {
    test('пересекающиеся периоды — отказ invalidInput', () async {
      final Category food = await seedExpenseCategory();
      await seedPlan(categoryId: food.id);
      await expectLater(
        seedPlan(
          categoryId: food.id,
          periodStart: DateTime.utc(2026, 10, 15),
          periodEnd: DateTime.utc(2026, 11, 15),
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

    test(
      'касание границами не пересечение: [a, b) и [b, c) свободны',
      () async {
        final Category food = await seedExpenseCategory();
        await seedPlan(categoryId: food.id);
        final Plan second = await seedPlan(
          categoryId: food.id,
          periodStart: DateTime.utc(2026, 11, 1),
          periodEnd: DateTime.utc(2026, 12, 1),
        );
        expect(second.periodStart, '2026-11-01T00:00:00.000Z');
      },
    );

    test('разные категории свободны', () async {
      final Category food = await seedExpenseCategory();
      final Category fun = await f.seedCategory(name: 'Развлечения');
      await seedPlan(categoryId: food.id);
      final Plan plan = await seedPlan(categoryId: fun.id);
      expect(plan.categoryId, fun.id);
    });

    test('мягко удалённый план период не занимает', () async {
      final Category food = await seedExpenseCategory();
      final Plan first = await seedPlan(categoryId: food.id);
      await f.plans.softDelete(first.id);
      final Plan second = await seedPlan(categoryId: food.id);
      expect(second.id, 'plan-2');
    });
  });

  group('updatePlan и softDelete', () {
    test('правка суммы и периода; пересечение с чужаком — отказ', () async {
      final Category food = await seedExpenseCategory();
      final Category fun = await f.seedCategory(name: 'Развлечения');
      final Plan plan = await seedPlan(categoryId: food.id);
      await seedPlan(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 11, 1),
        periodEnd: DateTime.utc(2026, 12, 1),
      );
      await seedPlan(categoryId: fun.id);
      f.clock.advance(const Duration(minutes: 5));

      final Plan updated = await f.plans.updatePlan(
        plan.id,
        amountMinor: const Value<int>(5000000),
        periodStart: Value<DateTime>(DateTime.utc(2026, 10, 5)),
        periodEnd: Value<DateTime>(DateTime.utc(2026, 10, 20)),
      );
      expect(updated.amountMinor, 5000000);
      expect(updated.periodStart, '2026-10-05T00:00:00.000Z');
      expect(updated.updatedAt.toUtc(), isNot(updated.createdAt.toUtc()));

      // Правка того же плана не «пересекается сама с собой».
      final Plan same = await f.plans.updatePlan(
        plan.id,
        periodEnd: Value<DateTime>(DateTime.utc(2026, 10, 25)),
      );
      expect(same.periodEnd, '2026-10-25T00:00:00.000Z');

      // Расширение в чужой период — отказ.
      await expectLater(
        f.plans.updatePlan(
          plan.id,
          periodEnd: Value<DateTime>(DateTime.utc(2026, 11, 10)),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );

      // Смена категории с пересечением в новой категории — тоже отказ.
      await expectLater(
        f.plans.updatePlan(plan.id, categoryId: Value<String>(fun.id)),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      expect((await f.plans.getById(plan.id))!.categoryId, food.id);
    });

    test('soft delete: строка остаётся, живой не читается', () async {
      final Category food = await seedExpenseCategory();
      final Plan plan = await seedPlan(categoryId: food.id);
      await f.plans.softDelete(plan.id);

      expect(await f.plans.getById(plan.id), isNull);
      expect(await f.plans.watchAlive().first, isEmpty);
      expect(await rawRowCount(f.db, 'plans'), 1);
      await expectLater(
        f.plans.requireAliveById(plan.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('watchAlive отдаёт живые планы по началу периода', () async {
      final Category food = await seedExpenseCategory();
      final Plan late = await seedPlan(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 11, 1),
        periodEnd: DateTime.utc(2026, 12, 1),
      );
      final Plan early = await seedPlan(categoryId: food.id);
      final List<Plan> alive = await f.plans.watchAlive().first;
      expect(alive.map((Plan p) => p.id), <String>[early.id, late.id]);
    });
  });

  group('watchPlanVsFact (D-116): факт одним запросом, конвертация D-18', () {
    test(
      'факт — живые операции категории за период плана, в базовой',
      () async {
        await f.ensureRub();
        final Category food = await seedExpenseCategory();
        final Account card = await f.seedAccount(name: 'Карта');
        final Plan plan = await seedPlan(categoryId: food.id);
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: card.id,
          categoryId: food.id,
          amountMinor: 120050,
          date: DateTime.utc(2026, 10, 5),
        );
        final Transaction deleted = await f.transactions.create(
          type: TransactionType.expense,
          accountId: card.id,
          categoryId: food.id,
          amountMinor: 999999,
          date: DateTime.utc(2026, 10, 6),
        );
        final List<Transaction> all = await f.transactions.getFiltered();
        expect(all, hasLength(2));
        await f.transactions.softDelete(deleted.id);

        final List<PlanVsFact> rows = await f.plans
            .watchPlanVsFact(
              from: DateTime.utc(2026, 10),
              to: DateTime.utc(2026, 11),
            )
            .first;
        expect(rows, hasLength(1));
        expect(rows.single.plan.id, plan.id);
        expect(rows.single.categoryName, 'Продукты');
        expect(rows.single.factMinor, 120050);
        expect(rows.single.amountMinor, 4000000);
        expect(rows.single.remainingMinor, 3879950);
      },
    );

    test('валюты конвертируются построчно half-up (D-18/D-22)', () async {
      await f.ensureRub();
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 2.5);
      final Category food = await seedExpenseCategory();
      final Account usd = await f.seedAccount(name: 'USD', currencyCode: 'USD');
      final Plan plan = await seedPlan(categoryId: food.id);
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: usd.id,
        categoryId: food.id,
        amountMinor: 101,
        date: DateTime.utc(2026, 10, 5),
      );

      final List<PlanVsFact> rows = await f.plans
          .watchPlanVsFact(
            from: DateTime.utc(2026, 10),
            to: DateTime.utc(2026, 11),
          )
          .first;
      expect(rows.single.plan.id, plan.id);
      // 101 × 2.5 = 252.5 → half-up 253 в минорных единицах базы.
      expect(rows.single.factMinor, 253);
    });

    test('доходный план считает доходы: тип — производная от kind', () async {
      await f.ensureRub();
      final Category salary = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );
      final Account card = await f.seedAccount();
      final Plan plan = await seedPlan(categoryId: salary.id);
      await f.transactions.create(
        type: TransactionType.income,
        accountId: card.id,
        categoryId: salary.id,
        amountMinor: 3000000,
        date: DateTime.utc(2026, 10, 10),
      );

      final List<PlanVsFact> rows = await f.plans
          .watchPlanVsFact(
            from: DateTime.utc(2026, 10),
            to: DateTime.utc(2026, 11),
          )
          .first;
      expect(rows.single.plan.id, plan.id);
      expect(rows.single.factMinor, 3000000);
    });

    test('план без операций даёт факт 0', () async {
      final Category food = await seedExpenseCategory();
      final Plan plan = await seedPlan(categoryId: food.id);
      final List<PlanVsFact> rows = await f.plans
          .watchPlanVsFact(
            from: DateTime.utc(2026, 10),
            to: DateTime.utc(2026, 11),
          )
          .first;
      expect(rows.single.plan.id, plan.id);
      expect(rows.single.factMinor, 0);
      expect(rows.single.ratio, 0);
    });

    test(
      'окно from/to отбирает планы, факт — за полный период плана',
      () async {
        final Category food = await seedExpenseCategory();
        final Plan plan = await seedPlan(categoryId: food.id);
        final Account card = await f.seedAccount();
        await f.transactions.create(
          type: TransactionType.expense,
          accountId: card.id,
          categoryId: food.id,
          amountMinor: 1000,
          date: DateTime.utc(2026, 10, 20),
        );

        // Окно внутри периода плана: план показан, факт — за весь его период.
        final List<PlanVsFact> inside = await f.plans
            .watchPlanVsFact(
              from: DateTime.utc(2026, 10, 15),
              to: DateTime.utc(2026, 10, 25),
            )
            .first;
        expect(inside.single.plan.id, plan.id);
        expect(inside.single.factMinor, 1000);

        // Окно вне периода: плана нет.
        final List<PlanVsFact> outside = await f.plans
            .watchPlanVsFact(
              from: DateTime.utc(2026, 11),
              to: DateTime.utc(2026, 12),
            )
            .first;
        expect(outside, isEmpty);
      },
    );

    test('план с мягко удалённой категорией не показывается', () async {
      final Category food = await seedExpenseCategory();
      final Plan plan = await seedPlan(categoryId: food.id);
      // С D-128 DAO сам не создаёт комбинацию «план + удалённая категория»
      // (удаление с живым планом запрещено): она возможна только из
      // несогласованного импорта (D-25 принимает мягко удалённых
      // владельцев) — эмулируем его прямой записью deleted_at, минуя DAO,
      // и проверяем, что JOIN-отсев (D-122.в) остаётся защитой чтения.
      await f.db.customStatement(
        'UPDATE categories SET deleted_at = ? WHERE id = ?',
        <Object?>[f.clock.read().toIso8601String(), food.id],
      );
      final List<PlanVsFact> rows = await f.plans
          .watchPlanVsFact(
            from: DateTime.utc(2026, 10),
            to: DateTime.utc(2026, 11),
          )
          .first;
      expect(rows, isEmpty);
      expect(await f.plans.getById(plan.id), isNotNull);
    });
  });
}
