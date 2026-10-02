// Провайдеры прогноза баланса (M7-шаг B, D-117).
//
// Прогноз — линза просмотра: не хранится, не кэшируется, в балансовые
// агрегаты §8 не входит. Провайдер собирает существующие живые потоки
// (общий баланс дашборда, новый агрегат TransactionsDao D-116, план-факт
// D-116) и зовёт чистое ядро `core/forecast.dart`; пересчёт — на каждое
// изменение источников (Riverpod сам инвалидирует зависимости), кэша нет.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/forecast.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/reports/reports_controller.dart';

/// История для прогноза: суммы живых операций по категориям, видам и
/// месяцам UTC в базовой валюте (D-116) за всё время учёта. Нижняя граница
/// 1970 (начало unix-времени) не режет данные: окно средних сужает само
/// ядро — «с первой операции» (D-117), а месяцы в строках дают ему эту
/// границу. Верхняя граница — конец текущего месяца: будущие операции
/// (датированные вперёд) в историю не входят.
final forecastHistoryProvider =
    StreamProvider.autoDispose<List<CategoryNetBase>>((ref) {
      return ref
          .watch(transactionsDaoProvider)
          .watchCategoryNetByPeriodInBase(
            from: DateTime.utc(1970),
            to: nextMonthStart(utcNow()),
          );
    });

/// Планы, пересекающие горизонт прогноза (1..[forecastWindows] месяцев):
/// строки план-факта (D-116) — расчёту нужны сами планы; факт уже есть
/// у потребителя-карточки план-факта. Верхняя граница — конец последнего
/// окна, чтобы план, пересекающий его, не выпал.
final forecastPlansProvider = StreamProvider.autoDispose<List<PlanVsFact>>((
  ref,
) {
  final DateTime thisMonth = monthStart(utcNow());
  return ref
      .watch(plansDaoProvider)
      .watchPlanVsFact(
        from: thisMonth,
        to: DateTime.utc(
          thisMonth.year,
          thisMonth.month + forecastWindows.last + 1,
        ),
      );
});

/// Вид живых категорий (id → «доход»): направление плана — производная от
/// вида категории (D-115.а), а `PlanVsFact` вида не несёт.
final forecastCategoryKindsProvider =
    StreamProvider.autoDispose<Map<String, bool>>((ref) {
      return ref
          .watch(categoriesDaoProvider)
          .watchAlive()
          .map(
            (List<Category> categories) => <String, bool>{
              for (final Category category in categories)
                category.id:
                    CategoryKind.fromDb(category.kind) == CategoryKind.income,
            },
          );
    });

/// Прогноз баланса на окна 1/3/6/9/12 месяцев (D-117): текущий баланс
/// дашборда (D-18/D-60) + нетто будущих месяцев по средним истории и
/// планам. Каждое изменение операции, плана, курса или баланса приходит
/// новой выдачей — линза живая, без хранения.
final forecastProvider = FutureProvider.autoDispose<List<ForecastPoint>>((
  ref,
) async {
  final int balance = await ref.watch(totalBalanceProvider.future);
  final List<CategoryNetBase> rows = await ref.watch(
    forecastHistoryProvider.future,
  );
  final List<PlanVsFact> planRows = await ref.watch(
    forecastPlansProvider.future,
  );
  final Map<String, bool> kinds = await ref.watch(
    forecastCategoryKindsProvider.future,
  );
  final List<ForecastPlan> plans = <ForecastPlan>[];
  for (final PlanVsFact row in planRows) {
    final bool? isIncome = kinds[row.plan.categoryId];
    if (isIncome == null) {
      continue; // план без живой категории невозможен через DAO (D-115.а)
    }
    plans.add(
      ForecastPlan(
        categoryId: row.plan.categoryId,
        isIncome: isIncome,
        periodStart: DateTime.parse(row.plan.periodStart).toUtc(),
        periodEnd: DateTime.parse(row.plan.periodEnd).toUtc(),
        amountMinor: row.plan.amountMinor,
      ),
    );
  }
  return forecastBalance(
    history: <ForecastHistoryEntry>[
      for (final CategoryNetBase row in rows)
        ForecastHistoryEntry(
          categoryId: row.categoryId,
          month: _monthFromKey(row.monthKey),
          isIncome: row.type == TransactionType.income,
          amountMinor: row.amountMinor,
        ),
    ],
    plans: plans,
    currentBalanceMinor: balance,
    now: utcNow(),
  );
});

/// Месяц (начало, UTC) из ключа агрегата `YYYY-MM` (образец SQL-группировки
/// `_baseAggregateOpsSelect`).
DateTime _monthFromKey(String key) => DateTime.utc(
  int.parse(key.substring(0, 4)),
  int.parse(key.substring(5, 7)),
);
