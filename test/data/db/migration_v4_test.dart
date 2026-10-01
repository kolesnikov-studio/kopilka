// Тест миграции схемы v3 → v4 (правило эпох, ROADMAP.md: у пользователей
// реальный файл БД v0.1–v0.4, он обязан открыться без потерь).
//
// Приём — по образцу migration_v3_test: файл базы со схемой v3 строится
// сырым sqlite3 API (тот же DDL, что генерировала v0.3, user_version = 3),
// с данными формата v0.3 (даты — unix-секунды). Затем файл открывается
// AppDatabase: drift видит user_version 3 < 4 и выполняет onUpgrade
// (ALTER TABLE ADD COLUMN без перезаписи данных, D-54). Старые строки
// категорий читаются, icon_code = NULL — валидное состояние «иконка не
// выбрана».
//
// Второй сценарий — полная цепочка v1 → v2 → v3 → v4: файл v0.1 открывается
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
// вместо локальных PRAGMA-копий (образец migration_v3_test).
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

/// DDL схемы v3 (v0.3): v1 + таблица budgets + колонка переводов
/// target_amount_minor. Колонки icon_code ещё нет.
const List<String> _v3Ddl = <String>[
  ..._v1Ddl,
  'CREATE TABLE budgets ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'category_id TEXT NOT NULL REFERENCES categories (id), '
      'limit_minor INTEGER NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'ALTER TABLE transactions ADD COLUMN target_amount_minor INTEGER NULL',
];

/// Данные v0.3: посев справочников, пара счетов, категория со старым
/// свободным `icon` (не путать с icon_code) и категория вовсе без иконки;
/// после миграции у обеих icon_code = NULL — валидное состояние «иконка
/// не выбрана» (D-54). Даты — unix-секунды.
///
/// [withBudgets] = false — посев для файла v1: таблицы budgets ещё нет,
/// бюджет появится только в v2.
void _seedV03Data(Database raw, {bool withBudgets = true}) {
  final int now = DateTime.utc(2026, 9, 28, 12).millisecondsSinceEpoch ~/ 1000;
  raw.execute(
    "INSERT INTO currencies (code, symbol, is_base, rate_to_base, created_at, updated_at) "
    "VALUES ('RUB', '₽', 1, 1.0, $now, $now)",
  );
  raw.execute(
    "INSERT INTO categories (id, name, kind, is_system, created_at, updated_at) "
    "VALUES ('cat-food', 'Продукты', 'expense', 1, $now, $now)",
  );
  // Старое свободное поле icon (§3) обязано пережить миграцию дословно —
  // оно не трогается (§8), а icon_code заполняет только пользователь/UI.
  raw.execute(
    "INSERT INTO categories (id, name, kind, is_system, icon, created_at, updated_at) "
    "VALUES ('cat-cafe', 'Кафе', 'expense', 1, '☕', $now, $now)",
  );
  raw.execute(
    "INSERT INTO accounts (id, name, kind, currency_code, initial_balance_minor, "
    "sort_order, created_at, updated_at) "
    "VALUES ('acc-1', 'Karta', 'card', 'RUB', 1000050, 0, $now, $now)",
  );
  raw.execute(
    "INSERT INTO accounts (id, name, kind, currency_code, initial_balance_minor, "
    "sort_order, created_at, updated_at) "
    "VALUES ('acc-2', 'Nakopleniya', 'bank', 'RUB', 0, 1, $now, $now)",
  );
  raw.execute(
    "INSERT INTO transactions (id, type, account_id, category_id, amount_minor, "
    "currency_code, date, note, created_at, updated_at) "
    "VALUES ('tx-1', 'expense', 'acc-1', 'cat-food', 50050, 'RUB', $now, 'кофе', $now, $now)",
  );
  raw.execute(
    "INSERT INTO transactions (id, type, account_id, target_account_id, "
    "amount_minor, currency_code, date, created_at, updated_at) "
    "VALUES ('tx-2', 'transfer', 'acc-1', 'acc-2', 100000, 'RUB', $now, $now, $now)",
  );
  if (withBudgets) {
    raw.execute(
      "INSERT INTO budgets (id, category_id, limit_minor, created_at, updated_at) "
      "VALUES ('bud-1', 'cat-food', 250000, $now, $now)",
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_v4');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('миграция v3 → v4: данные v0.3 целы, колонка иконок NULL', () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 3');
    for (final String ddl in _v3Ddl) {
      raw.execute(ddl);
    }
    _seedV03Data(raw);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // beforeOpen после миграции: версия поднята до 4.
    final int version =
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        );
    expect(
      version,
      7,
      reason: 'после открытия база на v7 — цепочка миграций дошла до конца',
    );

    // Колонка существует, nullable и без default (D-54) — через S3-хелпер.
    final Map<String, String> catColumns = await columnTypes(db, 'categories');
    expect(catColumns['icon_code'], 'TEXT');
    // Nullable и без default проверяются raw-PRAGMA: helper отдаёт только
    // имя → тип, а семантика колонки — суть этого теста миграции.
    final List<QueryRow> rawColumns = await db
        .customSelect('PRAGMA table_info(categories)')
        .get();
    final Map<String, dynamic> iconCodeColumn = rawColumns
        .singleWhere((QueryRow row) => row.read<String>('name') == 'icon_code')
        .data;
    expect(iconCodeColumn['notnull'], 0, reason: 'колонка nullable');
    expect(
      iconCodeColumn['dflt_value'],
      isNull,
      reason: 'default не задан: NULL — семантика «иконка не выбрана»',
    );
    // Служебные колонки §3 у всех таблиц на месте после миграции (S3).
    await expectTimestampColumns(db, expectedTables);

    // Данные v0.3 выжили дословно.
    final List<Currency> currencies = await db.select(db.currencies).get();
    expect(currencies.single.code, 'RUB');
    expect(currencies.single.isBase, isTrue);

    final List<Account> accounts = await db.select(db.accounts).get();
    expect(accounts, hasLength(2));

    final List<Category> categories = await db.select(db.categories).get();
    expect(categories, hasLength(2));
    // Старые строки категорий читаются, поле иконки NULL — «не выбрана».
    final Category food = categories.singleWhere(
      (Category c) => c.id == 'cat-food',
    );
    expect(food.name, 'Продукты');
    expect(food.isSystem, isTrue);
    expect(
      food.iconCode,
      isNull,
      reason: 'данные v0.3 созданы до v4 — иконка не выбрана',
    );
    // Старое свободное поле icon не тронуто и не «мигрировало» в icon_code.
    final Category cafe = categories.singleWhere(
      (Category c) => c.id == 'cat-cafe',
    );
    expect(cafe.icon, '☕');
    expect(
      cafe.iconCode,
      isNull,
      reason: 'icon_code заполняет только пользователь/UI, не миграция',
    );

    final List<Transaction> transactions = await db
        .select(db.transactions)
        .get();
    expect(transactions, hasLength(2));
    expect(
      transactions.singleWhere((Transaction t) => t.id == 'tx-1').amountMinor,
      50050,
    );
    expect(
      transactions
          .singleWhere((Transaction t) => t.id == 'tx-2')
          .targetAmountMinor,
      isNull,
      reason: 'перевод в одной валюте — D-17',
    );

    // Бюджеты v2 не тронуты.
    final List<Budget> budgets = await db.select(db.budgets).get();
    expect(budgets.single.limitMinor, 250000);

    // Индексы транзакций пережили миграцию.
    final List<QueryRow> indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND tbl_name = 'transactions'",
        )
        .get();
    expect(
      indexes.map((QueryRow row) => row.read<String>('name')),
      containsAll(<String>[
        'idx_transactions_date',
        'idx_transactions_account_id',
        'idx_transactions_category_id',
      ]),
    );
  });

  test(
    'цепочка v1 → v2 → v3 → v4: файл v0.1 открывается на текущей схеме',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );
      final Database raw = sqlite3.open(dbFile.path);
      raw.execute('PRAGMA user_version = 1');
      for (final String ddl in _v1Ddl) {
        raw.execute(ddl);
      }
      // budgets в v1 не существует — бюджет в посев не входит.
      _seedV03Data(raw, withBudgets: false);
      raw.close();

      final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        7,
      );

      // Все три шага цепочки исполнены: budgets создана, колонки добавлены.
      final Map<String, String> catColumns = await columnTypes(
        db,
        'categories',
      );
      expect(catColumns['icon_code'], 'TEXT');
      final List<Transaction> transactions = await db
          .select(db.transactions)
          .get();
      expect(transactions, hasLength(2));
      expect(
        transactions.every((Transaction t) => t.targetAmountMinor == null),
        isTrue,
        reason: 'все данные v0.1 — одно-валютные',
      );
      expect(
        (await db.select(db.categories).get()).every(
          (Category c) => c.iconCode == null,
        ),
        isTrue,
        reason: 'все данные v0.1 — без иконок',
      );
      // Шаг v1→v2 цепочки: таблица budgets создана и пуста.
      final List<Budget> budgets = await db.select(db.budgets).get();
      expect(budgets, isEmpty);
    },
  );

  test(
    'повторное открытие базы v4: без ре-миграции, данные на месте',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );

      final AppDatabase first = AppDatabase.forTesting(NativeDatabase(dbFile));
      // Свежая база пуста — создаём справочник и категорию с иконкой.
      await first.currenciesDao.create(code: 'RUB', symbol: '₽', isBase: true);
      final Category food = await first.categoriesDao.create(
        name: 'Продукты',
        kind: CategoryKind.expense,
        iconCode: 'groceries',
      );
      await first.close();

      // Повторное открытие: onUpgrade не выполняется (версия уже 4),
      // данные живы.
      final AppDatabase second = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      expect(
        (await second.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        7,
      );
      final Category alive = (await second.categoriesDao.getAlive()).single;
      expect(alive.id, food.id);
      expect(alive.iconCode, 'groceries');
    },
  );
}
