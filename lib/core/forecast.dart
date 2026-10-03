/// Прогноз баланса на 1/3/6/9/12 месяцев (M7/D-117).
///
/// Чистое ядро: вход — строки истории и планы (суммы уже в базовой валюте,
/// конвертация построчная — D-18/D-22), выход — точки прогноза. Ни drift,
/// ни UI: тестируется таблицей значений.
///
/// Алгоритм (D-117):
/// - окно истории — последние [forecastHistoryMonths] полных календарных
///   месяцев UTC; короче — если данных меньше (с первой операции); нет
///   данных — линия плоская (нетто будущих месяцев нулевые);
/// - среднее месячное нетто категории (доход +, расход −) = сумма за окно /
///   число месяцев окна (half-up D-22);
/// - для каждого будущего месяца m (1..12): категория с планом, период
///   которого пересекает m, — план, распределённый по дням пересечения
///   (доля = дни пересечения / дни плана, half-up; доход +, расход −);
///   категория без плана на m — её среднее по истории; без плана и без
///   истории — 0;
/// - прогноз баланса в месяце m = текущий баланс + Σ нетто месяцев до m
///   включительно.
library;

import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/months.dart';

/// Длина окна истории в полных календарных месяцах (D-117).
const int forecastHistoryMonths = 6;

/// Окна прогноза в месяцах — точки карточки (D-117).
const List<int> forecastWindows = <int>[1, 3, 6, 9, 12];

/// Строка истории: сумма живых операций одной категории одного вида за
/// календарный месяц UTC в минорных единицах базовой валюты (D-18/D-22).
class ForecastHistoryEntry {
  const ForecastHistoryEntry({
    required this.categoryId,
    required this.month,
    required this.isIncome,
    required this.amountMinor,
  });

  /// Категория операции.
  final String categoryId;

  /// Начало календарного месяца (UTC), за который собрана сумма.
  final DateTime month;

  /// Доход (+) или расход (−): знак задаёт вклад в нетто.
  final bool isIncome;

  /// Положительная сумма месяца в базовой валюте.
  final int amountMinor;
}

/// План, влияющий на прогноз: цель категории на период
/// [periodStart, periodEnd) — полузамкнутый интервал, как в схеме (D-115.а).
class ForecastPlan {
  const ForecastPlan({
    required this.categoryId,
    required this.isIncome,
    required this.periodStart,
    required this.periodEnd,
    required this.amountMinor,
  });

  /// Категория плана.
  final String categoryId;

  /// Направление — производная от вида категории (D-115.а).
  final bool isIncome;

  final DateTime periodStart;
  final DateTime periodEnd;

  /// Целевая сумма периода в базовой валюте, положительная.
  final int amountMinor;
}

/// Точка прогноза: конец окна (месяц UTC) и прогноз баланса в этот месяц.
class ForecastPoint {
  const ForecastPoint({required this.month, required this.balanceMinor});

  /// Начало месяца UTC, на который приходится точка (конец окна).
  final DateTime month;

  /// Прогноз баланса, минорные единицы базовой валюты.
  final int balanceMinor;
}

/// Прогноз баланса на окна [forecastWindows] (D-117).
///
/// [now] — текущий момент в UTC: функция чистая, системное время не читает
/// (шов тестов). История может содержать месяцы вне окна, в том числе
/// будущие и неполный текущий, — в средние входят только полные месяцы
/// окна; самый ранний такой месяц задаёт «данных меньше» — окно укорачивается
/// до него. Планы без пересечения с будущим месяцем на него не влияют.
List<ForecastPoint> forecastBalance({
  required List<ForecastHistoryEntry> history,
  required List<ForecastPlan> plans,
  required int currentBalanceMinor,
  required DateTime now,
}) {
  final DateTime thisMonth = monthStart(now);
  final _ForecastAverages averages = _averages(history, thisMonth);
  final int maxWindow = forecastWindows.reduce((int a, int b) => a > b ? a : b);
  final List<int> cumulative = <int>[];
  int running = currentBalanceMinor;
  for (int monthShift = 1; monthShift <= maxWindow; monthShift++) {
    final DateTime month = DateTime.utc(
      thisMonth.year,
      thisMonth.month + monthShift,
    );
    running += _monthNet(month, averages, plans);
    cumulative.add(running);
  }
  return <ForecastPoint>[
    for (final int window in forecastWindows)
      ForecastPoint(
        month: DateTime.utc(thisMonth.year, thisMonth.month + window),
        balanceMinor: cumulative[window - 1],
      ),
  ];
}

/// Средние нетто категорий по окну истории: карта «категория → среднее» и
/// число месяцев окна (0 — окно пустое: данных за полные месяцы нет).
class _ForecastAverages {
  const _ForecastAverages({required this.byCategory, required this.months});

  final Map<String, int> byCategory;
  final int months;
}

/// Считает окно истории (D-117): последние [forecastHistoryMonths] полных
/// календарных месяцев UTC, укороченные до самого раннего месяца с данными.
/// Текущий (неполный) и будущие месяцы в окно не входят; суммы за окно
/// нормируются на число месяцев окна (half-up D-22, знак отдельно).
_ForecastAverages _averages(
  List<ForecastHistoryEntry> history,
  DateTime thisMonth,
) {
  DateTime? firstMonth;
  for (final ForecastHistoryEntry entry in history) {
    final DateTime month = monthStart(entry.month);
    if (!month.isBefore(thisMonth)) {
      continue; // текущий неполный и будущие месяцы — не история
    }
    if (firstMonth == null || month.isBefore(firstMonth)) {
      firstMonth = month;
    }
  }
  if (firstMonth == null) {
    return const _ForecastAverages(byCategory: <String, int>{}, months: 0);
  }
  final DateTime horizonStart = DateTime.utc(
    thisMonth.year,
    thisMonth.month - forecastHistoryMonths,
  );
  final DateTime windowStart = firstMonth.isAfter(horizonStart)
      ? firstMonth
      : horizonStart;
  final int months = _monthDiff(windowStart, thisMonth);
  final Map<String, int> netByCategory = <String, int>{};
  for (final ForecastHistoryEntry entry in history) {
    final DateTime month = monthStart(entry.month);
    if (month.isBefore(windowStart) || !month.isBefore(thisMonth)) {
      continue;
    }
    final int signed = entry.isIncome ? entry.amountMinor : -entry.amountMinor;
    netByCategory[entry.categoryId] =
        (netByCategory[entry.categoryId] ?? 0) + signed;
  }
  return _ForecastAverages(
    byCategory: <String, int>{
      for (final MapEntry<String, int> entry in netByCategory.entries)
        entry.key: _roundHalfUpDiv(entry.value, months),
    },
    months: months,
  );
}

/// Нетто будущего месяца [month]: планы категории (распределённые по дням
/// пересечения) или среднее категории; без плана и истории — 0.
int _monthNet(
  DateTime month,
  _ForecastAverages averages,
  List<ForecastPlan> plans,
) {
  final DateTime nextMonth = nextMonthStart(month);
  final List<String> categories = <String>{
    ...averages.byCategory.keys,
    for (final ForecastPlan plan in plans) plan.categoryId,
  }.toList();
  int net = 0;
  for (final String categoryId in categories) {
    final List<ForecastPlan> covering = <ForecastPlan>[
      for (final ForecastPlan plan in plans)
        if (plan.categoryId == categoryId)
          if (_intersectionDays(plan, month, nextMonth) > 0) plan,
    ];
    if (covering.isNotEmpty) {
      for (final ForecastPlan plan in covering) {
        final int share = _planShareInMonth(plan, month, nextMonth);
        net += plan.isIncome ? share : -share;
      }
    } else {
      net += averages.byCategory[categoryId] ?? 0;
    }
  }
  return net;
}

/// Доля плана, приходящаяся на месяц [monthStart, monthEnd): half-up
/// (D-22) от `сумма × дни пересечения / дни плана`.
int _planShareInMonth(
  ForecastPlan plan,
  DateTime monthStart,
  DateTime monthEnd,
) {
  final DateTime start = calendarDayUtc(plan.periodStart);
  final DateTime end = calendarDayUtc(plan.periodEnd);
  final int planDays = end.difference(start).inDays;
  if (planDays <= 0) {
    return 0;
  }
  final DateTime intersectionStart = start.isBefore(monthStart)
      ? monthStart
      : start;
  final DateTime intersectionEnd = end.isBefore(monthEnd) ? end : monthEnd;
  final int days = intersectionEnd.difference(intersectionStart).inDays;
  if (days <= 0) {
    return 0;
  }
  return _roundHalfUpDiv(plan.amountMinor * days, planDays);
}

/// Число дней пересечения периода плана с месяцем ([monthStart, monthEnd)) —
/// по календарным дням UTC (периоды планов — даты формы, полуночи UTC).
int _intersectionDays(
  ForecastPlan plan,
  DateTime monthStart,
  DateTime monthEnd,
) {
  final DateTime start = calendarDayUtc(plan.periodStart);
  final DateTime end = calendarDayUtc(plan.periodEnd);
  final DateTime intersectionStart = start.isBefore(monthStart)
      ? monthStart
      : start;
  final DateTime intersectionEnd = end.isBefore(monthEnd) ? end : monthEnd;
  return intersectionEnd.difference(intersectionStart).inDays;
}

/// Деление с округлением half-up по модулю (D-22): в прогнозе — доли плана
/// и средние за месяцы. Double не используется: суммы — минорные int (§3).
int _roundHalfUpDiv(int value, int divisor) {
  final bool negative = value < 0;
  final int magnitude = negative ? -value : value;
  final int rounded = (2 * magnitude + divisor) ~/ (2 * divisor);
  return negative ? -rounded : rounded;
}

/// Число календарных месяцев между началами месяцев ([to] позже [from]).
int _monthDiff(DateTime from, DateTime to) =>
    (to.year * 12 + to.month) - (from.year * 12 + from.month);
