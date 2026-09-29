// Тест миграции схемы v4 → v5 (правило эпох, ROADMAP.md: у пользователей
// реальный файл БД v0.1–v0.5, он обязан открыться без потерь).
//
// Приём — по образцу migration_v4_test: файл базы со схемой v4 строится
// сырым sqlite3 API (тот же DDL, что генерировала v0.4, user_version = 4),
// с данными формата v0.4 (даты — unix-секунды, иконки в icon_code). Затем
// файл открывается AppDatabase: drift видит user_version 4 < 5 и выполняет
// onUpgrade (ALTER TABLE ADD COLUMN без перезаписи данных, D-54). Старые
// строки счетов читаются, exclude_from_balance = NULL — валидное состояние
// «учитывать в балансе» (дефолт v0.1–v0.4 без отличий).
//
// Второй сценарий — полная цепочка v1 → … → v5: файл v0.1 открывается
// на текущей схеме, onUpgrade исполняет все шаги по порядку.
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

// S3-хелпер: структурные проверки после миграции идут общими инвариантами
// (образец migration_v4_test).
import '../../helpers/schema_invariants.dart';

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

/// DDL схемы v4 (v0.4): v1 + таблица budgets + колонка переводов
/// target_amount_minor + колонка иконок категорий icon_code.
/// Колонки exclude_from_balance ещё нет.
const List<String> _v4Ddl = <String>[
  ..._v1Ddl,
  'CREATE TABLE budgets ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'category_id TEXT NOT NULL REFERENCES categories (id), '
      'limit_minor INTEGER NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'ALTER TABLE transactions ADD COLUMN target_amount_minor INTEGER NULL',
  'ALTER TABLE categories ADD COLUMN icon_code TEXT NULL',
];

/// Данные v0.4: посев справочников, счёт, категория с иконкой (v4) и
/// категория без; после миграции счёт читается с exclude_from_balance =
/// NULL — валидное состояние «учитывать». Даты — unix-секунды.
/// [withV4Columns] = false — посев для файла v1: колонок v3/v4 ещё нет,
/// иконка появится только в v4.
void _seedV04Data(Database raw, {bool withV4Columns = true}) {
  final int now = DateTime.utc(2026, 9, 29, 12).millisecondsSinceEpoch ~/ 1000;
  raw.execute(
    "INSERT INTO currencies (code, symbol, is_base, rate_to_base, created_at, updated_at) "
    "VALUES ('RUB', '₽', 1, 1.0, $now, $now)",
  );
  if (withV4Columns) {
    raw.execute(
      "INSERT INTO categories (id, name, kind, is_system, icon_code, created_at, updated_at) "
      "VALUES ('cat-food', 'Продукты', 'expense', 1, 'groceries', $now, $now)",
    );
  } else {
    raw.execute(
      "INSERT INTO categories (id, name, kind, is_system, created_at, updated_at) "
      "VALUES ('cat-food', 'Продукты', 'expense', 1, $now, $now)",
    );
  }
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
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_v5');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('миграция v4 → v5: данные v0.4 целы, флаг баланса NULL', () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 4');
    for (final String ddl in _v4Ddl) {
      raw.execute(ddl);
    }
    _seedV04Data(raw);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // beforeOpen после миграции: версия поднята до 5.
    final int version =
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');
    expect(version, 5, reason: 'после открытия база должна быть на v5');

    // Колонка существует, nullable и без default (D-21-образец) —
    // семантика колонки суть этого теста, raw-PRAGMA. drift хранит
    // boolean() как INTEGER с CHECK (IN (0, 1)) — не declared 'BOOLEAN'.
    final List<QueryRow> rawColumns = await db.customSelect(
      'PRAGMA table_info(accounts)',
    ).get();
    final Map<String, dynamic> flagColumn = rawColumns.singleWhere(
      (QueryRow row) => row.read<String>('name') == 'exclude_from_balance',
    ).data;
    expect(flagColumn['type'], 'INTEGER');
    expect(flagColumn['notnull'], 0, reason: 'колонка nullable');
    expect(
      flagColumn['dflt_value'],
      isNull,
      reason: 'default не задан: NULL — семантика «учитывать» (v0.1–v0.4)',
    );
    // CHECK-инвариант булевой колонки drift (0/1) на месте — DDL из
    // sqlite_master (у PRAGMA table_info колонки sql нет).
    final List<QueryRow> ddlRows = await db.customSelect(
      "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'accounts'",
    ).get();
    expect(
      ddlRows.single.read<String>('sql'),
      contains('exclude_from_balance" IN (0, 1)'),
    );
    // Служебные колонки §3 у всех таблиц на месте после миграции (S3).
    await expectTimestampColumns(db, expectedTables);

    // Данные v0.4 выжили дословно, флаг у старых строк NULL.
    final List<Account> accounts = await db.select(db.accounts).get();
    expect(accounts.single.id, 'acc-1');
    expect(accounts.single.name, 'Karta');
    expect(accounts.single.initialBalanceMinor, 1000050);
    expect(
      accounts.single.excludeFromBalance,
      isNull,
      reason: 'данные v0.4 созданы до v5 — счёт учитывается в балансе',
    );

    // Иконки v4 не тронуты миграцией v5.
    final List<Category> categories = await db.select(db.categories).get();
    expect(categories.single.iconCode, 'groceries');

    // Операции не тронуты.
    final List<Transaction> transactions = await db.select(db.transactions).get();
    expect(transactions, hasLength(1));
    expect(transactions.single.amountMinor, 50050);
  });

  test('цепочка v1 → … → v5: файл v0.1 открывается на текущей схеме',
      () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 1');
    for (final String ddl in _v1Ddl) {
      raw.execute(ddl);
    }
    // budgets в v1 не существует, колонок v3/v4 нет — бюджет и иконка
    // появятся в цепочке миграций.
    _seedV04Data(raw, withV4Columns: false);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      5,
    );

    // Все шаги цепочки исполнены: budgets создана, обе колонки добавлены
    // (drift хранит boolean() как INTEGER — не declared 'BOOLEAN').
    final Map<String, String> accountColumns = await columnTypes(db, 'accounts');
    expect(accountColumns['exclude_from_balance'], 'INTEGER');
    final Map<String, String> catColumns = await columnTypes(db, 'categories');
    expect(catColumns['icon_code'], 'TEXT');
    final List<Transaction> transactions = await db.select(db.transactions).get();
    expect(transactions, hasLength(1));
    expect(
      transactions.single.targetAmountMinor,
      isNull,
      reason: 'все данные v0.1 — одно-валютные',
    );
    expect(
      (await db.select(db.accounts).get())
          .every((Account a) => a.excludeFromBalance == null),
      isTrue,
      reason: 'все данные v0.1 — с учётом в балансе',
    );
    // Шаг v1→v2 цепочки: таблица budgets создана и пуста.
    final List<Budget> budgets = await db.select(db.budgets).get();
    expect(budgets, isEmpty);
  });

  test('повторное открытие базы v5: без ре-миграции, данные на месте',
      () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );

    final AppDatabase first = AppDatabase.forTesting(NativeDatabase(dbFile));
    await first.currenciesDao.create(code: 'RUB', symbol: '₽', isBase: true);
    final Account savings = await first.accountsDao.create(
      name: 'Накопления',
      kind: AccountKind.bank,
      currencyCode: 'RUB',
      initialBalanceMinor: 9900000,
      excludeFromBalance: true,
    );
    await first.close();

    // Повторное открытие: onUpgrade не выполняется (версия уже 5),
    // данные живы, флаг сохранился.
    final AppDatabase second =
        AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    expect(
      (await second.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      5,
    );
    final Account alive = (await second.accountsDao.getAlive()).single;
    expect(alive.id, savings.id);
    expect(alive.excludeFromBalance, isTrue);
  });
}
