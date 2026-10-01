// Тест миграции схемы v6 → v7 (правило эпох, ROADMAP.md: у пользователей
// реальный файл БД v0.1–v0.6, он обязан открыться без потерь).
//
// Приём — по образцу migration_v6_test: файл базы со схемой v6 строится
// сырым sqlite3 API (тот же DDL, что генерировала v0.6, user_version = 6),
// с данными формата v0.6 (вложения). Затем файл открывается AppDatabase:
// drift видит user_version 6 < 7 и выполняет onUpgrade (createTable debts,
// createTable debt_payments, addColumn accounts.interest_reminder_date —
// без перезаписи данных, M6/D-81). Таблицы долгов пусты (данных долгов
// в v6 не было), колонка счетов получает NULL = обычный счёт.
//
// Второй сценарий — полная цепочка v1 → … → v7: файл v0.1 открывается
// на текущей схеме, onUpgrade исполняет все шаги по порядку.
//
// sqlite3 здесь — dev-зависимость только для тестов (та же нативная
// библиотека, что бандлит drift).
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:sqlite3/sqlite3.dart';

// S3-хелпер: структурные проверки после миграции идут общими инвариантами
// (образец migration_v4/v5/v6_test).
import '../../helpers/schema_invariants.dart';

/// DDL схемы v1 (v0.1): budgets/attachments/debts не существуют, индексы
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

/// DDL схемы v6 (v0.6): v1 + budgets + колонка переводов
/// target_amount_minor + колонка иконок icon_code + флаг баланса
/// exclude_from_balance + таблица вложений. Таблиц долгов ещё нет.
const List<String> _v6Ddl = <String>[
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
  'CREATE TABLE attachments ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'transaction_id TEXT NOT NULL REFERENCES transactions (id), '
      'file_path TEXT NOT NULL, '
      'mime_type TEXT NOT NULL, '
      'file_size INTEGER NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
];

/// Данные v0.6: посев справочников, счёт, категория, операция. После
/// миграции всё читается дословно; таблицы долгов пусты, дата напоминания
/// NULL. Даты — unix-секунды. [withV4Columns] = false — посев для файла v1:
/// колонок v3/v4/v5 ещё нет.
void _seedV06Data(Database raw, {bool withV4Columns = true}) {
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
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_v7');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'миграция v6 → v7: данные v0.6 целы, долги созданы, дата напоминания NULL',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );
      final Database raw = sqlite3.open(dbFile.path);
      raw.execute('PRAGMA user_version = 6');
      for (final String ddl in _v6Ddl) {
        raw.execute(ddl);
      }
      _seedV06Data(raw);
      raw.close();

      final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      // beforeOpen после миграции: версия поднята до 7.
      final int version =
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          );
      expect(version, 7, reason: 'после открытия база должна быть на v7');

      // Таблицы долгов существуют; структурные колонки §3 на месте
      // (S3-инвариант). Колонки — из D-81 дословно.
      final Map<String, String> debtColumns = await columnTypes(db, 'debts');
      expect(
        debtColumns.keys,
        containsAll(<String>[
          'id',
          'person',
          'direction',
          'amount_minor',
          'extra_minor',
          'currency_code',
          'due_date',
          'note',
          'created_at',
          'updated_at',
          'deleted_at',
        ]),
      );
      expect(debtColumns['id'], 'TEXT');
      expect(debtColumns['person'], 'TEXT');
      expect(debtColumns['direction'], 'TEXT');
      expect(debtColumns['amount_minor'], 'INTEGER');
      expect(debtColumns['extra_minor'], 'INTEGER');
      expect(debtColumns['currency_code'], 'TEXT');
      expect(debtColumns['due_date'], 'TEXT');
      final Map<String, String> paymentColumns = await columnTypes(
        db,
        'debt_payments',
      );
      expect(
        paymentColumns.keys,
        containsAll(<String>[
          'id',
          'debt_id',
          'transaction_id',
          'amount_minor',
          'paid_at',
          'created_at',
          'updated_at',
          'deleted_at',
        ]),
      );
      expect(paymentColumns['id'], 'TEXT');
      expect(paymentColumns['debt_id'], 'TEXT');
      expect(paymentColumns['transaction_id'], 'TEXT');
      expect(paymentColumns['amount_minor'], 'INTEGER');
      expect(paymentColumns['paid_at'], 'TEXT');
      await expectTimestampColumns(db, expectedTablesV7);

      // Дата напоминания о процентах добавлена колонкой TEXT NULL.
      final Map<String, String> accountColumns = await columnTypes(
        db,
        'accounts',
      );
      expect(accountColumns['interest_reminder_date'], 'TEXT');
      final List<Account> accounts = await db.select(db.accounts).get();
      expect(
        accounts.single.interestReminderDate,
        isNull,
        reason: 'нет поля = NULL = обычный счёт (D-81)',
      );

      // FK без каскада: строка в sqlite_master ссылается на родителей,
      // отдельных действий ON DELETE нет (§3, D-25).
      final List<QueryRow> ddlRows = await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('debts', 'debt_payments')",
          )
          .get();
      final Map<String, String> ddlByName = {
        for (final QueryRow row in ddlRows)
          row.read<String>('name'): row.read<String>('sql'),
      };
      expect(ddlByName['debts'], contains('REFERENCES currencies (code)'));
      expect(ddlByName['debt_payments'], contains('REFERENCES debts (id)'));
      expect(
        ddlByName['debt_payments'],
        contains('REFERENCES transactions (id)'),
      );
      expect(ddlByName['debt_payments'], isNot(contains('ON DELETE')));

      // Данных долгов в v6 не было — таблицы пусты.
      expect(await db.select(db.debts).get(), isEmpty);
      expect(await db.select(db.debtPayments).get(), isEmpty);

      // Данные v0.6 выжили дословно.
      final List<Category> categories = await db.select(db.categories).get();
      expect(categories.single.iconCode, 'groceries');
      final List<Transaction> transactions = await db
          .select(db.transactions)
          .get();
      expect(transactions.single.amountMinor, 50050);
      final List<Account> aliveAccounts = await db.select(db.accounts).get();
      expect(aliveAccounts.single.initialBalanceMinor, 1000050);
      expect(aliveAccounts.single.excludeFromBalance, isNull);
    },
  );

  test('цепочка v1 → … → v7: файл v0.1 открывается на текущей схеме', () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 1');
    for (final String ddl in _v1Ddl) {
      raw.execute(ddl);
    }
    // budgets в v1 не существует, колонок v3/v4/v5 и таблиц v6/v7 нет —
    // они появятся в цепочке миграций.
    _seedV06Data(raw, withV4Columns: false);
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
    // вложения и долги созданы (drift хранит boolean() как INTEGER).
    final Map<String, String> accountColumns = await columnTypes(
      db,
      'accounts',
    );
    expect(accountColumns['exclude_from_balance'], 'INTEGER');
    expect(accountColumns['interest_reminder_date'], 'TEXT');
    final Map<String, String> attColumns = await columnTypes(db, 'attachments');
    expect(attColumns['file_path'], 'TEXT');
    expect(attColumns['mime_type'], 'TEXT');
    final Map<String, String> debtColumns = await columnTypes(db, 'debts');
    expect(debtColumns['person'], 'TEXT');
    expect(debtColumns['amount_minor'], 'INTEGER');
    final Map<String, String> paymentColumns = await columnTypes(
      db,
      'debt_payments',
    );
    expect(paymentColumns['paid_at'], 'TEXT');
    final List<Budget> budgets = await db.select(db.budgets).get();
    expect(budgets, isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);
    expect(await db.select(db.debts).get(), isEmpty);
    expect(await db.select(db.debtPayments).get(), isEmpty);
    final List<Transaction> transactions = await db
        .select(db.transactions)
        .get();
    expect(transactions, hasLength(1));
    expect(transactions.single.targetAmountMinor, isNull);
  });

  test(
    'повторное открытие базы v7: без ре-миграции, данные на месте',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );

      final AppDatabase first = AppDatabase.forTesting(NativeDatabase(dbFile));
      await first.currenciesDao.create(code: 'RUB', symbol: '₽', isBase: true);
      final Account savings = await first.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
        initialBalanceMinor: 9900000,
        interestReminderDate: DateTime.utc(2026, 10, 30),
      );
      final Debt debt = await first.debtsDao.create(
        person: 'Алексей',
        direction: DebtDirection.theyOweMe,
        amountMinor: 500000,
        currencyCode: 'RUB',
        extraMinor: 25000,
        dueDate: DateTime.utc(2026, 11, 1),
        note: 'под расписку',
      );
      final Account cash = await first.accountsDao.create(
        name: 'Наличные',
        kind: AccountKind.cash,
        currencyCode: 'RUB',
      );
      final Transaction transfer = await first.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: cash.id,
        targetAccountId: savings.id,
        amountMinor: 100000,
      );
      await first.debtsDao.addPayment(
        debt.id,
        transactionId: transfer.id,
        amountMinor: 100000,
        paidAt: DateTime.utc(2026, 10, 2),
      );
      await first.close();

      // Повторное открытие: onUpgrade не выполняется (версия уже 7),
      // данные живы — счёт, долг, платёж и сводка читаются.
      final AppDatabase second = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      expect(
        (await second.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        7,
      );
      final Account? restored = await second.accountsDao.findById(savings.id);
      expect(restored?.interestReminderDate, isNotNull);
      final DebtSummary? summary = await second.debtsDao
          .watchSummary(debt.id)
          .first;
      expect(summary?.totalMinor, 525000);
      expect(summary?.paidMinor, 100000);
      expect(summary?.remainingMinor, 425000);
    },
  );
}
