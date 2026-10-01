// Тест миграции схемы v5 → v6 (правило эпох, ROADMAP.md: у пользователей
// реальный файл БД v0.1–v0.5, он обязан открыться без потерь).
//
// Приём — по образцу migration_v5_test: файл базы со схемой v5 строится
// сырым sqlite3 API (тот же DDL, что генерировала v0.5, user_version = 5),
// с данными формата v0.5 (флаг exclude_from_balance, иконки в icon_code).
// Затем файл открывается AppDatabase: drift видит user_version 5 < 6 и
// выполняет onUpgrade (createTable attachments — без перезаписи данных,
// D-63). Таблица вложений пуста (данных вложений в v5 не было), операции
// и счета читаются дословно.
//
// Второй сценарий — полная цепочка v1 → … → v6: файл v0.1 открывается
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
// (образец migration_v4/v5_test).
import '../../helpers/schema_invariants.dart';

/// DDL схемы v1 (v0.1): budgets/attachments не существуют, индексы
/// транзакций на месте.
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

/// DDL схемы v5 (v0.5): v1 + budgets + колонка переводов
/// target_amount_minor + колонка иконок icon_code + флаг баланса
/// exclude_from_balance. Таблицы attachments ещё нет.
const List<String> _v5Ddl = <String>[
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
  'ALTER TABLE accounts ADD COLUMN exclude_from_balance INTEGER NULL',
];

/// Данные v0.5: посев справочников, счёт, категория, операция. После
/// миграции всё читается дословно; таблица attachments пуста.
/// Даты — unix-секунды. [withV4Columns] = false — посев для файла v1:
/// колонок v3/v4/v5 ещё нет.
void _seedV05Data(Database raw, {bool withV4Columns = true}) {
  final int now = DateTime.utc(2026, 9, 30, 12).millisecondsSinceEpoch ~/ 1000;
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
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_v6');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'миграция v5 → v6: данные v0.5 целы, таблица attachments создана',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );
      final Database raw = sqlite3.open(dbFile.path);
      raw.execute('PRAGMA user_version = 5');
      for (final String ddl in _v5Ddl) {
        raw.execute(ddl);
      }
      _seedV05Data(raw);
      raw.close();

      final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      // beforeOpen после миграции: версия поднята до 6.
      final int version =
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          );
      expect(version, 7, reason: 'после открытия база должна быть на v7');

      // Таблица attachments существует; структурные колонки §3 на месте
      // (S3-инвариант). file_path/mime_type/file_size — из D-63 дословно.
      final Map<String, String> columns = await columnTypes(db, 'attachments');
      expect(
        columns.keys,
        containsAll(<String>[
          'id',
          'transaction_id',
          'file_path',
          'mime_type',
          'file_size',
          'created_at',
          'updated_at',
          'deleted_at',
        ]),
      );
      expect(columns['id'], 'TEXT');
      expect(columns['transaction_id'], 'TEXT');
      expect(columns['file_path'], 'TEXT');
      expect(columns['mime_type'], 'TEXT');
      expect(columns['file_size'], 'INTEGER');
      await expectTimestampColumns(db, expectedTablesPlusAttachments);

      // FK на transactions без каскада: строка в sqlite_master ссылается
      // на transactions, отдельных действий ON DELETE нет.
      final List<QueryRow> fkRows = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'attachments'",
          )
          .get();
      final String ddlSql = fkRows.single.read<String>('sql');
      expect(ddlSql, contains('REFERENCES transactions (id)'));
      expect(ddlSql, isNot(contains('ON DELETE')));

      // Данных вложений в v5 не было — таблица пуста.
      expect(await db.select(db.attachments).get(), isEmpty);

      // Данные v0.5 выжили дословно.
      final List<Account> accounts = await db.select(db.accounts).get();
      expect(accounts.single.id, 'acc-1');
      expect(accounts.single.initialBalanceMinor, 1000050);
      expect(accounts.single.excludeFromBalance, isNull);
      final List<Category> categories = await db.select(db.categories).get();
      expect(categories.single.iconCode, 'groceries');
      final List<Transaction> transactions = await db
          .select(db.transactions)
          .get();
      expect(transactions.single.amountMinor, 50050);
    },
  );

  test('цепочка v1 → … → v6: файл v0.1 открывается на текущей схеме', () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 1');
    for (final String ddl in _v1Ddl) {
      raw.execute(ddl);
    }
    // budgets в v1 не существует, колонок v3/v4/v5 нет — они появятся
    // в цепочке миграций.
    _seedV05Data(raw, withV4Columns: false);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      7,
    );

    // Все шаги цепочки исполнены: budgets создана, колонки добавлены,
    // таблица вложений создана (drift хранит boolean() как INTEGER).
    final Map<String, String> accountColumns = await columnTypes(
      db,
      'accounts',
    );
    expect(accountColumns['exclude_from_balance'], 'INTEGER');
    final Map<String, String> catColumns = await columnTypes(db, 'categories');
    expect(catColumns['icon_code'], 'TEXT');
    final Map<String, String> attColumns = await columnTypes(db, 'attachments');
    expect(attColumns['file_path'], 'TEXT');
    expect(attColumns['mime_type'], 'TEXT');
    expect(attColumns['file_size'], 'INTEGER');
    final List<Budget> budgets = await db.select(db.budgets).get();
    expect(budgets, isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);
    final List<Transaction> transactions = await db
        .select(db.transactions)
        .get();
    expect(transactions, hasLength(1));
    expect(transactions.single.targetAmountMinor, isNull);
  });

  test(
    'повторное открытие базы v6: без ре-миграции, данные на месте',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );

      final AppDatabase first = AppDatabase.forTesting(NativeDatabase(dbFile));
      await first.currenciesDao.create(code: 'RUB', symbol: '₽', isBase: true);
      final Account account = await first.accountsDao.create(
        name: 'Наличные',
        kind: AccountKind.cash,
        currencyCode: 'RUB',
        initialBalanceMinor: 150000,
      );
      final Transaction tx = await first.transactionsDao.create(
        type: TransactionType.expense,
        accountId: account.id,
        amountMinor: 25000,
        note: 'с вложением',
      );
      await first.attachmentsDao.create(
        transactionId: tx.id,
        filePath: 'att-check.png',
        mimeType: 'image/png',
        fileSize: 4242,
      );
      await first.close();

      // Повторное открытие: onUpgrade не выполняется (версия уже 7),
      // данные живы, вложение читается.
      final AppDatabase second = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      expect(
        (await second.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        7,
      );
      final Attachment? att = await second.attachmentsDao.findByTransaction(
        tx.id,
      );
      expect(att?.filePath, 'att-check.png');
      expect(att?.fileSize, 4242);
    },
  );
}
