// Тест миграции схемы v1 → v2 (первая миграция после релиза v0.1: у
// пользователей реальный файл БД с данными, он обязан открыться без потерь).
//
// Приём: файл базы со схемой v1 строится сырым sqlite3 API — тем же DDL,
// который генерировала v0.1, с user_version = 1 и данными формата v0.1
// (даты — unix-секунды). Затем файл открывается AppDatabase: drift видит
// user_version 1 < 2 и выполняет onUpgrade.
//
// sqlite3 здесь — dev-зависимость только для тестов (та же нативная
// библиотека, что бандлит drift).
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:sqlite3/sqlite3.dart';

/// DDL схемы v1 (v0.1): budgets не существует, индексы транзакций на месте.
const List<String> _v1Ddl = <String>[
  'CREATE TABLE currencies ('
      'code TEXT NOT NULL PRIMARY KEY, '
      'symbol TEXT NOT NULL, '
      'is_base INTEGER NOT NULL DEFAULT 0, '
      'rate_to_base REAL NOT NULL DEFAULT 1, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'CREATE TABLE accounts ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'kind TEXT NOT NULL, '
      'currency_code TEXT NOT NULL REFERENCES currencies (code), '
      'initial_balance_minor INTEGER NOT NULL DEFAULT 0, '
      'sort_order INTEGER NOT NULL DEFAULT 0, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'CREATE TABLE categories ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'kind TEXT NOT NULL, '
      'parent_id TEXT NULL REFERENCES categories (id), '
      'icon TEXT NULL, '
      'color TEXT NULL, '
      'is_system INTEGER NOT NULL DEFAULT 0, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'CREATE TABLE transactions ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'type TEXT NOT NULL, '
      'account_id TEXT NOT NULL REFERENCES accounts (id), '
      'target_account_id TEXT NULL REFERENCES accounts (id), '
      'category_id TEXT NULL REFERENCES categories (id), '
      'amount_minor INTEGER NOT NULL, '
      'currency_code TEXT NOT NULL REFERENCES currencies (code), '
      'date INTEGER NOT NULL, '
      'note TEXT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'CREATE INDEX idx_transactions_date ON transactions (date)',
  'CREATE INDEX idx_transactions_account_id ON transactions (account_id)',
  'CREATE INDEX idx_transactions_category_id ON transactions (category_id)',
];

/// Данные v0.1: посев справочников, счёт, операция. Даты — unix-секунды.
void _seedV01Data(Database raw) {
  final int now = DateTime.utc(2026, 9, 25, 12).millisecondsSinceEpoch ~/ 1000;
  raw.execute(
    "INSERT INTO currencies (code, symbol, is_base, rate_to_base, created_at, updated_at) "
    "VALUES ('RUB', '₽', 1, 1.0, $now, $now)",
  );
  raw.execute(
    "INSERT INTO categories (id, name, kind, is_system, created_at, updated_at) "
    "VALUES ('cat-food', 'Продукты', 'expense', 1, $now, $now)",
  );
  raw.execute(
    "INSERT INTO categories (id, name, kind, is_system, created_at, updated_at) "
    "VALUES ('cat-salary', 'Зарплата', 'income', 1, $now, $now)",
  );
  raw.execute(
    "INSERT INTO accounts (id, name, kind, currency_code, initial_balance_minor, "
    "sort_order, created_at, updated_at) "
    "VALUES ('acc-1', 'Karta', 'card', 'RUB', 1000050, 0, $now, $now)",
  );
  raw.execute(
    "INSERT INTO transactions (id, type, account_id, category_id, amount_minor, "
    "currency_code, date, note, created_at, updated_at) "
    "VALUES ('tx-1', 'expense', 'acc-1', 'cat-food', 50050, 'RUB', $now, 'кофе', $now, $now)",
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('миграция v1 → v2: данные v0.1 целы, таблица budgets готова',
      () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 1');
    for (final String ddl in _v1Ddl) {
      raw.execute(ddl);
    }
    _seedV01Data(raw);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // beforeOpen после миграции: версия поднята до 2.
    final int version =
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');
    expect(version, 2, reason: 'после открытия база должна быть на v2');

    // Данные v0.1 выжили дословно.
    final List<Currency> currencies = await db.select(db.currencies).get();
    expect(currencies.single.code, 'RUB');
    expect(currencies.single.isBase, isTrue);
    expect(currencies.single.rateToBase, 1.0);

    final List<Account> accounts = await db.select(db.accounts).get();
    expect(accounts.single.name, 'Karta');
    expect(accounts.single.initialBalanceMinor, 1000050);

    final List<Category> categories = await db.select(db.categories).get();
    expect(categories, hasLength(2));
    expect(categories.where((Category c) => c.isSystem), hasLength(2));

    final List<Transaction> transactions =
        await db.select(db.transactions).get();
    expect(transactions.single.amountMinor, 50050);
    expect(transactions.single.note, 'кофе');
    // drift отдаёт дату тем же моментом, что записан в файле.
    expect(
      transactions.single.date.toUtc(),
      DateTime.utc(2026, 9, 25, 12),
    );

    // Таблица budgets существует, пуста.
    final List<QueryRow> budgetRows =
        await db.customSelect('SELECT COUNT(*) AS c FROM budgets').get();
    expect(budgetRows.single.read<int>('c'), 0);

    // DAO поверх мигрированной базы работает.
    final Category food =
        categories.singleWhere((Category c) => c.name == 'Продукты');
    final Budget created = await db.budgetsDao.create(
      categoryId: food.id,
      limitMinor: 12345,
    );
    expect(created.limitMinor, 12345);
    expect((await db.budgetsDao.getAlive()).single.id, created.id);

    // Индексы транзакций пережили миграцию (createAll не трогает их).
    final List<QueryRow> indexes = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = 'transactions'",
    ).get();
    expect(
      indexes.map((QueryRow row) => row.read<String>('name')),
      containsAll(<String>[
        'idx_transactions_date',
        'idx_transactions_account_id',
        'idx_transactions_category_id',
      ]),
    );
  });

  test('повторное открытие базы v2: без ре-миграции, данные на месте',
      () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );

    final AppDatabase first = AppDatabase.forTesting(NativeDatabase(dbFile));
    // Свежая база пуста — создаём справочник и бюджет.
    await first.currenciesDao.create(code: 'RUB', symbol: '₽', isBase: true);
    final Category food = await first.categoriesDao.create(
      name: 'Продукты',
      kind: CategoryKind.expense,
    );
    final Budget budget = await first.budgetsDao.create(
      categoryId: food.id,
      limitMinor: 5000,
    );
    await first.close();

    // Повторное открытие: onUpgrade не выполняется (версия уже 2),
    // данные живы.
    final AppDatabase second =
        AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    expect(
      (await second.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      2,
    );
    final List<Budget> alive = await second.budgetsDao.getAlive();
    expect(alive.single.id, budget.id);
    expect(alive.single.limitMinor, 5000);
  });
}
