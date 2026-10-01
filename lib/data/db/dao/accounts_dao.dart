import 'package:drift/drift.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'accounts_dao.g.dart';

/// Счёт вместе с вычисленным балансом.
///
/// Балансы не хранятся (§3): считаются запросом из `initial_balance_minor`
/// и живых операций, чтобы у данных был один источник истины.
class AccountBalance {
  const AccountBalance({required this.account, required this.balanceMinor});

  final Account account;

  /// Баланс в минорных единицах валюты счёта.
  final int balanceMinor;
}

/// Счета: CRUD, soft delete и балансы.
@DriftAccessor(tables: [Accounts, Transactions, Currencies])
class AccountsDao extends DatabaseAccessor<AppDatabase>
    with _$AccountsDaoMixin {
  AccountsDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт счёт. `sortOrder` по умолчанию — в конец списка.
  ///
  /// [interestReminderDate] — дата напоминания о процентах (v7, D-81):
  /// NULL = обычный счёт, дата = накопительный; UTC (§3).
  Future<Account> create({
    required String name,
    required AccountKind kind,
    required String currencyCode,
    int initialBalanceMinor = 0,
    int? sortOrder,
    bool excludeFromBalance = false,
    DateTime? interestReminderDate,
  }) async {
    final String trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw DataValidationException(
        'название счёта не может быть пустым',
        kind: DataFailure.invalidInput,
      );
    }
    await _requireAliveCurrency(currencyCode);
    final DateTime now = clock();
    return into(accounts).insertReturning(
      AccountsCompanion.insert(
        id: idGenerator(),
        name: trimmedName,
        kind: kind.dbValue,
        currencyCode: currencyCode,
        initialBalanceMinor: Value(initialBalanceMinor),
        sortOrder: Value(sortOrder ?? await _nextSortOrder()),
        // Флаг «не учитывать в балансе» (v5/D-54): null и false
        // равнозначны («учитывать»), поэтому храним именно bool.
        excludeFromBalance: Value(excludeFromBalance),
        // Дата напоминания о процентах (v7/D-81): UTC-строка или NULL.
        interestReminderDate: Value(
          interestReminderDate?.toUtc().toIso8601String(),
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живой счёт по id.
  Future<Account?> findById(String id) => (select(
    accounts,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Живые счета в порядке отображения (`sort_order`, затем название).
  Future<List<Account>> getAlive() => _aliveQuery().get();

  /// Поток живых счетов.
  Stream<List<Account>> watchAlive() => _aliveQuery().watch();

  /// Живые счета с вычисленными балансами — для списка счетов.
  Future<List<AccountBalance>> getBalances() async => _mapBalances(
    await customSelect(_balancesSql, readsFrom: {accounts, transactions}).get(),
  );

  /// Поток счетов с балансами: пересчитывается при изменении счетов и операций.
  Stream<List<AccountBalance>> watchBalances() => customSelect(
    _balancesSql,
    readsFrom: {accounts, transactions},
  ).watch().map(_mapBalances);

  /// Баланс одного счёта в минорных единицах (A8/R6): тот же
  /// [_balanceExpression] одним SQL-запросом по `WHERE a.id = ?` —
  /// вместо скана балансов всех счетов.
  ///
  /// Брошен [DataValidationException], если живого счёта с таким id нет.
  Future<int> balanceMinor(String accountId) async {
    final List<QueryRow> rows = await customSelect(
      'SELECT $_balanceExpression AS balance_minor '
      'FROM accounts AS a '
      'LEFT JOIN transactions AS t '
      'ON t.account_id = a.id AND t.deleted_at IS NULL '
      'WHERE a.deleted_at IS NULL AND a.id = ? '
      'GROUP BY a.id',
      variables: [Variable<String>(accountId)],
      readsFrom: {accounts, transactions},
    ).get();
    if (rows.isEmpty) {
      throw DataValidationException(
        'счёт $accountId не найден',
        kind: DataFailure.notFound,
      );
    }
    return rows.single.read<int>('balance_minor');
  }

  /// Меняет поля счёта; не переданные поля (`Value.absent()`) остаются как
  /// были. `updatedAt` обновляется всегда.
  ///
  /// Смена валюты запрещена, пока на счёт ссылаются живые операции: операция
  /// наследует валюту счёта (§3), и её сумма стала бы бессмысленной.
  /// [interestReminderDate] (v7, D-81) — Companion-параметр: не передан —
  /// не тронут; передан — перезаписывается (в т.ч. на NULL: сброс даты
  /// возвращает счёту статус обычного, D-81).
  Future<Account> updateAccount(
    String id, {
    Value<String> name = const Value.absent(),
    Value<AccountKind> kind = const Value.absent(),
    Value<String> currencyCode = const Value.absent(),
    Value<int> initialBalanceMinor = const Value.absent(),
    Value<int> sortOrder = const Value.absent(),
    Value<bool> excludeFromBalance = const Value.absent(),
    Value<DateTime?> interestReminderDate = const Value.absent(),
  }) async {
    final Account current = await _requireAlive(id);
    Value<String>? newName;
    if (name.present) {
      final String trimmed = name.value.trim();
      if (trimmed.isEmpty) {
        throw DataValidationException(
          'название счёта не может быть пустым',
          kind: DataFailure.invalidInput,
        );
      }
      newName = Value<String>(trimmed);
    }
    if (currencyCode.present && currencyCode.value != current.currencyCode) {
      await _requireAliveCurrency(currencyCode.value);
      final int linked = await _aliveTransactionsTouching(id);
      if (linked > 0) {
        throw DataValidationException(
          'у счёта ${current.name} есть живые операции ($linked) — '
          'смена валюты оставила бы их в прежней валюте',
          kind: DataFailure.accountHasTransactions,
        );
      }
    }
    await (update(accounts)..where((t) => t.id.equals(id))).write(
      AccountsCompanion(
        name: newName ?? const Value.absent(),
        kind: kind.present
            ? Value<String>(kind.value.dbValue)
            : const Value.absent(),
        currencyCode: currencyCode,
        initialBalanceMinor: initialBalanceMinor,
        sortOrder: sortOrder,
        excludeFromBalance: excludeFromBalance,
        interestReminderDate: interestReminderDate.present
            ? Value<String?>(
                interestReminderDate.value?.toUtc().toIso8601String(),
              )
            : const Value.absent(),
        updatedAt: Value(clock()),
      ),
    );
    return _requireAlive(id);
  }

  /// Есть ли у счёта живые операции (включая переводы, где счёт —
  /// зачисление). Read-only признак для UI (B2.2/D-24: кнопка «Сменить
  /// валюту» показывается только пока операций нет); DAO-отказ
  /// `accountHasTransactions` при самой смене остаётся последней линией —
  /// между чтением признака и записью возможна гонка.
  Future<bool> hasAliveTransactions(String id) async {
    final Expression<int> count = transactions.id.count();
    final TypedResult row =
        await (selectOnly(transactions)
              ..addColumns([count])
              ..where(
                transactions.deletedAt.isNull() &
                    (transactions.accountId.equals(id) |
                        transactions.targetAccountId.equals(id)),
              ))
            .getSingle();
    return (row.read(count) ?? 0) > 0;
  }

  /// Мягко удаляет счёт. Каскадов нет (§3), поэтому удалить счёт с живыми
  /// операциями нельзя — операции остались бы без счёта.
  Future<void> softDelete(String id) async {
    final Account current = await _requireAlive(id);
    final int linked = await _aliveTransactionsTouching(id);
    if (linked > 0) {
      throw DataValidationException(
        'у счёта ${current.name} есть живые операции ($linked) — сначала удалите их',
        kind: DataFailure.accountHasTransactions,
      );
    }
    final DateTime now = clock();
    await (update(accounts)..where((t) => t.id.equals(id))).write(
      AccountsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  SimpleSelectStatement<$AccountsTable, Account> _aliveQuery() =>
      select(accounts)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([
          (t) => OrderingTerm.asc(t.sortOrder),
          (t) => OrderingTerm.asc(t.name),
        ]);

  List<AccountBalance> _mapBalances(List<QueryRow> rows) => rows
      .map(
        (QueryRow row) => AccountBalance(
          account: accounts.map(row.data),
          balanceMinor: row.read<int>('balance_minor'),
        ),
      )
      .toList();

  Future<Account> _requireAlive(String id) async {
    final Account? account = await findById(id);
    if (account == null) {
      throw DataValidationException(
        'счёт $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return account;
  }

  Future<void> _requireAliveCurrency(String code) async {
    final Currency? currency =
        await (select(currencies)
              ..where((t) => t.code.equals(code) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (currency == null) {
      throw DataValidationException(
        'валюта $code не найдена в справочнике',
        kind: DataFailure.invalidInput,
      );
    }
  }

  Future<int> _nextSortOrder() async {
    final Expression<int> maxOrder = accounts.sortOrder.max();
    final TypedResult row =
        await (selectOnly(accounts)
              ..addColumns([maxOrder])
              ..where(accounts.deletedAt.isNull()))
            .getSingle();
    return (row.read(maxOrder) ?? -1) + 1;
  }

  /// Живые операции, где счёт — источник или счёт зачисления перевода.
  Future<int> _aliveTransactionsTouching(String id) async {
    final Expression<int> count = transactions.id.count();
    final TypedResult row =
        await (selectOnly(transactions)
              ..addColumns([count])
              ..where(
                transactions.deletedAt.isNull() &
                    (transactions.accountId.equals(id) |
                        transactions.targetAccountId.equals(id)),
              ))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Баланс: начальный остаток + доходы − расходы − исходящие переводы
  /// + входящие переводы. Считается только по живым записям.
  ///
  /// Входящий перевод зачисляется суммой зачисления (D-17):
  /// target_amount_minor — сумма в валюте целевого счёта, обязательная
  /// для мультивалютного перевода; у одно-валютного она NULL, и SUM
  /// падает на amount_minor. Смешения валют нет: D-17 запрещает
  /// target_amount_minor при совпадающих валютах.
  static const String _balanceExpression = '''
a.initial_balance_minor
  + COALESCE(SUM(CASE t.type
      WHEN 'income' THEN t.amount_minor
      WHEN 'expense' THEN -t.amount_minor
      WHEN 'transfer' THEN -t.amount_minor
      ELSE 0 END), 0)
  + COALESCE((
      SELECT SUM(COALESCE(incoming.target_amount_minor, incoming.amount_minor))
      FROM transactions AS incoming
      WHERE incoming.type = 'transfer'
        AND incoming.target_account_id = a.id
        AND incoming.deleted_at IS NULL
    ), 0)''';

  static const String _balanceFrom = '''
FROM accounts AS a
LEFT JOIN transactions AS t
       ON t.account_id = a.id AND t.deleted_at IS NULL
WHERE a.deleted_at IS NULL''';

  static const String _balancesSql =
      'SELECT a.*, $_balanceExpression AS balance_minor $_balanceFrom '
      'GROUP BY a.id ORDER BY a.sort_order, a.name';
}
