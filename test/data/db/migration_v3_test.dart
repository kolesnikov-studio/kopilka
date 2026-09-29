// Тест миграции схемы v2 → v3 (правило эпох, ROADMAP.md: у пользователей
// реальный файл БД v0.1–v0.2, он обязан открыться без потерь).
//
// Приём — по образцу migration_v2_test: файл базы со схемой v2 строится
// сырым sqlite3 API (тот же DDL, что генерировала v0.2, user_version = 2),
// с данными формата v0.2 (даты — unix-секунды), включая старые переводы
// с target_amount_minor = NULL — после миграции они считаются переводами
// в одной валюте (D-17/D-21). Затем файл открывается AppDatabase: drift
// видит user_version 2 < 3 и выполняет onUpgrade (ALTER TABLE ADD COLUMN
// без перезаписи данных).
//
// Второй сценарий — полная цепочка v1 → v2 → v3: файл v0.1 открывается на
// текущей схеме, onUpgrade исполняет оба шага по порядку.
//
// sqlite3 здесь — dev-зависимость только для тестов (та же нативная
// библиотека, что бандлит drift).
//
// Замок миграции v2→v3 (правило §8: старые тесты не редактировать;
// поднимается только ожидаемая «текущая версия» при новой схеме v4).
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:sqlite3/sqlite3.dart';

// S3-хелпер (перевод на него — решение ревью M3-шага 1, «в шаге 4»):
// структурные проверки после миграции идут общими инвариантами вместо
// локальных PRAGMA-копий.
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

/// DDL схемы v2 (v0.2): v1 + таблица budgets; колонки target_amount_minor
/// ещё нет.
const List<String> _v2Ddl = <String>[
  ..._v1Ddl,
  'CREATE TABLE budgets ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'category_id TEXT NOT NULL REFERENCES categories (id), '
      'limit_minor INTEGER NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
];

/// Данные v0.2: посев справочников, пара счетов, расход и старые переводы
/// (target_account_id заполнен, target_amount_minor в v2 не существует —
/// после миграции должен остаться NULL). Даты — unix-секунды.
///
/// [withBudgets] = false — посев для файла v1: таблицы budgets ещё нет,
/// бюджет появится только в v2.
void _seedV02Data(Database raw, {bool withBudgets = true}) {
  final int now = DateTime.utc(2026, 9, 26, 12).millisecondsSinceEpoch ~/ 1000;
  raw.execute(
    "INSERT INTO currencies (code, symbol, is_base, rate_to_base, created_at, updated_at) "
    "VALUES ('RUB', '₽', 1, 1.0, $now, $now)",
  );
  raw.execute(
    "INSERT INTO currencies (code, symbol, is_base, rate_to_base, created_at, updated_at) "
    "VALUES ('USD', '\$', 0, 79.5, $now, $now)",
  );
  raw.execute(
    "INSERT INTO categories (id, name, kind, is_system, created_at, updated_at) "
    "VALUES ('cat-food', 'Продукты', 'expense', 1, $now, $now)",
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
  // Старый перевод в одной валюте: после миграции target_amount_minor NULL.
  raw.execute(
    "INSERT INTO transactions (id, type, account_id, target_account_id, "
    "amount_minor, currency_code, date, created_at, updated_at) "
    "VALUES ('tx-2', 'transfer', 'acc-1', 'acc-2', 100000, 'RUB', $now, $now, $now)",
  );
  // Мягко удалённый перевод — тоже обязан пережить миграцию.
  raw.execute(
    "INSERT INTO transactions (id, type, account_id, target_account_id, "
    "amount_minor, currency_code, date, deleted_at, created_at, updated_at) "
    "VALUES ('tx-3', 'transfer', 'acc-2', 'acc-1', 5000, 'RUB', $now, $now, $now, $now)",
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
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_v3');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('миграция v2 → v3: данные v0.2 целы, колонка переводов NULL', () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 2');
    for (final String ddl in _v2Ddl) {
      raw.execute(ddl);
    }
    _seedV02Data(raw);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    // beforeOpen после миграции: версия поднята до текущей (4; шаг v3→v4
    // исполняется следом — тест замка v2→v3 проверяет свою колонку).
    final int version =
        (await db.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version');
    expect(version, 5, reason: 'после открытия база должна быть на текущей схеме');

    // Колонка существует, nullable и без default (D-21) — через S3-хелпер.
    final Map<String, String> txColumns = await columnTypes(db, 'transactions');
    expect(txColumns['target_amount_minor'], 'INTEGER');
    // Nullable и без default проверяются raw-PRAGMA: helper отдаёт только
    // имя → тип, а семантика колонки — суть этого теста миграции.
    final List<QueryRow> rawColumns = await db.customSelect(
      'PRAGMA table_info(transactions)',
    ).get();
    final Map<String, dynamic> targetColumn = rawColumns.singleWhere(
      (QueryRow row) => row.read<String>('name') == 'target_amount_minor',
    ).data;
    expect(targetColumn['notnull'], 0, reason: 'колонка nullable');
    expect(
      targetColumn['dflt_value'],
      isNull,
      reason: 'default не задан: NULL — семантика «не перевод/одна валюта»',
    );
    // Служебные колонки §3 у всех таблиц на месте после миграции (S3).
    await expectTimestampColumns(db, expectedTables);

    // Данные v0.2 выжили дословно.
    final List<Currency> currencies = await db.select(db.currencies).get();
    expect(currencies, hasLength(2));
    expect(currencies.where((Currency c) => c.isBase).single.code, 'RUB');

    final List<Account> accounts = await db.select(db.accounts).get();
    expect(accounts, hasLength(2));

    final List<Transaction> transactions =
        await db.select(db.transactions).get();
    expect(transactions, hasLength(3));
    final Transaction expense =
        transactions.singleWhere((Transaction t) => t.id == 'tx-1');
    expect(expense.amountMinor, 50050);
    expect(expense.note, 'кофе');
    expect(
      expense.date.toUtc(),
      DateTime.utc(2026, 9, 26, 12),
    );
    expect(expense.targetAmountMinor, isNull,
        reason: 'у не-перевода колонка NULL');

    // Старые переводы: target_amount_minor = NULL — теперь это переводы
    // в одной валюте (D-17); мягко удалённая строка тоже цела.
    for (final String id in <String>['tx-2', 'tx-3']) {
      final Transaction transfer =
          transactions.singleWhere((Transaction t) => t.id == id);
      expect(transfer.targetAccountId, isNotNull);
      expect(transfer.targetAmountMinor, isNull,
          reason: 'перевод $id создан до v3 — одна валюта');
    }
    expect(
      transactions.singleWhere((Transaction t) => t.id == 'tx-3').deletedAt,
      isNotNull,
    );

    // Бюджеты v2 не тронуты.
    final List<Budget> budgets = await db.select(db.budgets).get();
    expect(budgets.single.limitMinor, 250000);

    // Индексы транзакций пережили миграцию.
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

  test('цепочка v1 → v2 → v3: файл v0.1 открывается на текущей схеме',
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
    _seedV02Data(raw, withBudgets: false);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      5,
    );

    // Оба шага цепочки исполнены: budgets создана, колонка добавлена.
    final List<Transaction> transactions =
        await db.select(db.transactions).get();
    expect(transactions, hasLength(3));
    expect(
      transactions.every((Transaction t) => t.targetAmountMinor == null),
      isTrue,
      reason: 'все данные v0.1 — одно-валютные',
    );
    // Шаг v1→v2 цепочки: таблица budgets создана и пуста.
    final List<Budget> budgets = await db.select(db.budgets).get();
    expect(budgets, isEmpty);
  });

  test('повторное открытие базы v3: без ре-миграции, данные на месте',
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

    // Повторное открытие: onUpgrade не выполняется (версия уже 4),
    // данные живы.
    final AppDatabase second =
        AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(second.close);
    expect(
      (await second.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version'),
      5,
    );
    final List<Budget> alive = await second.budgetsDao.getAlive();
    expect(alive.single.id, budget.id);
    expect(alive.single.limitMinor, 5000);
  });
}
