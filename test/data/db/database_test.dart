// Тест схемы БД v1 на in-memory SQLite: таблицы, типы колонок, индексы,
// вставка/выборка, soft delete и включённые внешние ключи.
// isNull из drift — конструктор SQL-выражения; в тесте нужен матчер
// с таким же именем из flutter_test, поэтому drift-вариант скрыт.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';

/// Фиксированное «сейчас» в UTC: тесты не должны зависеть от часов.
final DateTime fixedNow = DateTime.utc(2026, 9, 24, 12);

/// Имена таблиц, созданных в схеме.
Future<Set<String>> tableNames(AppDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

/// Типы колонок таблицы (имя → тип SQLite).
Future<Map<String, String>> columnTypes(AppDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('PRAGMA table_info($table)')
      .get();
  return {
    for (final QueryRow row in rows) row.read<String>('name'): row.read<String>('type'),
  };
}

/// Индексы таблицы.
Future<Set<String>> indexNames(AppDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
        variables: [Variable<String>(table)],
      )
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('schemaVersion = 1', () {
    expect(db.schemaVersion, 1);
  });

  test('схема создаёт четыре таблицы из §3', () async {
    expect(
      await tableNames(db),
      containsAll(<String>[
        'currencies',
        'accounts',
        'categories',
        'transactions',
      ]),
    );
  });

  test('ключ — UUID-текст, деньги — целые в минорных единицах', () async {
    final Map<String, String> account = await columnTypes(db, 'accounts');
    expect(account['id'], 'TEXT');
    expect(account['initial_balance_minor'], 'INTEGER');
    expect(account['currency_code'], 'TEXT');

    final Map<String, String> transaction = await columnTypes(db, 'transactions');
    expect(transaction['id'], 'TEXT');
    expect(transaction['amount_minor'], 'INTEGER');
    expect(transaction['date'], 'INTEGER');
  });

  test('в каждой таблице есть created_at, updated_at и deleted_at', () async {
    for (final String table in <String>[
      'currencies',
      'accounts',
      'categories',
      'transactions',
    ]) {
      final Map<String, String> columns = await columnTypes(db, table);
      expect(columns, contains('created_at'), reason: 'таблица $table');
      expect(columns, contains('updated_at'), reason: 'таблица $table');
      expect(columns, contains('deleted_at'), reason: 'таблица $table');
    }
  });

  test('индексы транзакций созданы', () async {
    expect(
      await indexNames(db, 'transactions'),
      containsAll(<String>[
        'idx_transactions_date',
        'idx_transactions_account_id',
        'idx_transactions_category_id',
      ]),
    );
  });

  test('вставка и выборка работают на всех четырёх таблицах', () async {
    await db
        .into(db.currencies)
        .insert(
          CurrenciesCompanion.insert(
            code: 'RUB',
            symbol: '₽',
            isBase: const Value(true),
            createdAt: fixedNow,
            updatedAt: fixedNow,
          ),
        );

    await db
        .into(db.accounts)
        .insert(
          AccountsCompanion.insert(
            id: '00000000-0000-4000-8000-000000000001',
            name: 'Наличные',
            kind: 'cash',
            currencyCode: 'RUB',
            initialBalanceMinor: const Value(100000),
            createdAt: fixedNow,
            updatedAt: fixedNow,
          ),
        );

    await db
        .into(db.categories)
        .insert(
          CategoriesCompanion.insert(
            id: '00000000-0000-4000-8000-000000000002',
            name: 'Продукты',
            kind: 'expense',
            isSystem: const Value(true),
            createdAt: fixedNow,
            updatedAt: fixedNow,
          ),
        );

    await db
        .into(db.transactions)
        .insert(
          TransactionsCompanion.insert(
            id: '00000000-0000-4000-8000-000000000003',
            type: 'expense',
            accountId: '00000000-0000-4000-8000-000000000001',
            categoryId: const Value('00000000-0000-4000-8000-000000000002'),
            amountMinor: 12345,
            currencyCode: 'RUB',
            date: fixedNow,
            note: const Value('Тестовая покупка'),
            createdAt: fixedNow,
            updatedAt: fixedNow,
          ),
        );

    final List<Currency> currencies = await db.select(db.currencies).get();
    expect(currencies, hasLength(1));
    expect(currencies.single.code, 'RUB');
    expect(currencies.single.isBase, isTrue);
    expect(currencies.single.rateToBase, 1);

    final List<Account> accounts = await db.select(db.accounts).get();
    expect(accounts.single.initialBalanceMinor, 100000);

    final List<Transaction> transactions = await db
        .select(db.transactions)
        .get();
    expect(transactions, hasLength(1));
    expect(transactions.single.amountMinor, 12345);
    expect(transactions.single.deletedAt, isNull);
    expect(transactions.single.note, 'Тестовая покупка');
  });

  test('soft delete: deleted_at заполняется, запись остаётся', () async {
    await db
        .into(db.currencies)
        .insert(
          CurrenciesCompanion.insert(
            code: 'USD',
            symbol: r'$',
            createdAt: fixedNow,
            updatedAt: fixedNow,
          ),
        );

    await (db.update(db.currencies)..where((t) => t.code.equals('USD'))).write(
      CurrenciesCompanion(
        deletedAt: Value(fixedNow),
        updatedAt: Value(fixedNow),
      ),
    );

    // Фильтр по `deleted_at IS NULL` — на стороне SQL, без конфликта имени
    // матчера isNull из flutter_test.
    final List<String> aliveCodes = await db
        .customSelect('SELECT code FROM currencies WHERE deleted_at IS NULL')
        .map((QueryRow row) => row.read<String>('code'))
        .get();
    expect(aliveCodes, isEmpty);

    final List<Currency> all = await db.select(db.currencies).get();
    expect(all, hasLength(1));
    // drift хранит даты как UTC-отметку времени, а при чтении отдаёт DateTime
    // в локальной зоне (тот же момент). Сравниваем момент, а не зону (§3).
    expect(all.single.deletedAt?.toUtc(), fixedNow);
  });

  test('внешние ключи включены: транзакция без счёта не вставляется', () async {
    await expectLater(
      db
          .into(db.transactions)
          .insert(
            TransactionsCompanion.insert(
              id: '00000000-0000-4000-8000-000000000004',
              type: 'expense',
              accountId: '00000000-0000-4000-8000-0000000000ff', // нет такого
              amountMinor: 1,
              currencyCode: 'RUB',
              date: fixedNow,
              createdAt: fixedNow,
              updatedAt: fixedNow,
            ),
          ),
      // Конкретный тип (SqliteException из package:sqlite3) не важен —
      // важно, что БД отклонила вставку.
      throwsA(isA<Exception>()),
    );
  });
}
