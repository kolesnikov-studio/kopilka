import 'package:drift/drift.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/tables.dart';

part 'plans_dao.g.dart';

/// Строка план-факта (D-116): план, имя категории и факт за его период.
///
/// Факт — живые операции категории плана за собственный период плана
/// [periodStart, periodEnd), конвертированные в базовую валюту построчно
/// (D-18/D-22). Направление — производная от категории (D-115.а): для
/// расходной категории факт — расходы, для доходной — доходы.
class PlanVsFact {
  const PlanVsFact({
    required this.plan,
    required this.categoryName,
    required this.factMinor,
  });

  /// План, к которому относится факт.
  final Plan plan;

  /// Имя категории на момент чтения (JOIN categories) — для подписи в UI.
  final String categoryName;

  /// Факт за период плана, минорные единицы базовой валюты.
  final int factMinor;

  /// Целевая сумма плана, минорные единицы базовой.
  int get amountMinor => plan.amountMinor;

  /// Остаток до цели: план минус факт (может быть отрицательным при
  /// перерасходе плана).
  int get remainingMinor => plan.amountMinor - factMinor;

  /// Доля исполнения (без верхней границы; UI сам решает, как показывать
  /// перерасход).
  double get ratio => plan.amountMinor <= 0 ? 0 : factMinor / plan.amountMinor;
}

/// Планы (v8, M7/D-116): срочная целевая сумма по категории на период.
///
/// Правила:
/// - категория обязана быть живой; направление (доход/расход) — производная
///   от `categories.kind` (D-115.а), отдельной колонки нет;
/// - суммa строго положительная — минорные единицы базовой валюты (§3,
///   образец D-19: у категории валюты нет);
/// - период — полузамкнутый [periodStart, periodEnd) с датами UTC,
///   end > start (D-115.а);
/// - пересекающиеся по датам живые планы одной категории невозможны —
///   правило DAO, не SQL (D-115.в); отказ [DataFailure.invalidInput];
/// - удаление — только soft delete, без каскадов.
@DriftAccessor(tables: [Plans, Categories, Transactions])
class PlansDao extends DatabaseAccessor<AppDatabase> with _$PlansDaoMixin {
  PlansDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт план на живую категорию.
  ///
  /// Пересечение с живым планом той же категории — отказ: «одна категория —
  /// один живой план в каждый момент времени» (D-115.в). Планы разных
  /// категорий и непересекающиеся периоды одной категории свободны.
  Future<Plan> create({
    required String categoryId,
    required DateTime periodStart,
    required DateTime periodEnd,
    required int amountMinor,
  }) async {
    _requirePositiveAmount(amountMinor);
    _requireUtcDate(periodStart, 'начало периода плана');
    _requireUtcDate(periodEnd, 'конец периода плана');
    _requireOrderedPeriod(periodStart, periodEnd);
    await _requireAliveCategory(categoryId);
    await _assertNoOverlap(
      categoryId: categoryId,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
    final DateTime now = clock();
    return into(plans).insertReturning(
      PlansCompanion.insert(
        id: idGenerator(),
        categoryId: categoryId,
        periodStart: _iso(periodStart),
        periodEnd: _iso(periodEnd),
        amountMinor: amountMinor,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живой план по id (или NULL).
  Future<Plan?> getById(String id) => (select(
    plans,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Живой план по id или отказ [DataFailure.notFound] (образец D-82).
  Future<Plan> requireAliveById(String id) async {
    final Plan? plan = await getById(id);
    if (plan == null) {
      throw DataValidationException(
        'план $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return plan;
  }

  /// Поток живых планов, ранние периоды сверху (для списка UI).
  Stream<List<Plan>> watchAlive() => _aliveQuery().watch();

  /// Правит поля плана; не переданные поля (`Value.absent()`) остаются
  /// как были. `updatedAt` обновляется всегда.
  ///
  /// Валидации те же, что при создании, по итоговому состоянию строки:
  /// смена категории переносит план в другую категорию (и проверяет
  /// пересечение там), смена периода проверяет end > start и пересечения
  /// в своей (возможно, новой) категории.
  Future<Plan> updatePlan(
    String id, {
    Value<String> categoryId = const Value.absent(),
    Value<DateTime> periodStart = const Value.absent(),
    Value<DateTime> periodEnd = const Value.absent(),
    Value<int> amountMinor = const Value.absent(),
  }) async {
    final Plan current = await requireAliveById(id);
    if (amountMinor.present) {
      _requirePositiveAmount(amountMinor.value);
    }
    if (periodStart.present) {
      _requireUtcDate(periodStart.value, 'начало периода плана');
    }
    if (periodEnd.present) {
      _requireUtcDate(periodEnd.value, 'конец периода плана');
    }
    final String effectiveCategory = categoryId.present
        ? categoryId.value
        : current.categoryId;
    final DateTime effectiveStart = periodStart.present
        ? periodStart.value
        : DateTime.parse(current.periodStart).toUtc();
    final DateTime effectiveEnd = periodEnd.present
        ? periodEnd.value
        : DateTime.parse(current.periodEnd).toUtc();
    if (effectiveEnd.isAfter(effectiveStart) == false) {
      throw DataValidationException(
        'конец периода плана должен быть позже начала',
        kind: DataFailure.invalidInput,
      );
    }
    if (categoryId.present) {
      await _requireAliveCategory(effectiveCategory);
    }
    await _assertNoOverlap(
      categoryId: effectiveCategory,
      periodStart: effectiveStart,
      periodEnd: effectiveEnd,
      excludePlanId: id,
    );
    await (update(plans)..where((t) => t.id.equals(id))).write(
      PlansCompanion(
        categoryId: categoryId,
        periodStart: periodStart.present
            ? Value<String>(_iso(periodStart.value))
            : const Value.absent(),
        periodEnd: periodEnd.present
            ? Value<String>(_iso(periodEnd.value))
            : const Value.absent(),
        amountMinor: amountMinor,
        updatedAt: Value(clock()),
      ),
    );
    return requireAliveById(id);
  }

  /// Мягко удаляет план. Пересечение после удаления снова свободно —
  /// новый план на тот же период можно создать (D-115.в).
  Future<void> softDelete(String id) async {
    await requireAliveById(id);
    final DateTime now = clock();
    await (update(plans)..where((t) => t.id.equals(id))).write(
      PlansCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Поток «план против факта» по всем живым планам, пересекающимся
  /// с окном [from, to).
  ///
  /// Один customSelect: план, имя категории и живые операции его категории
  /// за собственный период плана (образец [BudgetsDao.watchProgress]).
  /// Факт конвертируется в базовую построчно в Dart — SQL не умеет
  /// округлять «до минорной единицы базы» (D-18/D-22). Тип операций —
  /// по виду категории (D-115.а: направление — производная от kind).
  /// Пересчитывается при изменении планов, категорий, операций и курсов.
  /// План с мягко удалённой категорией не показывается (как у бюджетов:
  /// комбинация возможна только у несогласованного импорта).
  Stream<List<PlanVsFact>> watchPlanVsFact({
    required DateTime from,
    required DateTime to,
  }) {
    final DateTime utcFrom = from.toUtc();
    final DateTime utcTo = to.toUtc();
    return customSelect(
      'SELECT p.id AS plan_id, p.category_id AS category_id, '
      'p.period_start AS period_start, p.period_end AS period_end, '
      'p.amount_minor AS amount_minor, '
      'p.created_at AS created_at, p.updated_at AS updated_at, '
      'c.name AS category_name, '
      't.id AS tx_id, t.amount_minor AS tx_amount_minor, '
      't.currency_code AS currency_code, '
      'COALESCE(cur.rate_to_base, 1.0) AS rate '
      'FROM plans p '
      'JOIN categories c ON c.id = p.category_id AND c.deleted_at IS NULL '
      'LEFT JOIN transactions t '
      'ON t.category_id = p.category_id AND t.type = c.kind '
      'AND t.deleted_at IS NULL '
      'AND t.date >= CAST(strftime(\'%s\', p.period_start) AS INTEGER) '
      'AND t.date < CAST(strftime(\'%s\', p.period_end) AS INTEGER) '
      'LEFT JOIN currencies AS cur ON cur.code = t.currency_code '
      'WHERE p.deleted_at IS NULL '
      'AND CAST(strftime(\'%s\', p.period_end) AS INTEGER) > ? '
      'AND CAST(strftime(\'%s\', p.period_start) AS INTEGER) < ? '
      'ORDER BY p.period_start, p.id',
      variables: [
        Variable<int>(utcFrom.millisecondsSinceEpoch ~/ 1000),
        Variable<int>(utcTo.millisecondsSinceEpoch ~/ 1000),
      ],
      readsFrom: {plans, categories, transactions, currencies},
    ).watch().map(_groupPlanVsFactRows);
  }

  /// Группирует строки план-факта по планам, конвертируя каждую операцию
  /// в базовую до суммирования (D-18). План без операций (LEFT JOIN дал
  /// NULL-строку) даёт факт 0.
  List<PlanVsFact> _groupPlanVsFactRows(List<QueryRow> rows) {
    final Map<String, PlanVsFact> byPlan = <String, PlanVsFact>{};
    final Map<String, int> factByPlan = <String, int>{};
    for (final QueryRow row in rows) {
      final String planId = row.read<String>('plan_id');
      if (!byPlan.containsKey(planId)) {
        byPlan[planId] = PlanVsFact(
          plan: Plan(
            id: planId,
            categoryId: row.read<String>('category_id'),
            periodStart: row.read<String>('period_start'),
            periodEnd: row.read<String>('period_end'),
            amountMinor: row.read<int>('amount_minor'),
            createdAt: _rawDate(row.read<int>('created_at')),
            updatedAt: _rawDate(row.read<int>('updated_at')),
          ),
          categoryName: row.read<String>('category_name'),
          factMinor: 0,
        );
      }
      // Левое соединение с операциями: строка плана без операций имеет
      // NULL tx_id и не вносит ничего в сумму.
      if (row.read<String?>('tx_id') == null) {
        continue;
      }
      factByPlan[planId] =
          (factByPlan[planId] ?? 0) +
          convertMinor(
            row.read<int>('tx_amount_minor'),
            row.read<double>('rate'),
            exponent: currencyExponentByCode(row.read<String>('currency_code')),
          );
    }
    return <PlanVsFact>[
      for (final MapEntry<String, PlanVsFact> entry in byPlan.entries)
        PlanVsFact(
          plan: entry.value.plan,
          categoryName: entry.value.categoryName,
          factMinor: factByPlan[entry.key] ?? 0,
        ),
    ];
  }

  SimpleSelectStatement<$PlansTable, Plan> _aliveQuery() => select(plans)
    ..where((t) => t.deletedAt.isNull())
    ..orderBy([
      (t) => OrderingTerm.asc(t.periodStart),
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.id),
    ]);

  /// Категория обязана быть живой; направление плана производно от её
  /// вида (D-115.а), поэтому вид здесь не ограничивается.
  Future<void> _requireAliveCategory(String categoryId) async {
    final Category? category =
        await (select(categories)
              ..where((t) => t.id.equals(categoryId) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (category == null) {
      throw DataValidationException(
        'категория $categoryId не найдена',
        kind: DataFailure.notFound,
      );
    }
  }

  /// Пересечение живых планов категории: интервалы [start, end) — планы,
  /// касающиеся только границами (end == start), не пересекаются (D-115.в).
  Future<void> _assertNoOverlap({
    required String categoryId,
    required DateTime periodStart,
    required DateTime periodEnd,
    String? excludePlanId,
  }) async {
    final Plan? overlapping =
        await (select(plans)..where(
              (t) =>
                  t.categoryId.equals(categoryId) &
                  t.deletedAt.isNull() &
                  (excludePlanId == null
                      ? const Constant<bool>(true)
                      : t.id.equals(excludePlanId).not()) &
                  t.periodEnd.isBiggerThanValue(_iso(periodStart)) &
                  t.periodStart.isSmallerThanValue(_iso(periodEnd)),
            ))
            .getSingleOrNull();
    if (overlapping != null) {
      throw DataValidationException(
        'у категории уже есть живой план на пересекающийся период — '
        'пересекающиеся планы одной категории невозможны (D-115.в)',
        kind: DataFailure.invalidInput,
      );
    }
  }

  void _requirePositiveAmount(int amountMinor) {
    if (amountMinor <= 0) {
      throw DataValidationException(
        'сумма плана должна быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
  }

  void _requireUtcDate(DateTime date, String what) {
    if (!date.isUtc) {
      throw DataValidationException(
        '$what должен быть в UTC (§3)',
        kind: DataFailure.invalidInput,
      );
    }
  }

  void _requireOrderedPeriod(DateTime start, DateTime end) {
    if (!end.isAfter(start)) {
      throw DataValidationException(
        'конец периода плана должен быть позже начала',
        kind: DataFailure.invalidInput,
      );
    }
  }

  /// Каноничная запись UTC-даты в TEXT-колонку: ISO-8601 с миллисекундами
  /// и `Z` — как у due_date долгов; лексикографический порядок строк
  /// совпадает с хронологическим (SQL сравнения периодов).
  String _iso(DateTime date) => date.toUtc().toIso8601String();

  /// customSelect отдаёт даты сырыми int-секундами SQLite — та же
  /// нормализация, что и в кодеке экспорта.
  DateTime _rawDate(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
}
