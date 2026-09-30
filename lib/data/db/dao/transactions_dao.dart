import 'package:drift/drift.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'transactions_dao.g.dart';

/// Расходы одной категории за месяц в базовой валюте (M3-шаг 5, D-18):
/// сумма конвертированных построчно операций. Значения — минорные
/// единицы базовой валюты (экспонент 2).
class CategoryExpenseBase {
  const CategoryExpenseBase({
    required this.categoryId,
    required this.categoryName,
    required this.amountMinor,
  });

  final String categoryId;
  final String categoryName;
  final int amountMinor;
}

/// Доходы и расходы одного календарного месяца в базовой валюте
/// (M3-шаг 5, D-18). Изменяемый класс:
/// DAO собирает итоги из групп конвертированных строк.
class MonthTotalsBase {
  MonthTotalsBase({required this.monthKey});

  final String monthKey;
  int incomeMinor = 0;
  int expenseMinor = 0;
}

/// Строка списка операций (A9/R7): операция + имена счёта, счёта
/// зачисления и категории из одного JOIN-запроса — плитке не нужны
/// подписки на списки счетов и категорий (уходят N+1 watch).
///
/// Имена берутся на момент чтения; мягко удалённые записи сохраняют имя
/// (ссылки из истории валидны), отсутствующие дают null.
class TransactionView {
  const TransactionView({
    required this.transaction,
    required this.accountName,
    this.accountCurrencyCode,
    this.targetAccountName,
    this.targetCurrencyCode,
    this.categoryName,
    this.hasAttachment = false,
  });

  /// Сама операция.
  final Transaction transaction;

  /// Имя счёта операции (для перевода — счёт списания).
  final String accountName;

  /// Код валюты счёта операции (для перевода — счёт списания); у
  /// отсутствующей строки — null (несогласованный импорт).
  final String? accountCurrencyCode;

  /// Имя счёта зачисления перевода; у не-перевода — null.
  final String? targetAccountName;

  /// Код валюты счёта зачисления перевода; у не-перевода и отсутствующей
  /// строки — null.
  final String? targetCurrencyCode;

  /// Имя категории; у перевода и операции без категории — null.
  final String? categoryName;

  /// У операции есть живое вложение (v6, M5-шаг 6в): маркер в списке.
  /// LEFT JOIN по одной строке на операцию; файл на диске не проверяется
  /// — это обязанность карточки вложения, список смотрит только БД.
  final bool hasAttachment;
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
@DriftAccessor(tables: [
  Transactions,
  Accounts,
  Categories,
  Currencies,
  Attachments,
])
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
  ///
  /// `targetAmountMinor` — сумма зачисления перевода в минорных единицах
  /// целевого счёта (D-17): обязательна, когда валюты живых счетов перевода
  /// различаются, и обязана быть NULL, когда совпадают; у не-перевода
  /// всегда NULL. Правила переводов — D-17, отказы — [DataValidationException].
  Future<Transaction> create({
    required TransactionType type,
    required String accountId,
    String? targetAccountId,
    String? categoryId,
    required int amountMinor,
    int? targetAmountMinor,
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
    final int? targetAmount = await _validateTransferAmounts(
      type: type,
      account: account,
      targetAccountId: targetAccountId,
      amountMinor: amountMinor,
      targetAmountMinor: targetAmountMinor,
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
        targetAmountMinor: Value(targetAmount),
        // M1: валюта списания наследуется от счёта; валюта зачисления —
        // валюта целевого счёта (считывается из базы в rules D-17 выше).
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

  /// Живые операции по фильтру, новые сверху.
  Future<List<Transaction>> getFiltered([
    TransactionFilter filter = const TransactionFilter(),
  ]) async => [
        for (final QueryRow row in await _filteredSelect(filter).get())
          transactions.map(row.data),
      ];

  /// Поток операций с именами счетов и категории (R7/R8): один
  /// JOIN-запрос вместо двух watch-подписок на каждую плитку списка.
  /// Сортировка и фильтр — те же, что у [getFiltered].
  Stream<List<TransactionView>> watchFilteredView([
    TransactionFilter filter = const TransactionFilter(),
  ]) {
    // Имена из живых и мягко удалённых записей (ссылки истории валидны);
    // отсутствующие строки (несогласованный импорт) дают NULL — UI
    // подставит локализованный текст «Счёт удалён»/«Без категории».
    // Живое вложение (6в) — тем же LEFT JOIN одним запросом: живых
    // вложений на операцию не больше одного (правило DAO, D-63).
    final (String whereSql, List<Variable> variables) =
        _filteredSqlParts(filter);
    return customSelect(
      'SELECT t.*, '
      'a.name AS account_name, '
      'a.currency_code AS account_currency_code, '
      'target.name AS target_account_name, '
      'target.currency_code AS target_currency_code, '
      'c.name AS category_name, '
      'att.id IS NOT NULL AS has_attachment '
      'FROM transactions AS t '
      'JOIN accounts AS a ON a.id = t.account_id '
      'LEFT JOIN accounts AS target ON target.id = t.target_account_id '
      'LEFT JOIN categories AS c ON c.id = t.category_id '
      'LEFT JOIN attachments AS att '
      'ON att.transaction_id = t.id AND att.deleted_at IS NULL '
      '$whereSql ORDER BY t.date DESC, t.created_at DESC',
      variables: variables,
      readsFrom: {transactions, accounts, categories, attachments},
    ).watch().map(_readTransactionViews);
  }

  List<TransactionView> _readTransactionViews(List<QueryRow> rows) =>
      <TransactionView>[
        for (final QueryRow row in rows)
          TransactionView(
            transaction: transactions.map(row.data),
            accountName: row.read<String>('account_name'),
            accountCurrencyCode: row.read<String?>('account_currency_code'),
            targetAccountName: row.read<String?>('target_account_name'),
            targetCurrencyCode: row.read<String?>('target_currency_code'),
            categoryName: row.read<String?>('category_name'),
            hasAttachment: row.read<bool>('has_attachment'),
          ),
      ];

  /// Меняет операцию; не переданные поля (`Value.absent()`) остаются как
  /// были, `Value(null)` очищает необязательное поле.
  ///
  /// Тип операции и счёт не меняются: это была бы другая операция —
  /// удалите её и создайте новую.
  ///
  /// `targetAmountMinor` (D-17): у мультивалютного перевода правится
  /// только вместе с `amountMinor` (правка ровно одной из двух сумм —
  /// отказ); у одно-валютного перевода и не-перевода обязана быть NULL
  /// (передача значения — отказ).
  Future<Transaction> updateTransaction(
    String id, {
    Value<int> amountMinor = const Value.absent(),
    Value<int?> targetAmountMinor = const Value.absent(),
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
    final TransactionType type = TransactionType.fromDb(current.type);
    final Account account = await _requireAliveAccount(current.accountId);
    await _validateShape(
      type: type,
      account: account,
      targetAccountId: targetAccountId.present
          ? targetAccountId.value
          : current.targetAccountId,
      categoryId: categoryId.present ? categoryId.value : current.categoryId,
    );
    // D-17: обе суммы правятся только вместе — валидируем ПОСЛЕ и
    // отменяем всю правку, если пара неполна или не соответствует валютам.
    final String? effectiveTargetAccountId = targetAccountId.present
        ? targetAccountId.value
        : current.targetAccountId;
    if (amountMinor.present != targetAmountMinor.present) {
      final bool isMultiCurrency = await _isMultiCurrencyTransfer(
        type,
        account,
        effectiveTargetAccountId,
      );
      if (isMultiCurrency) {
        throw DataValidationException(
          'у мультивалютного перевода суммы списания и зачисления правятся '
          'только вместе: передана только одна из двух',
          kind: DataFailure.invalidInput,
        );
      }
      // Одно-валютная операция правит amount без target — допустимо;
      // target без amount будет отвергнут проверкой NULL ниже.
    }
    final int effectiveAmount =
        amountMinor.present ? amountMinor.value : current.amountMinor;
    final int? effectiveTargetAmount = targetAmountMinor.present
        ? targetAmountMinor.value
        : current.targetAmountMinor;
    await _validateTransferAmounts(
      type: type,
      account: account,
      targetAccountId: effectiveTargetAccountId,
      amountMinor: effectiveAmount,
      targetAmountMinor: effectiveTargetAmount,
    );
    await (update(transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        amountMinor: amountMinor,
        targetAmountMinor: targetAmountMinor,
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

  /// SELECT живых операций по фильтру (общий источник для get/watch —
  /// и view-варианта: одно место фильтрации, не дублируется).
  Selectable<QueryRow> _filteredSelect(TransactionFilter filter) {
    final (String whereSql, List<Variable> variables) =
        _filteredSqlParts(filter);
    return customSelect(
      'SELECT t.* FROM transactions AS t '
      '$whereSql ORDER BY t.date DESC, t.created_at DESC',
      variables: variables,
      readsFrom: {transactions},
    );
  }

  /// WHERE-часть живого фильтра: SQL-строка и связанные переменные.
  /// Даты привязываются секундами unix-epoch — drift хранит DateTime
  /// так же (§3, грабли дат-секунд).
  (String, List<Variable>) _filteredSqlParts(TransactionFilter filter) {
    final List<String> conditions = <String>['t.deleted_at IS NULL'];
    final List<Variable> variables = <Variable>[];
    final String? accountId = filter.accountId;
    if (accountId != null) {
      conditions.add('(t.account_id = ? OR t.target_account_id = ?)');
      variables
        ..add(Variable<String>(accountId))
        ..add(Variable<String>(accountId));
    }
    final String? categoryId = filter.categoryId;
    if (categoryId != null) {
      conditions.add('t.category_id = ?');
      variables.add(Variable<String>(categoryId));
    }
    final TransactionType? type = filter.type;
    if (type != null) {
      conditions.add('t.type = ?');
      variables.add(Variable<String>(type.dbValue));
    }
    final DateTime? from = filter.from;
    if (from != null) {
      conditions.add('t.date >= ?');
      variables.add(Variable<int>(from.millisecondsSinceEpoch ~/ 1000));
    }
    final DateTime? to = filter.to;
    if (to != null) {
      conditions.add('t.date < ?');
      variables.add(Variable<int>(to.millisecondsSinceEpoch ~/ 1000));
    }
    final String? search = optionalText(filter.search);
    if (search != null) {
      // Экранируем спецсимволы LIKE (A12): пользователь ищет подстроку,
      // «100%» должно находить «100%», а не «100x».
      const String escape = r'\';
      final String escaped = search
          .replaceAll(escape, '$escape$escape')
          .replaceAll('%', '$escape%')
          .replaceAll('_', '${escape}_');
      // Escape-символ задан односимвольной строкой в SQL-литерале:
      // "ESCAPE '\\'" (в сыром Dart — r"ESCAPE '\\'").
      conditions.add(r"t.note LIKE ? ESCAPE '\'");
      variables.add(Variable<String>('%$escaped%'));
    }
    return (' WHERE ${conditions.join(' AND ')}', variables);
  }

  /// Правила сумм перевода (D-17) для Effective-значений create/update.
  /// Возвращает сумму зачисления для записи (NULL для одно-валютного
  /// перевода и не-перевода); отказы — [DataValidationException]:
  ///
  /// - валюты живых счетов перевода различаются ⇔ обе суммы обязательны
  ///   (правятся только вместе — см. [updateTransaction]);
  /// - валюты совпадают ⇔ target_amount_minor обязана быть NULL.
  Future<int?> _validateTransferAmounts({
    required TransactionType type,
    required Account account,
    required String? targetAccountId,
    required int amountMinor,
    required int? targetAmountMinor,
  }) async {
    if (type != TransactionType.transfer) {
      if (targetAmountMinor != null) {
        throw DataValidationException(
          'сумма зачисления задаётся только у перевода',
          kind: DataFailure.invalidInput,
        );
      }
      return null;
    }
    // Форма перевода уже проверена _validateShape: targetAccountId задан
    // и жив, отличается от счёта списания.
    final Account target = await _requireAliveAccount(targetAccountId!);
    if (target.currencyCode != account.currencyCode) {
      if (targetAmountMinor == null) {
        throw DataValidationException(
          'перевод между разными валютами (${account.currencyCode} → '
          '${target.currencyCode}) требует обеих сумм: списания и зачисления',
          kind: DataFailure.invalidInput,
        );
      }
      if (targetAmountMinor <= 0) {
        throw DataValidationException(
          'сумма зачисления должна быть больше нуля: в БД сумма хранится '
          'без знака (§3)',
          kind: DataFailure.invalidInput,
        );
      }
      return targetAmountMinor;
    }
    if (targetAmountMinor != null) {
      throw DataValidationException(
        'перевод в одной валюте (${account.currencyCode}) хранит только '
        'сумму списания: target_amount_minor обязана быть NULL (D-17)',
        kind: DataFailure.invalidInput,
      );
    }
    return null;
  }

  /// Мультивалютный ли это перевод (для правила «правится только вместе»):
  /// перевод между живыми счетами в разных валютах.
  Future<bool> _isMultiCurrencyTransfer(
    TransactionType type,
    Account account,
    String? targetAccountId,
  ) async {
    if (type != TransactionType.transfer || targetAccountId == null) {
      return false;
    }
    final Account? target = await (select(accounts)..where(
          (t) => t.id.equals(targetAccountId) & t.deletedAt.isNull(),
        )).getSingleOrNull();
    if (target == null) {
      return false; // форма уже отвергнута _validateShape
    }
    return target.currencyCode != account.currencyCode;
  }

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

  // -----------------------------------------------------------------
  // Агрегаты в базовой валюте (M3-шаг 5, D-18).
  //
  // SQL не умеет округлять «до минорной единицы базы» построчно (правило
  // D-18/D-22: каждая операция конвертируется до суммирования), поэтому
  // SELECT отдаёт живые операции-кандидаты вместе с текущим курсом их
  // валюты, а конвертация и группировка — построчно в Dart через
  // `convertMinor`. Курс читается самим запросом (JOIN currencies) и входит
  // в readsFrom: смена курса перевыполняет SELECT и пересчитывает поток —
  // без кэша и без ручного совмещения потоков (D-18).
  // -----------------------------------------------------------------

  /// Живые операции-кандидаты отчётных агрегатов в периоде [from, to):
  /// суммы в минорных единицах своей валюты, ключ месяца (UTC, §3 — как в
  /// замке P3), живая категория и текущий курс валюты операции к базовой.
  /// Переводы отсекаются списком [types] (перевод — не расход/доход, §3);
  /// операция с валютой без строки справочника получает курс 1
  /// (несогласованный импорт не выпадает из отчётов).
  Selectable<QueryRow> _baseAggregateOpsSelect(
    DateTime from,
    DateTime to,
    List<String> types,
  ) => customSelect(
        'SELECT t.id AS tx_id, t.type AS type, '
        't.amount_minor AS amount_minor, t.currency_code AS currency_code, '
        "strftime('%Y-%m', t.date, 'unixepoch') AS month_key, "
        'c.id AS category_id, c.name AS category_name, '
        'COALESCE(cur.rate_to_base, 1.0) AS rate '
        'FROM transactions AS t '
        'JOIN categories AS c ON c.id = t.category_id AND c.deleted_at IS NULL '
        'LEFT JOIN currencies AS cur ON cur.code = t.currency_code '
        'WHERE t.deleted_at IS NULL AND t.type IN (${types.map((_) => '?').join(', ')}) '
        'AND t.date >= ? AND t.date < ?',
        variables: <Variable>[
          for (final String type in types) Variable<String>(type),
          Variable<int>(from.millisecondsSinceEpoch ~/ 1000),
          Variable<int>(to.millisecondsSinceEpoch ~/ 1000),
        ],
        readsFrom: {transactions, categories, currencies},
      );

  /// Расходы по категориям за месяц [moment] в базовой валюте (D-18):
  /// построчная конвертация каждой операции до суммирования, half-up по
  /// модулю (D-22). Порядок строк — по конвертированной сумме, затем по
  /// имени (как в исходном агрегате M2).
  Future<List<CategoryExpenseBase>> expensesByCategoryForMonthInBase({
    required DateTime moment,
  }) async {
    final List<QueryRow> rows = await _baseAggregateOpsSelect(
      monthStart(moment),
      nextMonthStart(moment),
      <String>[TransactionType.expense.dbValue],
    ).get();
    return _categoryExpensesInBase(rows);
  }

  /// Живой вариант [expensesByCategoryForMonthInBase]: пересчитывается при
  /// изменении операций, категорий и курсов валют (D-18).
  Stream<List<CategoryExpenseBase>> watchExpensesByCategoryForMonthInBase({
    required DateTime moment,
  }) => _baseAggregateOpsSelect(
        monthStart(moment),
        nextMonthStart(moment),
        <String>[TransactionType.expense.dbValue],
      ).watch().map(_categoryExpensesInBase);

  /// Группирует конвертированные построчно операции по категориям.
  List<CategoryExpenseBase> _categoryExpensesInBase(List<QueryRow> rows) {
    final Map<String, List<Object>> byCategory = <String, List<Object>>{};
    for (final QueryRow row in rows) {
      final int converted = _convertToBase(row);
      final String categoryId = row.read<String>('category_id');
      final List<Object>? bucket = byCategory[categoryId];
      if (bucket == null) {
        byCategory[categoryId] = <Object>[
          row.read<String>('category_name'),
          converted,
        ];
      } else {
        bucket[1] = (bucket[1] as int) + converted;
      }
    }
    final List<CategoryExpenseBase> result = <CategoryExpenseBase>[
      for (final MapEntry<String, List<Object>> entry in byCategory.entries)
        CategoryExpenseBase(
          categoryId: entry.key,
          categoryName: entry.value[0] as String,
          amountMinor: entry.value[1] as int,
        ),
    ]
      ..sort((CategoryExpenseBase a, CategoryExpenseBase b) {
        final int byAmount = b.amountMinor.compareTo(a.amountMinor);
        return byAmount != 0 ? byAmount : a.categoryName.compareTo(b.categoryName);
      });
    return result;
  }

  /// Конвертирует одну операцию в базовую валюту: `convertMinor` с текущим
  /// курсом из строки запроса и экспонентом валюты-источника (D-22).
  int _convertToBase(QueryRow row) => convertMinor(
        row.read<int>('amount_minor'),
        row.read<double>('rate'),
        exponent: currencyExponentByCode(row.read<String>('currency_code')),
      );

  /// Доходы и расходы по календарным месяцам в базовой валюте (D-18):
  /// построчная конвертация, полугодовое окно — как в исходной динамике.
  /// Месяцы без операций в списке отсутствуют — UI восстанавливает
  /// непрерывность сам (как в M2).
  Future<List<MonthTotalsBase>> totalsByMonthInBase({
    required DateTime from,
    required DateTime to,
  }) async {
    if (!to.isAfter(from)) {
      throw DataValidationException(
        'период пуст: to должен быть позже from',
        kind: DataFailure.invalidInput,
      );
    }
    return _readMonthTotalsInBase(
      await _baseAggregateOpsSelect(
        from,
        to,
        <String>[TransactionType.income.dbValue, TransactionType.expense.dbValue],
      ).get(),
    );
  }

  /// Живой вариант [totalsByMonthInBase]: пересчитывается при изменении
  /// операций, категорий и курсов валют (D-18).
  Stream<List<MonthTotalsBase>> watchTotalsByMonthInBase({
    required DateTime from,
    required DateTime to,
  }) {
    if (!to.isAfter(from)) {
      throw DataValidationException(
        'период пуст: to должен быть позже from',
        kind: DataFailure.invalidInput,
      );
    }
    return _baseAggregateOpsSelect(
      from,
      to,
      <String>[TransactionType.income.dbValue, TransactionType.expense.dbValue],
    ).watch().map(_readMonthTotalsInBase);
  }

  /// Группирует конвертированные построчно операции по месяцам и типам;
  /// месяцы сортируются по ключу (как в исходной динамике M2).
  List<MonthTotalsBase> _readMonthTotalsInBase(List<QueryRow> rows) {
    final Map<String, MonthTotalsBase> byMonth = <String, MonthTotalsBase>{};
    for (final QueryRow row in rows) {
      final int converted = _convertToBase(row);
      final String key = row.read<String>('month_key');
      final TransactionType type = TransactionType.fromDb(
        row.read<String>('type'),
      );
      final MonthTotalsBase totals = byMonth.putIfAbsent(
        key,
        () => MonthTotalsBase(monthKey: key),
      );
      if (type == TransactionType.income) {
        totals.incomeMinor += converted;
      } else {
        totals.expenseMinor += converted;
      }
    }
    return byMonth.values.toList()
      ..sort(
        (MonthTotalsBase a, MonthTotalsBase b) =>
            a.monthKey.compareTo(b.monthKey),
      );
  }
}
