import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
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
/// Схема v2. v1 — дословно по ARCHITECTURE.md §3; v2 добавляет таблицу
/// `budgets` (M2, D-14). Балансы не хранятся: вычисляются запросом из
/// транзакций и `initial_balance_minor` (M1).
///
/// Доступ к данным — через DAO: `currenciesDao`, `accountsDao`,
/// `categoriesDao`, `transactionsDao`, `budgetsDao`. UI обращается к ним
/// не напрямую, а через Riverpod-контроллеры (§2).
@DriftDatabase(
  tables: [Currencies, Accounts, Categories, Transactions, Budgets],
  daos: [CurrenciesDao, AccountsDao, CategoriesDao, TransactionsDao, BudgetsDao],
)
class AppDatabase extends _$AppDatabase {
  /// БД приложения: файл `kopilka.sqlite` в каталоге поддержки приложения.
  AppDatabase() : super(_openConnection());

  /// БД на произвольном executor — используется в тестах (in-memory).
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      // Правило эпох (ROADMAP.md): изменение схемы — только новая
      // schema_version + миграция + тест миграции.
      if (from < 2) {
        await m.createTable(budgets);
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
