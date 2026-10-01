// S3: хелпер табличных инвариантов — общие проверки схемы для тестов
// миграций и структуры БД (одобрен при ревью M3-шага 1; на схеме v3 оправдан: таблиц стало пять, инварианты
// проверяются в трёх тест-файлах).
//
// Инварианты (§3):
// - каждая таблица содержит created_at / updated_at / deleted_at;
// - колонки денег — INTEGER (передаются вызывающим списком полей);
// - PK — TEXT.
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';

/// Все таблицы схемы БД (sqlite_master, без служебных sqlite_%).
Future<Set<String>> tableNames(AppDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      )
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}

/// Ожидаемый набор таблиц схемы v3 (пять: четыре §3 + budgets v2).
const Set<String> expectedTables = <String>{
  'currencies',
  'accounts',
  'categories',
  'transactions',
  'budgets',
};

/// Ожидаемый набор таблиц схемы v6: пять выше + attachments (v6, D-63).
const Set<String> expectedTablesPlusAttachments = <String>{
  ...expectedTables,
  'attachments',
};

/// Ожидаемый набор таблиц схемы v7: выше + debts и debt_payments
/// (v7, M6/D-81).
const Set<String> expectedTablesV7 = <String>{
  ...expectedTablesPlusAttachments,
  'debts',
  'debt_payments',
};

/// Инвариант служебных колонок: в каждой таблице [tables] есть
/// created_at, updated_at, deleted_at (§3).
Future<void> expectTimestampColumns(
  AppDatabase db,
  Iterable<String> tables,
) async {
  for (final String table in tables) {
    final Map<String, String> columns = await columnTypes(db, table);
    expect(columns, contains('created_at'), reason: 'таблица $table');
    expect(columns, contains('updated_at'), reason: 'таблица $table');
    expect(columns, contains('deleted_at'), reason: 'таблица $table');
  }
}

/// Типы колонок таблицы (имя → тип SQLite).
Future<Map<String, String>> columnTypes(AppDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect('PRAGMA table_info($table)')
      .get();
  return {
    for (final QueryRow row in rows)
      row.read<String>('name'): row.read<String>('type'),
  };
}

/// Инвариант типов: колонки [expectedTypes] таблицы [table] имеют
/// объявленные типы (деньги — INTEGER, PK — TEXT и т. п.).
Future<void> expectColumnTypes(
  AppDatabase db,
  String table,
  Map<String, String> expectedTypes,
) async {
  final Map<String, String> columns = await columnTypes(db, table);
  expectedTypes.forEach((String column, String type) {
    expect(columns[column], type, reason: '$table.$column');
  });
}

/// Индексы таблицы по имени (sqlite_master; миграция обязана сохранять
/// индексы — createAll не трогает существующие).
Future<Set<String>> indexNames(AppDatabase db, String table) async {
  final List<QueryRow> rows = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?",
        variables: [Variable<String>(table)],
      )
      .get();
  return rows.map((QueryRow row) => row.read<String>('name')).toSet();
}
