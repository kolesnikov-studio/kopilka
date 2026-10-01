import 'package:drift/drift.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'budgets_dao.g.dart';

/// Бюджеты (D-14): повторяющийся месячный лимит расходов по категории.
///
/// Правила:
/// - лимит ставится только на живую категорию расходов (доходы и переводы
///   в бюджете не участвуют);
/// - у категории максимум один живой бюджет;
/// - лимит строго положительный, деньги — минорные единицы (§3);
/// - удаление — только soft delete, без каскадов.
@DriftAccessor(tables: [Budgets, Categories, Transactions])
class BudgetsDao extends DatabaseAccessor<AppDatabase> with _$BudgetsDaoMixin {
  BudgetsDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт бюджет на категорию расходов.
  Future<Budget> create({
    required String categoryId,
    required int limitMinor,
  }) async {
    if (limitMinor <= 0) {
      throw DataValidationException(
        'лимит бюджета должен быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
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
    if (CategoryKind.fromDb(category.kind) != CategoryKind.expense) {
      throw DataValidationException(
        'бюджет можно установить только на категорию расходов',
        kind: DataFailure.budgetCategoryInvalid,
      );
    }
    final Budget? existing = await findByCategory(categoryId);
    if (existing != null) {
      throw DataValidationException(
        'у категории «${category.name}» уже есть бюджет',
        kind: DataFailure.budgetAlreadyExists,
      );
    }
    final DateTime now = clock();
    return into(budgets).insertReturning(
      BudgetsCompanion.insert(
        id: idGenerator(),
        categoryId: categoryId,
        limitMinor: limitMinor,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живой бюджет категории (или NULL, если бюджета нет).
  Future<Budget?> findByCategory(String categoryId) =>
      (select(budgets)..where(
            (t) => t.categoryId.equals(categoryId) & t.deletedAt.isNull(),
          ))
          .getSingleOrNull();

  /// Все живые бюджеты, в порядке создания.
  Future<List<Budget>> getAlive() => _aliveQuery().get();

  /// Меняет лимит бюджета.
  Future<Budget> updateLimit(String id, {required int limitMinor}) async {
    if (limitMinor <= 0) {
      throw DataValidationException(
        'лимит бюджета должен быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
    await _requireAlive(id);
    await (update(budgets)..where((t) => t.id.equals(id))).write(
      BudgetsCompanion(
        limitMinor: Value(limitMinor),
        updatedAt: Value(clock()),
      ),
    );
    return _requireAlive(id);
  }

  /// Мягко удаляет бюджет.
  Future<void> softDelete(String id) async {
    await _requireAlive(id);
    final DateTime now = clock();
    await (update(budgets)..where((t) => t.id.equals(id))).write(
      BudgetsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Прогресс бюджета на календарный месяц, в который попадает [moment]:
  /// сумма живых расходов категории за месяц, конвертированных в базовую
  /// валюту (D-18), против лимита. Лимит не конвертируется — он уже в
  /// минорных единицах базовой (D-19). Переводы расходами не считаются,
  /// мягко удалённые операции не учитываются.
  Future<BudgetProgress> progressOf(
    Budget budget, {
    required DateTime moment,
  }) async {
    final DateTime from = monthStart(moment);
    final DateTime to = nextMonthStart(from);
    final List<QueryRow> rows = await _progressOpsSelect(
      budget.categoryId,
      from,
      to,
    ).get();
    return BudgetProgress(
      budget: budget,
      categoryName:
          (await (select(categories)
                    ..where((t) => t.id.equals(budget.categoryId)))
                  .getSingleOrNull())
              ?.name ??
          '',
      spentMinor: _spentInBase(rows),
    );
  }

  /// Поток живых бюджетов с расходами за календарный месяц, в который
  /// попадает [moment]. Пересчитывается при изменении бюджетов, категорий,
  /// операций и курсов валют (D-18: readsFrom включает currencies).
  /// Расходы конвертируются в базовую построчно в Dart — SQL не умеет
  /// округлять «до минорной единицы базы» (D-18/D-22, приём шага 5).
  ///
  /// Бюджеты с мягко удалённой категорией не показываются: такая комбинация
  /// не возникает через DAO (удаление категории с бюджетом запрещено) и
  /// означает импортированный файл с несогласованными данными.
  Stream<List<BudgetProgress>> watchProgress({required DateTime moment}) {
    final DateTime from = monthStart(moment);
    final DateTime to = nextMonthStart(from);
    return customSelect(
      'SELECT b.id AS budget_id, b.category_id AS category_id, '
      'b.limit_minor AS limit_minor, b.created_at AS created_at, '
      'b.updated_at AS updated_at, c.name AS category_name, '
      't.id AS tx_id, t.amount_minor AS amount_minor, '
      't.currency_code AS currency_code, '
      'COALESCE(cur.rate_to_base, 1.0) AS rate '
      'FROM budgets b '
      'JOIN categories c ON c.id = b.category_id AND c.deleted_at IS NULL '
      'LEFT JOIN transactions t '
      'ON t.category_id = b.category_id AND t.type = ? '
      'AND t.deleted_at IS NULL AND t.date >= ? AND t.date < ? '
      'LEFT JOIN currencies AS cur ON cur.code = t.currency_code '
      'WHERE b.deleted_at IS NULL '
      'ORDER BY b.created_at, b.id',
      variables: [
        Variable<String>(TransactionType.expense.dbValue),
        Variable<int>(from.millisecondsSinceEpoch ~/ 1000),
        Variable<int>(to.millisecondsSinceEpoch ~/ 1000),
      ],
      readsFrom: {budgets, categories, transactions, currencies},
    ).watch().map(_groupProgressRows);
  }

  /// Операции-кандидаты прогресса одного бюджета в периоде [from, to):
  /// суммы в минорных единицах своей валюты и текущий курс валюты операции
  /// к базовой. Операция с валютой без строки справочника получает курс 1
  /// (несогласованный импорт не выпадает из прогресса — как в шаге 5).
  Selectable<QueryRow> _progressOpsSelect(
    String categoryId,
    DateTime from,
    DateTime to,
  ) => customSelect(
    'SELECT t.id AS tx_id, t.amount_minor AS amount_minor, '
    't.currency_code AS currency_code, '
    'COALESCE(cur.rate_to_base, 1.0) AS rate '
    'FROM transactions AS t '
    'LEFT JOIN currencies AS cur ON cur.code = t.currency_code '
    'WHERE t.category_id = ? AND t.type = ? AND t.deleted_at IS NULL '
    'AND t.date >= ? AND t.date < ?',
    variables: [
      Variable<String>(categoryId),
      Variable<String>(TransactionType.expense.dbValue),
      Variable<int>(from.millisecondsSinceEpoch ~/ 1000),
      Variable<int>(to.millisecondsSinceEpoch ~/ 1000),
    ],
    readsFrom: {transactions, currencies},
  );

  /// Группирует строки watch-запроса по бюджетам, конвертируя каждую
  /// операцию в базовую до суммирования (D-18). Бюджет без операций
  /// (LEFT JOIN дал NULL-строку) даёт spent 0.
  List<BudgetProgress> _groupProgressRows(List<QueryRow> rows) {
    final Map<String, BudgetProgress> byBudget = <String, BudgetProgress>{};
    final Map<String, int> spentByBudget = <String, int>{};
    for (final QueryRow row in rows) {
      final String budgetId = row.read<String>('budget_id');
      if (!byBudget.containsKey(budgetId)) {
        byBudget[budgetId] = BudgetProgress(
          budget: Budget(
            id: budgetId,
            categoryId: row.read<String>('category_id'),
            limitMinor: row.read<int>('limit_minor'),
            createdAt: _rawDate(row.read<int>('created_at')),
            updatedAt: _rawDate(row.read<int>('updated_at')),
          ),
          categoryName: row.read<String>('category_name'),
          spentMinor: 0,
        );
      }
      // Левое соединение с операциями: строка бюджета без операций имеет
      // NULL tx_id и не вносит ничего в сумму.
      if (row.read<String?>('tx_id') == null) {
        continue;
      }
      spentByBudget[budgetId] =
          (spentByBudget[budgetId] ?? 0) +
          convertMinor(
            row.read<int>('amount_minor'),
            row.read<double>('rate'),
            exponent: currencyExponentByCode(row.read<String>('currency_code')),
          );
    }
    return <BudgetProgress>[
      for (final MapEntry<String, BudgetProgress> entry in byBudget.entries)
        BudgetProgress(
          budget: entry.value.budget,
          categoryName: entry.value.categoryName,
          spentMinor: spentByBudget[entry.key] ?? 0,
        ),
    ];
  }

  /// Сумма конвертированных построчно операций прогресса одного бюджета
  /// (для [progressOf]).
  int _spentInBase(List<QueryRow> rows) {
    int spent = 0;
    for (final QueryRow row in rows) {
      spent += convertMinor(
        row.read<int>('amount_minor'),
        row.read<double>('rate'),
        exponent: currencyExponentByCode(row.read<String>('currency_code')),
      );
    }
    return spent;
  }

  /// customSelect отдаёт даты сырыми int-секундами SQLite — та же
  /// нормализация, что и в кодеке экспорта.
  DateTime _rawDate(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);

  SimpleSelectStatement<$BudgetsTable, Budget> _aliveQuery() => select(budgets)
    ..where((t) => t.deletedAt.isNull())
    ..orderBy([
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.id),
    ]);

  Future<Budget> _requireAlive(String id) async {
    final Budget? budget = await (select(
      budgets,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (budget == null) {
      throw DataValidationException(
        'бюджет $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return budget;
  }
}

/// Прогресс бюджета на месяц: потрачено против лимита.
class BudgetProgress {
  const BudgetProgress({
    required this.budget,
    required this.categoryName,
    required this.spentMinor,
  });

  /// Бюджет, к которому относится прогресс.
  final Budget budget;

  /// Имя категории на момент чтения (JOIN categories) — для подписи в UI.
  final String categoryName;

  /// Живые расходы категории за месяц, минорные единицы.
  final int spentMinor;

  /// Лимит бюджета, минорные единицы.
  int get limitMinor => budget.limitMinor;

  /// Лимит превышен.
  bool get isOver => spentMinor > limitMinor;

  /// Доля потраченного от лимита (без верхней границы; UI сам решает,
  /// как показывать превышение).
  double get ratio => limitMinor <= 0 ? 0 : spentMinor / limitMinor;
}
