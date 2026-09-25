import 'package:drift/drift.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

// Формат бэкапа (ARCHITECTURE.md §4):
//
// {
//   "schema_version": 1,
//   "exported_at": "2026-09-25T00:00:00.000Z",
//   "data": { "currencies": [...], "accounts": [...], ... }
// }
//
// Правила §3, которые кодек обязан воспроизводить дословно:
// - PK — UUID v4 (TEXT), сгенерирован приложением при создании записи;
// - каждая строка содержит created_at/updated_at (UTC) и deleted_at
//   (NULL = живая запись): бэкап — ПОЛНЫЙ дамп, включая мягко удалённые;
// - деньги — INTEGER в минорных единицах;
// - значения kind/type — канонические строки (enums.dart), при чтении
//   проверяются: неизвестное значение — отказ, не тихий пропуск.
//
// Кодек не знает про UI: ошибки — [BackupValidationException] с
// машиночитаемым видом, локализованный текст подбирает вызывающий код.

/// Текущая версия формата экспорта. Совпадает с schema_version БД: полный
/// дамп таблиц v1.
const int backupSchemaVersion = 1;

/// Нарушение формата бэкапа: старая/новая версия, битые строки, неизвестные
/// значения справочников. [kind] машиночитаем — для локализованного
/// сообщения в UI; [detail] — техническое описание для логов.
class BackupValidationException implements Exception {
  BackupValidationException(this.detail, {required this.kind});

  final String detail;
  final BackupFailure kind;

  @override
  String toString() => 'BackupValidationException($kind): $detail';
}

/// Виды отказов формата бэкапа, которые UI объясняет пользователю.
enum BackupFailure {
  /// JSON не разобрался или не является объектом нужной формы.
  invalidFormat,

  /// schema_version новее поддерживаемой.
  tooNew,

  /// schema_version старше поддерживаемой и не имеет миграции формата.
  tooOld,

  /// Данные внутри не соответствуют схеме v1 (битые строки, неизвестные
  /// значения kind/type, отсутствующие PK, некорректные даты/суммы).
  invalidData,
}

/// Каркас миграций формата экспорта: `schema_version` файла → v1.
///
/// Правило эпох (см. ROADMAP.md) касается и формата экспорта: новые версии
/// добавляются сюда, старые файлы обязаны читаться. Миграций пока нет:
/// v1 — первая версия формата.
Map<String, dynamic> Function(Map<String, dynamic>) _migrateFrom(int from) {
  return switch (from) {
    1 => (Map<String, dynamic> document) => document,
    _ => throw BackupValidationException(
        'нет миграции формата экспорта с версии $from',
        kind: BackupFailure.tooOld,
      ),
  };
}

Map<String, dynamic> _requireObject(Object? value, String what) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, dynamic>(
      (Object? key, Object? value) =>
          MapEntry<String, dynamic>(key.toString(), value),
    );
  }
  throw BackupValidationException(
    '$what должен быть объектом',
    kind: BackupFailure.invalidFormat,
  );
}

List<Map<String, dynamic>> _requireTable(Object? value, String name) {
  if (value is! List) {
    throw BackupValidationException(
      'таблица $name должна быть массивом строк',
      kind: BackupFailure.invalidFormat,
    );
  }
  return value
      .map<Map<String, dynamic>>(
        (Object? row) => _requireObject(row, 'строка таблицы $name'),
      )
      .toList();
}

DateTime _requireDate(Object? value, String what) {
  if (value is! String) {
    throw BackupValidationException(
      '$what должна быть строкой ISO-8601',
      kind: BackupFailure.invalidData,
    );
  }
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw BackupValidationException(
      '$what: некорректная дата «$value»',
      kind: BackupFailure.invalidData,
    );
  }
  return parsed.toUtc();
}

int _requireInt(Object? value, String what) {
  if (value is! int) {
    throw BackupValidationException(
      '$what должен быть целым числом',
      kind: BackupFailure.invalidData,
    );
  }
  return value;
}

String _requireString(Object? value, String what) {
  if (value is! String || value.isEmpty) {
    throw BackupValidationException(
      '$what должен быть непустой строкой',
      kind: BackupFailure.invalidData,
    );
  }
  return value;
}

String? _optionalString(Object? value, String what) =>
    value == null ? null : optionalText(_requireString(value, what));

/// Разбирает каноническое значение перечисления, переводя отказ в
/// [BackupValidationException] с видом [BackupFailure.invalidData] —
/// неизвестное значение в файле бэкапа это битые данные формата, а не
/// ошибка правила данных DAO.
T _enumFromDb<T>(
  T Function(String value) parse,
  Object? value,
  String what,
) {
  final String raw = _requireString(value, what);
  try {
    return parse(raw);
  } on DataValidationException catch (error) {
    throw BackupValidationException(
      '$what: ${error.message}',
      kind: BackupFailure.invalidData,
    );
  }
}

/// Колонки дампа, которые SQLite хранит сырыми int: даты — unix-секунды,
/// булевы — 0/1. customSelect отдаёт значения без типовой маппинга drift,
/// поэтому кодек нормализует их в формат v1 (ISO-строки и bool).
const Set<String> _dateColumns = <String>{
  'created_at',
  'updated_at',
  'deleted_at',
  'date',
};

const Set<String> _boolColumns = <String>{'is_base', 'is_system'};

Object? _encodeValue(String column, Object? value) {
  if (value == null) {
    return null;
  }
  if (_boolColumns.contains(column)) {
    return (value as int) != 0;
  }
  if (_dateColumns.contains(column)) {
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(
        value * 1000,
        isUtc: true,
      ).toIso8601String();
    }
    if (value is DateTime) {
      return value.toUtc().toIso8601String();
    }
    return value; // уже строка ISO
  }
  return value;
}

/// Сериализует сырую строку таблицы (customSelect: snake_case-колонки, даты
/// — unix-секунды, булевы — 0/1) в JSON-объект формата v1.
Map<String, dynamic> encodeRow(Map<String, Object?> row) => <String, dynamic>{
      for (final MapEntry<String, Object?> field in row.entries)
        field.key: _encodeValue(field.key, field.value),
    };

/// Полный дамп базы в JSON-объект формата v1 (§4: все четыре таблицы,
/// включая мягко удалённые строки).
Future<Map<String, dynamic>> exportToJson(AppDatabase db) async {
  Future<List<Map<String, dynamic>>> dumpTable(String table) async =>
      <Map<String, dynamic>>[
        for (final QueryRow row
            in await db.customSelect('SELECT * FROM $table').get())
          encodeRow(row.data),
      ];

  final Map<String, Object?> data = <String, Object?>{
    'currencies': await dumpTable('currencies'),
    'accounts': await dumpTable('accounts'),
    'categories': await dumpTable('categories'),
    'transactions': await dumpTable('transactions'),
  };
  return <String, dynamic>{
    'schema_version': backupSchemaVersion,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'data': data,
  };
}

/// Разбирает JSON-документ бэкапа в типизированный дамп с миграцией формата.
///
/// Проверяет соответствие схеме v1: PK, ссылки-поля, канонические значения
/// kind/type, корректные даты. Порядок записи задаёт сервис импорта.
DecodedBackup decodeJson(Map<String, dynamic> document) {
  final int version = switch (document['schema_version']) {
    final int value => value,
    _ => throw BackupValidationException(
        'schema_version должен быть целым числом',
        kind: BackupFailure.invalidFormat,
      ),
  };
  if (version > backupSchemaVersion) {
    throw BackupValidationException(
      'файл создан более новой версией приложения ($version > $backupSchemaVersion)',
      kind: BackupFailure.tooNew,
    );
  }
  final Map<String, dynamic> migrated = _migrateFrom(version)(document);
  final DateTime? exportedAt = migrated['exported_at'] == null
      ? null
      : _requireDate(migrated['exported_at'], 'exported_at');
  final Map<String, dynamic> data = _requireObject(migrated['data'], 'data');

  final List<BackupCurrency> currencies = <BackupCurrency>[
    for (final Map<String, dynamic> row
        in _requireTable(data['currencies'], 'currencies'))
      BackupCurrency(
        code: _requireString(row['code'], 'currencies.code'),
        symbol: _requireString(row['symbol'], 'currencies.symbol'),
        isBase: row['is_base'] == true,
        rateToBase: switch (row['rate_to_base']) {
          final double value => value,
          final int value => value.toDouble(),
          _ => throw BackupValidationException(
              'currencies.rate_to_base должен быть числом',
              kind: BackupFailure.invalidData,
            ),
        },
        createdAt: _requireDate(row['created_at'], 'currencies.created_at'),
        updatedAt: _requireDate(row['updated_at'], 'currencies.updated_at'),
        deletedAt: row['deleted_at'] == null
            ? null
            : _requireDate(row['deleted_at'], 'currencies.deleted_at'),
      ),
  ];

  final List<BackupAccount> accounts = <BackupAccount>[
    for (final Map<String, dynamic> row
        in _requireTable(data['accounts'], 'accounts'))
      BackupAccount(
        id: _requireString(row['id'], 'accounts.id'),
        name: _requireString(row['name'], 'accounts.name'),
        kind: _enumFromDb(
          AccountKind.fromDb,
          row['kind'],
          'accounts.kind',
        ),
        currencyCode: _requireString(
          row['currency_code'],
          'accounts.currency_code',
        ),
        initialBalanceMinor: row['initial_balance_minor'] == null
            ? 0
            : _requireInt(
                row['initial_balance_minor'],
                'accounts.initial_balance_minor',
              ),
        sortOrder: row['sort_order'] == null
            ? 0
            : _requireInt(row['sort_order'], 'accounts.sort_order'),
        createdAt: _requireDate(row['created_at'], 'accounts.created_at'),
        updatedAt: _requireDate(row['updated_at'], 'accounts.updated_at'),
        deletedAt: row['deleted_at'] == null
            ? null
            : _requireDate(row['deleted_at'], 'accounts.deleted_at'),
      ),
  ];

  final List<BackupCategory> categories = <BackupCategory>[
    for (final Map<String, dynamic> row
        in _requireTable(data['categories'], 'categories'))
      BackupCategory(
        id: _requireString(row['id'], 'categories.id'),
        name: _requireString(row['name'], 'categories.name'),
        kind: _enumFromDb(
          CategoryKind.fromDb,
          row['kind'],
          'categories.kind',
        ),
        parentId: _optionalString(row['parent_id'], 'categories.parent_id'),
        icon: _optionalString(row['icon'], 'categories.icon'),
        color: _optionalString(row['color'], 'categories.color'),
        isSystem: row['is_system'] == true,
        createdAt: _requireDate(row['created_at'], 'categories.created_at'),
        updatedAt: _requireDate(row['updated_at'], 'categories.updated_at'),
        deletedAt: row['deleted_at'] == null
            ? null
            : _requireDate(row['deleted_at'], 'categories.deleted_at'),
      ),
  ];

  final List<BackupTransaction> transactions = <BackupTransaction>[
    for (final Map<String, dynamic> row
        in _requireTable(data['transactions'], 'transactions'))
      BackupTransaction(
        id: _requireString(row['id'], 'transactions.id'),
        type: _enumFromDb(
          TransactionType.fromDb,
          row['type'],
          'transactions.type',
        ),
        accountId: _requireString(row['account_id'], 'transactions.account_id'),
        targetAccountId: _optionalString(
          row['target_account_id'],
          'transactions.target_account_id',
        ),
        categoryId: _optionalString(
          row['category_id'],
          'transactions.category_id',
        ),
        amountMinor: _requireInt(
          row['amount_minor'],
          'transactions.amount_minor',
        ),
        currencyCode: _requireString(
          row['currency_code'],
          'transactions.currency_code',
        ),
        date: _requireDate(row['date'], 'transactions.date'),
        note: _optionalString(row['note'], 'transactions.note'),
        createdAt: _requireDate(row['created_at'], 'transactions.created_at'),
        updatedAt: _requireDate(row['updated_at'], 'transactions.updated_at'),
        deletedAt: row['deleted_at'] == null
            ? null
            : _requireDate(row['deleted_at'], 'transactions.deleted_at'),
      ),
  ];

  return DecodedBackup(
    schemaVersion: version,
    exportedAt: exportedAt,
    currencies: currencies,
    accounts: accounts,
    categories: categories,
    transactions: transactions,
  );
}

/// Разобранный дамп: строки таблиц в типизированном виде, готовы к записи.
class DecodedBackup {
  const DecodedBackup({
    required this.schemaVersion,
    required this.currencies,
    required this.accounts,
    required this.categories,
    required this.transactions,
    this.exportedAt,
  });

  /// Версия формата исходного файла (до миграции).
  final int schemaVersion;
  final DateTime? exportedAt;
  final List<BackupCurrency> currencies;
  final List<BackupAccount> accounts;
  final List<BackupCategory> categories;
  final List<BackupTransaction> transactions;
}

/// Валюта дампа.
class BackupCurrency {
  const BackupCurrency({
    required this.code,
    required this.symbol,
    required this.isBase,
    required this.rateToBase,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String code;
  final String symbol;
  final bool isBase;
  final double rateToBase;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Счёт дампа.
class BackupAccount {
  const BackupAccount({
    required this.id,
    required this.name,
    required this.kind,
    required this.currencyCode,
    required this.initialBalanceMinor,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String name;
  final AccountKind kind;
  final String currencyCode;
  final int initialBalanceMinor;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Категория дампа.
class BackupCategory {
  const BackupCategory({
    required this.id,
    required this.name,
    required this.kind,
    required this.isSystem,
    required this.createdAt,
    required this.updatedAt,
    this.parentId,
    this.icon,
    this.color,
    this.deletedAt,
  });

  final String id;
  final String name;
  final CategoryKind kind;
  final String? parentId;
  final String? icon;
  final String? color;
  final bool isSystem;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Операция дампа.
class BackupTransaction {
  const BackupTransaction({
    required this.id,
    required this.type,
    required this.accountId,
    required this.amountMinor,
    required this.currencyCode,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
    this.targetAccountId,
    this.categoryId,
    this.note,
    this.deletedAt,
  });

  final String id;
  final TransactionType type;
  final String accountId;
  final String? targetAccountId;
  final String? categoryId;
  final int amountMinor;
  final String currencyCode;
  final DateTime date;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}
