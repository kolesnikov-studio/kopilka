import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';

/// Окно списка планирования — все живые планы (спека C §2, D-127): факт
/// берётся за собственный период каждого плана (D-122.в), поэтому окно
/// шире любых реалистичных периодов. Это UI-параметр вызова DAO, правок
/// слоя данных не требует.
DateTime planningListFrom() => DateTime.utc(2000, 1, 1);
DateTime planningListTo() => DateTime.utc(2100, 1, 1);

/// Строки план-факт списка планирования (спека C §2): план, имя категории,
/// факт за собственный период плана; пересчитывается при изменении планов,
/// категорий, операций и курсов.
final planningProvider = StreamProvider.autoDispose<List<PlanVsFact>>((ref) {
  return ref
      .watch(plansDaoProvider)
      .watchPlanVsFact(from: planningListFrom(), to: planningListTo());
});

/// Живые планы — для превентивной проверки пересечения в форме (спека C
/// §6.3): пересечение живых планов категории приходит из DAO как
/// invalidInput без подвида, снек различается контекстом формы; DAO-отказ
/// остаётся страховкой. Проверка — чтение живого потока, не SQL (§2).
final alivePlansProvider = StreamProvider.autoDispose<List<Plan>>((ref) {
  return ref.watch(plansDaoProvider).watchAlive();
});

/// Итоги месяцев в базовой валюте — агрегат автобюджета (спека C §4,
/// D-54.17/D-121): тот же метод, что у «Динамики» отчётов, новых DAO и
/// таблиц не нужно. Окно — 6 закрытых месяцев перед текущим: текущий
/// неполный и дёргал бы среднее каждый день.
final autoBudgetTotalsProvider =
    StreamProvider.autoDispose<List<MonthTotalsBase>>((ref) {
      final DateTime to = monthStart(utcNow());
      final DateTime from = DateTime.utc(to.year, to.month - 6);
      return ref
          .watch(transactionsDaoProvider)
          .watchTotalsByMonthInBase(from: from, to: to);
    });

/// Предложение автобюджета (спека C §4): средний доход по месяцам с
/// доходом за окно агрегата и сумма «средний доход × срок».
class AutoBudgetSuggestion {
  const AutoBudgetSuggestion({
    required this.averageIncomeMinor,
    required this.monthsWithIncome,
  });

  /// Средний доход месяца с доходом, минорные единицы базовой (округление
  /// half-up, §3 — без double-арифметики на хранении).
  final int averageIncomeMinor;

  /// Сколько месяцев с доходом легло в среднее — для честной строки
  /// расчёта диалога.
  final int monthsWithIncome;

  /// Предзаполнение суммы по сроку: средний доход × [termMonths].
  int suggestedMinor(int termMonths) => averageIncomeMinor * termMonths;
}

/// Расчёт предложения автобюджета (спека C §4) — чистая функция поверх
/// агрегата: учитываются только месяцы с доходом (нулевые гасят среднее и
/// скрывают смысл «по доходу»), порог предложения — хотя бы один такой
/// месяц. null — месяцев с доходом нет: состояние «нет данных» диалога.
AutoBudgetSuggestion? computeAutoBudget(List<MonthTotalsBase> totals) {
  final List<int> incomes = <int>[
    for (final MonthTotalsBase month in totals)
      if (month.incomeMinor > 0) month.incomeMinor,
  ];
  if (incomes.isEmpty) {
    return null;
  }
  final int total = incomes.fold<int>(0, (int sum, int income) => sum + income);
  final int count = incomes.length;
  // Half-up без double (§3): (2·total + count) ~/ (2·count).
  final int average = (2 * total + count) ~/ (2 * count);
  return AutoBudgetSuggestion(
    averageIncomeMinor: average,
    monthsWithIncome: count,
  );
}

/// Контроллер планирования (спека C, D-127): создание/правка/удаление
/// планов через DAO, превентивная проверка пересечения; отказы — как
/// [Result], UI объясняет их по машиночитаемому виду.
class PlanningController extends Notifier {
  @override
  void build() {}

  PlansDao get _plans => ref.read(plansDaoProvider);

  /// Превентивная проверка пересечения живых планов категории (спека C
  /// §6.3, D-115.в): интервалы полузамкнутые, касание границами — не
  /// пересечение. [excludePlanId] — при правке сам план не считается.
  /// Данные потока ещё не пришли — false (проверку возьмёт на себя DAO).
  bool hasOverlap({
    required String categoryId,
    required DateTime periodStartUtc,
    required DateTime periodEndUtc,
    String? excludePlanId,
  }) {
    final List<Plan>? alive = ref.read(alivePlansProvider).value;
    if (alive == null) {
      return false;
    }
    for (final Plan plan in alive) {
      if (plan.id == excludePlanId || plan.categoryId != categoryId) {
        continue;
      }
      final DateTime start = DateTime.parse(plan.periodStart).toUtc();
      final DateTime end = DateTime.parse(plan.periodEnd).toUtc();
      if (end.isAfter(periodStartUtc) && start.isBefore(periodEndUtc)) {
        return true;
      }
    }
    return false;
  }

  /// Создаёт план. Отказы DAO: пересечение живых планов категории
  /// ([DataFailure.invalidInput], страховка за превентивной проверкой),
  /// категория не живая ([DataFailure.notFound]).
  Future<Result<Plan>> createPlan({
    required String categoryId,
    required DateTime periodStartUtc,
    required DateTime periodEndUtc,
    required int amountMinor,
  }) async {
    try {
      final Plan plan = await _plans.create(
        categoryId: categoryId,
        periodStart: periodStartUtc,
        periodEnd: periodEndUtc,
        amountMinor: amountMinor,
      );
      return Success<Plan>(plan);
    } on DataValidationException catch (error) {
      return Failure<Plan>(error.kind);
    }
  }

  /// Правит план целиком (категорию менять можно — DAO переносит план и
  /// проверит пересечение, D-115.в). [DataFailure.notFound] — план удалён
  /// во время правки (гонка, образец M6).
  Future<Result<Plan>> updatePlan({
    required String id,
    required String categoryId,
    required DateTime periodStartUtc,
    required DateTime periodEndUtc,
    required int amountMinor,
  }) async {
    try {
      final Plan plan = await _plans.updatePlan(
        id,
        categoryId: Value(categoryId),
        periodStart: Value<DateTime>(periodStartUtc),
        periodEnd: Value<DateTime>(periodEndUtc),
        amountMinor: Value<int>(amountMinor),
      );
      return Success<Plan>(plan);
    } on DataValidationException catch (error) {
      return Failure<Plan>(error.kind);
    }
  }

  /// Мягко удаляет план; период снова свободен (D-115.в).
  Future<Result<void>> deletePlan(String id) async {
    try {
      await _plans.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final planningControllerProvider = NotifierProvider<PlanningController, void>(
  PlanningController.new,
);
