import 'package:drift/drift.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'transactions_dao.g.dart';

/// Расходы одной категории за месяц (M2, дашборд).
class CategoryExpense {
  const CategoryExpense({
    required this.categoryId,
    required this.categoryName,
    required this.amountMinor,
  });

  final String categoryId;
  final String categoryName;
  final int amountMinor;
}

/// Доходы и расходы одного календарного месяца (M2, динамика).
///
/// [monthKey] — канонический ключ `YYYY-MM` из strftime (UTC). Изменяемый
/// класс: DAO собирает итоги из двух SQL-групп (доходной и расходной).
class MonthTotals {
  MonthTotals({required this.monthKey});

  final String monthKey;
  int incomeMinor = 0;
  int expenseMinor = 0;
}

/// Фильтр списка операций (счёт, категория, вид, период, поиск по заметке).
///
/// Все условия объединяются по «И»; пустой фильтр означает «все живые
/// операции».
class TransactionFilter {
  const TransactionFilter({
    this.accountId,
    this.categoryId,
    this.type,
    this.from,
    this.to,
    this.search,
  });

  /// Операция затрагивает счёт: списание или зачисление перевода.
  final String? accountId;

  /// Категория операции.
  final String? categoryId;

  /// Тип операции.
  final TransactionType? type;

  /// Начало периода, включительно.
  final DateTime? from;

  /// Конец периода, исключительно: так удобно задавать границы месяца.
  final DateTime? to;

  /// Подстрока поиска по заметке (`LIKE`; регистр не учитывается для
  /// латиницы — ограничение SQLite без ICU).
  final String? search;
}

/// Операции: доход, расход, перевод между счетами.
///
/// Инкапсулирует правила §3: суммы всегда положительные (знак задаёт тип),
/// валюта наследуется от счёта, категории доходов и расходов не
/// смешиваются, у перевода нет категории.
@DriftAccessor(tables: [Transactions, Accounts, Categories])
class TransactionsDao extends DatabaseAccessor<AppDatabase>
    with _$TransactionsDaoMixin {
  TransactionsDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт операцию. `date` по умолчанию — текущий момент, `amountMinor` —
  /// всегда положительная сумма в минорных единицах.
  ///
  /// Для перевода `accountId` — счёт списания, `targetAccountId` — счёт
  /// зачисления, категории у перевода быть не может (§3).
  Future<Transaction> create({
    required TransactionType type,
    required String accountId,
    String? targetAccountId,
    String? categoryId,
    required int amountMinor,
    DateTime? date,
    String? note,
  }) async {
    if (amountMinor <= 0) {
      throw DataValidationException(
        'сумма должна быть больше нуля: в БД сумма хранится без знака (§3)',
        kind: DataFailure.invalidInput,
      );
    }
    final Account account = await _requireAliveAccount(accountId);
    await _validateShape(
      type: type,
      account: account,
      targetAccountId: targetAccountId,
      categoryId: categoryId,
    );
    final DateTime now = clock();
    return into(transactions).insertReturning(
      TransactionsCompanion.insert(
        id: idGenerator(),
        type: type.dbValue,
        accountId: account.id,
        targetAccountId: Value(targetAccountId),
        categoryId: Value(categoryId),
        amountMinor: amountMinor,
        // M1: операция наследует валюту счёта; мультивалютные переводы — M3.
        currencyCode: account.currencyCode,
        date: date ?? now,
        note: Value(optionalText(note)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живая операция по id.
  Future<Transaction?> findById(String id) => (select(
    transactions,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Поток одной операции.
  Stream<Transaction?> watchById(String id) => (select(
    transactions,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).watchSingleOrNull();

  /// Живые операции по фильтру, новые сверху.
  Future<List<Transaction>> getFiltered([
    TransactionFilter filter = const TransactionFilter(),
  ]) => _filteredQuery(filter).get();

  /// Поток живых операций по фильтру — для списка операций.
  Stream<List<Transaction>> watchFiltered([
    TransactionFilter filter = const TransactionFilter(),
  ]) => _filteredQuery(filter).watch();

  /// Меняет операцию; не переданные поля (`Value.absent()`) остаются как
  /// были, `Value(null)` очищает необязательное поле.
  ///
  /// Тип операции и счёт не меняются: это была бы другая операция —
  /// удалите её и создайте новую.
  Future<Transaction> updateTransaction(
    String id, {
    Value<int> amountMinor = const Value.absent(),
    Value<DateTime> date = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Value<String?> categoryId = const Value.absent(),
    Value<String?> targetAccountId = const Value.absent(),
  }) async {
    final Transaction current = await _requireAlive(id);
    if (amountMinor.present && amountMinor.value <= 0) {
      throw DataValidationException(
        'сумма должна быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
    await _validateShape(
      type: TransactionType.fromDb(current.type),
      account: await _requireAliveAccount(current.accountId),
      targetAccountId: targetAccountId.present
          ? targetAccountId.value
          : current.targetAccountId,
      categoryId: categoryId.present ? categoryId.value : current.categoryId,
    );
    await (update(transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        amountMinor: amountMinor,
        date: date,
        note: note.present
            ? Value<String?>(optionalText(note.value))
            : const Value.absent(),
        categoryId: categoryId,
        targetAccountId: targetAccountId,
        updatedAt: Value(clock()),
      ),
    );
    return _requireAlive(id);
  }

  /// Мягко удаляет операцию: строка остаётся в таблице, `deleted_at`
  /// заполняется (§3).
  Future<void> softDelete(String id) async {
    await _requireAlive(id);
    final DateTime now = clock();
    await (update(transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  SimpleSelectStatement<$TransactionsTable, Transaction> _filteredQuery(
    TransactionFilter filter,
  ) {
    final List<Expression<bool>> conditions = <Expression<bool>>[];
    final String? accountId = filter.accountId;
    if (accountId != null) {
      conditions.add(
        transactions.accountId.equals(accountId) |
            transactions.targetAccountId.equals(accountId),
      );
    }
    final String? categoryId = filter.categoryId;
    if (categoryId != null) {
      conditions.add(transactions.categoryId.equals(categoryId));
    }
    final TransactionType? type = filter.type;
    if (type != null) {
      conditions.add(transactions.type.equals(type.dbValue));
    }
    final DateTime? from = filter.from;
    if (from != null) {
      conditions.add(transactions.date.isBiggerOrEqualValue(from));
    }
    final DateTime? to = filter.to;
    if (to != null) {
      conditions.add(transactions.date.isSmallerThanValue(to));
    }
    final String? search = optionalText(filter.search);
    if (search != null) {
      conditions.add(transactions.note.like('%$search%'));
    }
    return select(transactions)
      ..where((t) => _allOf(<Expression<bool>>[t.deletedAt.isNull(), ...conditions]))
      ..orderBy([
        (t) => OrderingTerm.desc(t.date),
        (t) => OrderingTerm.desc(t.createdAt),
      ]);
  }

  Expression<bool> _allOf(List<Expression<bool>> conditions) => conditions
      .fold<Expression<bool>>(
        const Constant<bool>(true),
        (Expression<bool> left, Expression<bool> right) => left & right,
      );

  Future<Transaction> _requireAlive(String id) async {
    final Transaction? transaction = await findById(id);
    if (transaction == null) {
      throw DataValidationException(
        'операция $id не найдена',
        kind: DataFailure.notFound,
      );
    }
    return transaction;
  }

  Future<Account> _requireAliveAccount(String id) async {
    final Account? account = await (select(
      accounts,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (account == null) {
      throw DataValidationException(
        'счёт $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return account;
  }

  Future<void> _validateShape({
    required TransactionType type,
    required Account account,
    required String? targetAccountId,
    required String? categoryId,
  }) async {
    switch (type) {
      case TransactionType.transfer:
        if (targetAccountId == null) {
          throw DataValidationException(
            'для перевода нужен счёт зачисления',
            kind: DataFailure.invalidInput,
          );
        }
        if (targetAccountId == account.id) {
          throw DataValidationException(
            'счёт списания и зачисления перевода должны различаться',
            kind: DataFailure.invalidInput,
          );
        }
        if (categoryId != null) {
          throw DataValidationException(
            'у перевода не бывает категории (§3)',
            kind: DataFailure.invalidInput,
          );
        }
        await _requireAliveAccount(targetAccountId);
      case TransactionType.income || TransactionType.expense:
        if (targetAccountId != null) {
          throw DataValidationException(
            'счёт зачисления указывается только для перевода',
            kind: DataFailure.invalidInput,
          );
        }
        if (categoryId != null) {
          await _requireMatchingCategory(categoryId: categoryId, type: type);
        }
    }
  }

  Future<void> _requireMatchingCategory({
    required String categoryId,
    required TransactionType type,
  }) async {
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
    final CategoryKind expected = type == TransactionType.income
        ? CategoryKind.income
        : CategoryKind.expense;
    if (CategoryKind.fromDb(category.kind) != expected) {
      throw DataValidationException(
        'категория «${category.name}» другого вида — операция не может её использовать',
        kind: DataFailure.parentInvalid,
      );
    }
  }

  /// Расходы по категориям за календарный месяц, в который попадает
  /// [moment] (M2, дашборд). Переводы не считаются, мягко удалённые —
  /// тоже; категории без расходов в списке не появляются. Имена берутся
  /// из живых категорий JOIN'ом; одна категория — одна строка.
  Future<List<CategoryExpense>> expensesByCategoryForMonth({
    required DateTime moment,
  }) async {
    final DateTime from = monthStart(moment);
    final DateTime to = nextMonthStart(from);
    final Expression<int> total = transactions.amountMinor.sum();
    final List<TypedResult> rows = await (selectOnly(transactions)
          .join([
            innerJoin(
              categories,
              categories.id.equalsExp(transactions.categoryId),
            ),
          ])
          ..addColumns([categories.id, categories.name, total])
          ..where(
            transactions.deletedAt.isNull() &
                transactions.type.equals(TransactionType.expense.dbValue) &
                transactions.date.isBiggerOrEqualValue(from) &
                transactions.date.isSmallerThanValue(to) &
                categories.deletedAt.isNull(),
          )
          ..groupBy([categories.id])
          ..orderBy([
            OrderingTerm.desc(total),
            OrderingTerm.asc(categories.name),
          ]))
        .get();
    return <CategoryExpense>[
      for (final TypedResult row in rows)
        CategoryExpense(
          categoryId: row.read(categories.id)!,
          categoryName: row.read(categories.name)!,
          amountMinor: row.read(total) ?? 0,
        ),
    ];
  }

  /// Доходы и расходы по календарным месяцам (M2, динамика на дашборде):
  /// группы внутри [from, to) по границам месяцев в UTC. Переводы не
  /// участвуют, мягко удалённые не учитываются. Месяцы без операций в
  /// списке отсутствуют — UI восстанавливает непрерывность сам.
  ///
  /// Месяц операции определяет `strftime('%Y-%m', date, 'unixepoch')`:
  /// date хранится как unix-секунды, без модификатора 'unixepoch' SQLite
  /// трактует целое как юлианские дни — месяц был бы неверным. С
  /// 'unixepoch' секунды читаются как UTC — ровно правило месяцев (§3).
  /// Raw SQL по образцу [BudgetsDao.watchProgress]: обычный select здесь
  /// громоздок из-за группировки по выражению.
  Future<List<MonthTotals>> totalsByMonth({
    required DateTime from,
    required DateTime to,
  }) async {
    if (!to.isAfter(from)) {
      throw DataValidationException(
        'период пуст: to должен быть позже from',
        kind: DataFailure.invalidInput,
      );
    }
    final List<QueryRow> rows = await customSelect(
      "SELECT strftime('%Y-%m', date, 'unixepoch') AS month_key, type, "
      'SUM(amount_minor) AS total '
      'FROM transactions '
      'WHERE deleted_at IS NULL AND date >= ? AND date < ? '
      "AND type IN ('expense', 'income') "
      'GROUP BY month_key, type '
      'ORDER BY month_key',
      variables: [
        Variable<int>(from.millisecondsSinceEpoch ~/ 1000),
        Variable<int>(to.millisecondsSinceEpoch ~/ 1000),
      ],
      readsFrom: {transactions},
    ).get();
    final Map<String, MonthTotals> byMonth = <String, MonthTotals>{};
    for (final QueryRow row in rows) {
      final String key = row.read<String>('month_key');
      final TransactionType type = TransactionType.fromDb(
        row.read<String>('type'),
      );
      final int amount = row.read<int>('total');
      final MonthTotals totals = byMonth.putIfAbsent(
        key,
        () => MonthTotals(monthKey: key),
      );
      if (type == TransactionType.income) {
        totals.incomeMinor = amount;
      } else {
        totals.expenseMinor = amount;
      }
    }
    return byMonth.values.toList()
      ..sort(
        (MonthTotals a, MonthTotals b) => a.monthKey.compareTo(b.monthKey),
      );
  }
}
