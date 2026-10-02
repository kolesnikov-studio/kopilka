// Тест миграции схемы v7 → v8 (правило эпох, ROADMAP.md: у пользователей
// реальный файл БД v0.1–v0.7, он обязан открыться без потерь).
//
// Приём — по образцу migration_v7_test: файл базы со схемой v7 строится
// сырым sqlite3 API (тот же DDL, что генерировала v0.7, user_version = 7),
// с данными формата v0.7 (долги, накопительный счёт, вложение). Затем файл
// открывается AppDatabase: drift видит user_version 7 < 8 и выполняет
// onUpgrade (createTable plans, createTable scheduled_transfers — без
// перезаписи данных, M7/D-115). Таблицы M7 пусты (данных в v7 не было),
// прежние строки читаются дословно.
//
// Второй сценарий — полная цепочка v1 → … → v8: файл v0.1 открывается
// на текущей схеме, onUpgrade исполняет все шаги по порядку.
//
// sqlite3 здесь — dev-зависимость только для тестов (та же нативная
// библиотека, что бандлит drift).
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:sqlite3/sqlite3.dart';

// S3-хелпер: структурные проверки после миграции идут общими инвариантами
// (образец migration_v4/v5/v6/v7_test).
import '../../helpers/schema_invariants.dart';

/// DDL схемы v1 (v0.1): budgets/attachments/долгов/планов не существует,
/// индексы транзакций на месте.
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

/// DDL схемы v7 (v0.7): v1 + budgets + колонка переводов
/// target_amount_minor + колонка иконок icon_code + флаг баланса
/// exclude_from_balance + attachments + долги/погашения + дата напоминания
/// о процентах. Таблиц M7 (plans/scheduled_transfers) ещё нет.
const List<String> _v7Ddl = <String>[
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
  'ALTER TABLE accounts ADD COLUMN interest_reminder_date TEXT NULL',
  'CREATE TABLE attachments ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'transaction_id TEXT NOT NULL REFERENCES transactions (id), '
      'file_path TEXT NOT NULL, '
      'mime_type TEXT NOT NULL, '
      'file_size INTEGER NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'CREATE TABLE debts ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'person TEXT NOT NULL, '
      'direction TEXT NOT NULL, '
      'amount_minor INTEGER NOT NULL, '
      'extra_minor INTEGER NOT NULL, '
      'currency_code TEXT NOT NULL REFERENCES currencies (code), '
      'due_date TEXT NULL, '
      'note TEXT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
  'CREATE TABLE debt_payments ('
      'id TEXT NOT NULL PRIMARY KEY, '
      'debt_id TEXT NOT NULL REFERENCES debts (id), '
      'transaction_id TEXT NULL REFERENCES transactions (id), '
      'amount_minor INTEGER NOT NULL, '
      'paid_at TEXT NOT NULL, '
      'created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'deleted_at INTEGER NULL)',
];

/// Данные v0.7: посев справочников, счета, категория, операция, вложение,
/// долг и платёж. После миграции всё читается дословно; таблицы M7 пусты.
/// Даты — unix-секунды. [withV4Columns] = false — посев для файла v1:
/// колонок v3/v4/v5/v7 ещё нет, как и таблиц долгов.
void _seedV07Data(Database raw, {bool withV4Columns = true}) {
  final int now = DateTime.utc(2026, 10, 2, 12).millisecondsSinceEpoch ~/ 1000;
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
  if (!withV4Columns) {
    return; // файл v1: ни вложений, ни долгов — таблиц/колонок ещё нет
  }
  raw.execute(
    "INSERT INTO attachments (id, transaction_id, file_path, mime_type, file_size, "
    "created_at, updated_at) "
    "VALUES ('att-1', 'tx-1', 'att-1.png', 'image/png', 4242, $now, $now)",
  );
  raw.execute(
    "INSERT INTO debts (id, person, direction, amount_minor, extra_minor, "
    "currency_code, due_date, note, created_at, updated_at) "
    "VALUES ('debt-1', 'Алексей', 'they_owe_me', 500000, 25000, 'RUB', "
    "'2026-11-01T00:00:00.000Z', 'под расписку', $now, $now)",
  );
  raw.execute(
    "INSERT INTO debt_payments (id, debt_id, transaction_id, amount_minor, paid_at, "
    "created_at, updated_at) "
    "VALUES ('pay-1', 'debt-1', NULL, 100000, '2026-10-02T00:00:00.000Z', $now, $now)",
  );
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kopilka_migration_v8');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'миграция v7 → v8: данные v0.7 целы, plans и scheduled_transfers созданы',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );
      final Database raw = sqlite3.open(dbFile.path);
      raw.execute('PRAGMA user_version = 7');
      for (final String ddl in _v7Ddl) {
        raw.execute(ddl);
      }
      _seedV07Data(raw);
      raw.close();

      final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);

      // beforeOpen после миграции: версия поднята до 8.
      final int version =
          (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          );
      expect(version, 8, reason: 'после открытия база должна быть на v8');

      // Таблицы M7 существуют; структурные колонки §3 на месте
      // (S3-инвариант). Колонки — из D-115 дословно.
      final Map<String, String> planColumns = await columnTypes(db, 'plans');
      expect(
        planColumns.keys,
        containsAll(<String>[
          'id',
          'category_id',
          'period_start',
          'period_end',
          'amount_minor',
          'created_at',
          'updated_at',
          'deleted_at',
        ]),
      );
      expect(planColumns['id'], 'TEXT');
      expect(planColumns['category_id'], 'TEXT');
      expect(planColumns['period_start'], 'TEXT');
      expect(planColumns['period_end'], 'TEXT');
      expect(planColumns['amount_minor'], 'INTEGER');
      final Map<String, String> scheduledColumns = await columnTypes(
        db,
        'scheduled_transfers',
      );
      expect(
        scheduledColumns.keys,
        containsAll(<String>[
          'id',
          'account_id',
          'target_account_id',
          'amount_minor',
          'target_amount_minor',
          'execute_at',
          'commission_minor',
          'commission_category_id',
          'executed_at',
          'executed_transaction_id',
          'created_at',
          'updated_at',
          'deleted_at',
        ]),
      );
      expect(scheduledColumns['id'], 'TEXT');
      expect(scheduledColumns['account_id'], 'TEXT');
      expect(scheduledColumns['target_account_id'], 'TEXT');
      expect(scheduledColumns['amount_minor'], 'INTEGER');
      expect(scheduledColumns['target_amount_minor'], 'INTEGER');
      expect(scheduledColumns['execute_at'], 'TEXT');
      expect(scheduledColumns['commission_minor'], 'INTEGER');
      expect(scheduledColumns['commission_category_id'], 'TEXT');
      expect(scheduledColumns['executed_at'], 'TEXT');
      expect(scheduledColumns['executed_transaction_id'], 'TEXT');
      await expectTimestampColumns(db, expectedTablesV8);

      // FK без каскада: строки в sqlite_master ссылаются на родителей,
      // отдельных действий ON DELETE нет (§3, D-25).
      final List<QueryRow> ddlRows = await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
            "AND name IN ('plans', 'scheduled_transfers')",
          )
          .get();
      final Map<String, String> ddlByName = {
        for (final QueryRow row in ddlRows)
          row.read<String>('name'): row.read<String>('sql'),
      };
      expect(ddlByName['plans'], contains('REFERENCES categories (id)'));
      expect(
        ddlByName['scheduled_transfers'],
        contains('REFERENCES accounts (id)'),
      );
      expect(
        ddlByName['scheduled_transfers'],
        contains('REFERENCES categories (id)'),
      );
      expect(
        ddlByName['scheduled_transfers'],
        contains('REFERENCES transactions (id)'),
      );
      expect(ddlByName['plans'], isNot(contains('ON DELETE')));
      expect(ddlByName['scheduled_transfers'], isNot(contains('ON DELETE')));

      // Данных M7 в v7 не было — таблицы пусты.
      expect(await db.select(db.plans).get(), isEmpty);
      expect(await db.select(db.scheduledTransfers).get(), isEmpty);

      // Данные v0.7 выжили дословно: операция, вложение, долг и платёж.
      final List<Transaction> transactions = await db
          .select(db.transactions)
          .get();
      expect(transactions.single.amountMinor, 50050);
      final Attachment? attachment = await db.attachmentsDao.findByTransaction(
        'tx-1',
      );
      expect(attachment?.fileSize, 4242);
      final DebtSummary? summary = await db.debtsDao
          .watchSummary('debt-1')
          .first;
      expect(summary?.totalMinor, 525000);
      expect(summary?.paidMinor, 100000);
    },
  );

  test('цепочка v1 → … → v8: файл v0.1 открывается на текущей схеме', () async {
    final File dbFile = File(
      '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
    );
    final Database raw = sqlite3.open(dbFile.path);
    raw.execute('PRAGMA user_version = 1');
    for (final String ddl in _v1Ddl) {
      raw.execute(ddl);
    }
    // budgets/attachments/долгов/планов в v1 не существует, колонок
    // v3/v4/v5/v7 нет — они появятся в цепочке миграций.
    _seedV07Data(raw, withV4Columns: false);
    raw.close();

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase(dbFile));
    addTearDown(db.close);

    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      8,
    );

    // Все шаги цепочки исполнены: таблицы M7 созданы и пусты.
    expect(await tableNames(db), containsAll(expectedTablesV8));
    expect(await db.select(db.plans).get(), isEmpty);
    expect(await db.select(db.scheduledTransfers).get(), isEmpty);
    final List<Transaction> transactions = await db
        .select(db.transactions)
        .get();
    expect(transactions, hasLength(1));
    expect(transactions.single.targetAmountMinor, isNull);
  });

  test(
    'повторное открытие базы v8: без ре-миграции, данные на месте',
    () async {
      final File dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}kopilka.sqlite',
      );

      final AppDatabase first = AppDatabase.forTesting(NativeDatabase(dbFile));
      await first.currenciesDao.create(code: 'RUB', symbol: '₽', isBase: true);
      final Account card = await first.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      final Account cash = await first.accountsDao.create(
        name: 'Наличные',
        kind: AccountKind.cash,
        currencyCode: 'RUB',
      );
      final Category food = await first.categoriesDao.create(
        name: 'Продукты',
        kind: CategoryKind.expense,
        isSystem: true,
      );
      final Plan plan = await first.plansDao.create(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 10, 1),
        periodEnd: DateTime.utc(2026, 11, 1),
        amountMinor: 4000000,
      );
      await first.transactionsDao.create(
        type: TransactionType.expense,
        accountId: card.id,
        categoryId: food.id,
        amountMinor: 100000,
        date: DateTime.utc(2026, 10, 2),
      );
      final ScheduledTransfer scheduled = await first.scheduledTransfersDao
          .create(
            accountId: card.id,
            targetAccountId: cash.id,
            amountMinor: 500000,
            executeAt: DateTime.utc(2026, 10, 3),
          );
      await first.close();

      // Повторное открытие: onUpgrade не выполняется (версия уже 8),
      // данные живы — план, факт и отложенный перевод читаются.
      final AppDatabase second = AppDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      expect(
        (await second.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        8,
      );
      final Plan? restored = await second.plansDao.getById(plan.id);
      expect(restored?.amountMinor, 4000000);
      expect(
        DateTime.parse(restored!.periodStart).toUtc(),
        DateTime.utc(2026, 10, 1),
      );
      final List<PlanVsFact> vsFact = await second.plansDao
          .watchPlanVsFact(
            from: DateTime.utc(2026, 10),
            to: DateTime.utc(2026, 11),
          )
          .first;
      expect(vsFact.single.factMinor, 100000);
      final List<ScheduledTransfer> due = await second.scheduledTransfersDao
          .watchDue(now: DateTime.utc(2026, 10, 5))
          .first;
      expect(due.single.id, scheduled.id);
    },
  );
}
