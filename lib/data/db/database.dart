import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:kopilka/data/db/dao/attachments_dao.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/tables.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// Локальная база приложения (SQLite через drift).
///
/// Схема v6. v1 — дословно по ARCHITECTURE.md §3; v2 добавляет таблицу
/// `budgets` (M2, D-14); v3 добавляет nullable-колонку
/// `transactions.target_amount_minor` — сумму зачисления перевода между
/// валютами (M3, D-17/D-21); v4 добавляет nullable-колонку
/// `categories.icon_code` — код иконки из справочника core (M5, D-54);
/// v5 добавляет nullable-колонку `accounts.exclude_from_balance` — флаг
/// «не учитывать в балансе» (M5, D-54); v6 добавляет таблицу `attachments` —
/// метаданные вложений к операциям (M5, D-63; файлы — вне БД).
/// Балансы не хранятся: вычисляются запросом из
/// транзакций и `initial_balance_minor` (M1).
///
/// Доступ к данным — через DAO: `currenciesDao`, `accountsDao`,
/// `categoriesDao`, `transactionsDao`, `budgetsDao`, `attachmentsDao`.
/// UI обращается к ним не напрямую, а через Riverpod-контроллеры (§2).
@DriftDatabase(
  tables: [Currencies, Accounts, Categories, Transactions, Budgets, Attachments],
  daos: [
    CurrenciesDao,
    AccountsDao,
    CategoriesDao,
    TransactionsDao,
    BudgetsDao,
    AttachmentsDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// БД приложения: файл `kopilka.sqlite` в каталоге поддержки приложения.
  AppDatabase() : super(_openConnection());

  /// БД на произвольном executor — используется в тестах (in-memory).
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      // Правило эпох (ROADMAP.md): изменение схемы — только новая
      // schema_version + миграция + тест миграции. Цепочка v1→…→v6
      // исполняется по порядку: from < 2 добавляет budgets, from < 3 —
      // колонку переводов (ALTER TABLE без перезаписи данных, D-21),
      // from < 4 — колонку иконок категорий (M5, D-54), from < 5 —
      // колонку флага баланса счетов (M5, D-54), from < 6 — таблицу
      // вложений attachments (M5, D-63; только createTable, без данных).
      if (from < 2) {
        await m.createTable(budgets);
      }
      if (from < 3) {
        await m.addColumn(transactions, transactions.targetAmountMinor);
      }
      if (from < 4) {
        await m.addColumn(categories, categories.iconCode);
      }
      if (from < 5) {
        await m.addColumn(accounts, accounts.excludeFromBalance);
      }
      if (from < 6) {
        await m.createTable(attachments);
      }
    },
    beforeOpen: (OpeningDetails details) async {
      // Ссылочная целостность включена; удаление — только soft delete,
      // каскадов нет (§3).
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

QueryExecutor _openConnection() {
  return LazyDatabase(() async {
    final Directory dir = await getApplicationSupportDirectory();
    final File file = File(p.join(dir.path, 'kopilka.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
