import 'package:drift/drift.dart';
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
    final Category? category = await (select(categories)
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

  /// Поток живых бюджетов.
  Stream<List<Budget>> watchAlive() => _aliveQuery().watch();

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
      BudgetsCompanion(limitMinor: Value(limitMinor), updatedAt: Value(clock())),
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
  /// сумма живых расходов категории за месяц против лимита. Переводы
  /// расходами не считаются, мягко удалённые операции не учитываются.
  Future<BudgetProgress> progressOf(
    Budget budget, {
    required DateTime moment,
  }) async {
    final DateTime from = monthStart(moment);
    final DateTime to = nextMonthStart(from);
    final Expression<int> spent = transactions.amountMinor.sum();
    final TypedResult row = await (selectOnly(transactions)
          ..addColumns([spent])
          ..where(
            transactions.categoryId.equals(budget.categoryId) &
                transactions.deletedAt.isNull() &
                transactions.type.equals(TransactionType.expense.dbValue) &
                transactions.date.isBiggerOrEqualValue(from) &
                transactions.date.isSmallerThanValue(to),
          ))
        .getSingle();
    return BudgetProgress(
      budget: budget,
      spentMinor: row.read(spent) ?? 0,
    );
  }

  /// Поток живых бюджетов с расходами за календарный месяц, в который
  /// попадает [moment]. Пересчитывается при изменении бюджетов, категорий
  /// или операций. Расходы считаются одним JOIN-агрегатом в SQL.
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
      'b.updated_at AS updated_at, '
      'COALESCE(SUM(t.amount_minor), 0) AS spent_minor '
      'FROM budgets b '
      'JOIN categories c ON c.id = b.category_id AND c.deleted_at IS NULL '
      'LEFT JOIN transactions t '
      'ON t.category_id = b.category_id AND t.type = ? '
      'AND t.deleted_at IS NULL AND t.date >= ? AND t.date < ? '
      'WHERE b.deleted_at IS NULL '
      'GROUP BY b.id '
      'ORDER BY b.created_at, b.id',
      variables: [
        Variable<String>(TransactionType.expense.dbValue),
        Variable<int>(from.millisecondsSinceEpoch ~/ 1000),
        Variable<int>(to.millisecondsSinceEpoch ~/ 1000),
      ],
      readsFrom: {budgets, categories, transactions},
    ).watch().map(
          (List<QueryRow> rows) => <BudgetProgress>[
            for (final QueryRow row in rows)
              BudgetProgress(
                budget: Budget(
                  id: row.read<String>('budget_id'),
                  categoryId: row.read<String>('category_id'),
                  limitMinor: row.read<int>('limit_minor'),
                  createdAt: _rawDate(row.read<int>('created_at')),
                  updatedAt: _rawDate(row.read<int>('updated_at')),
                ),
                spentMinor: row.read<int>('spent_minor'),
              ),
          ],
        );
  }

  /// customSelect отдаёт даты сырыми int-секундами SQLite — та же
  /// нормализация, что и в кодеке экспорта.
  DateTime _rawDate(int epochSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);

  SimpleSelectStatement<$BudgetsTable, Budget> _aliveQuery() =>
      select(budgets)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.createdAt), (t) => OrderingTerm.asc(t.id)]);

  Future<Budget> _requireAlive(String id) async {
    final Budget? budget = await (select(budgets)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
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
  const BudgetProgress({required this.budget, required this.spentMinor});

  /// Бюджет, к которому относится прогресс.
  final Budget budget;

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
