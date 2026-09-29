import 'package:drift/drift.dart';
import 'package:kopilka/core/category_icons.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/attachments_service.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

// Формат бэкапа (ARCHITECTURE.md §4):
//
// {
//   "schema_version": 3,
//   "exported_at": "2026-09-25T00:00:00.000Z",
//   "data": { "currencies": [...], "accounts": [...], ..., "budgets": [...] }
// }
//
// v3 (M3, D-21): в строках transactions появилось необязательное поле
// target_amount_minor (сумма зачисления перевода между валютами, D-17);
// чтение v1/v2 не меняется — нет поля = NULL.
//
// v4 (M5, D-54): в строках categories появилось необязательное поле
// icon_code (код из справочника core/category_icons.dart); чтение v1/v2/v3
// не меняется — нет поля = NULL. Валидация строгая (прецедент D-25):
// неизвестный справочнику код — отказ импорта, не тихий пропуск.
//
// v5 (M5, D-54): в строках accounts появилось необязательное поле
// exclude_from_balance (флаг «не учитывать в балансе»); чтение v1–v4
// не меняется — нет поля = NULL («учитывать»). Валидация строгая
// (прецедент D-25): не-булево значение — отказ импорта.
//
// v6 (M5, D-64): в data появилась таблица attachments (метаданные вложений
// к операциям, D-63) — строки таблицы БД в общем механизме дампа. Файлы
// вложений в бэкап НЕ входят (JSON — данные, не blobs): импорт восстанав-
// ливает только метаданные, отсутствие файла на диске — норма. Чтение
// v1–v5 не меняется: нет ключа `attachments` = пустой список (образец
// v1→v2 в каркасе миграций формата).
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
/// дамп таблиц v6.
const int backupSchemaVersion = 6;

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

/// Каркас миграций формата экспорта: `schema_version` файла → текущая
/// версия.
///
/// Правило эпох (см. ROADMAP.md) касается и формата экспорта: новые версии
/// добавляются сюда, старые файлы обязаны читаться. v1 → v2: таблица
/// `budgets` появилась в v2, старый файл дополняется пустым списком.
/// v2 → v3: правки не требует — в v3 только необязательное поле строк
/// transactions, его отсутствие означает NULL (D-21). v3 → v4: правки не
/// требует — в v4 только необязательное поле строк categories, его
/// отсутствие означает NULL (D-54). v4 → v5: правки не требует — в v5
/// только необязательное поле строк accounts, его отсутствие означает
/// NULL («учитывать», D-54). v5 → v6: правки не требует — в v6 добавилась
/// таблица attachments, её отсутствие в файле означает пустой список
/// (D-64).
Map<String, dynamic> Function(Map<String, dynamic>) _migrateFrom(int from) {
  return switch (from) {
    6 => (Map<String, dynamic> document) => document,
    5 => (Map<String, dynamic> document) => document,
    4 => (Map<String, dynamic> document) => document,
    3 => (Map<String, dynamic> document) => document,
    2 => (Map<String, dynamic> document) => document,
    1 => (Map<String, dynamic> document) {
        final Map<String, dynamic> data = _requireObject(document['data'], 'data');
        data['budgets'] = const <dynamic>[];
        return document;
      },
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

const Set<String> _boolColumns = <String>{
  'is_base',
  'is_system',
  // v5 (D-54): флаг «не учитывать в балансе» — обычная булева колонка
  // SQLite (0/1/NULL); на экспорте нормализуется в true/false/null.
  'exclude_from_balance',
};

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

/// Полный дамп базы в JSON-объект текущего формата (§4: все таблицы,
/// включая мягко удалённые строки). Имена таблиц — только из константного
/// белого списка [dumpedTables] (A15): интерполяция имени в SELECT
/// допустима, когда источник имени — фиксированный список кода.
Future<Map<String, dynamic>> exportToJson(AppDatabase db) async {
  Future<List<Map<String, dynamic>>> dumpTable(String table) async {
    assert(dumpedTables.contains(table));
    return <Map<String, dynamic>>[
      for (final QueryRow row
          in await db.customSelect('SELECT * FROM $table').get())
        encodeRow(row.data),
    ];
  }

  final Map<String, Object?> data = <String, Object?>{
    'currencies': await dumpTable('currencies'),
    'accounts': await dumpTable('accounts'),
    'categories': await dumpTable('categories'),
    'transactions': await dumpTable('transactions'),
    'budgets': await dumpTable('budgets'),
    // v6 (D-64): метаданные вложений в общем механизме дампа. Файлы
    // вложений в бэкап не входят (D-63): JSON — данные, не blobs.
    'attachments': await dumpTable('attachments'),
  };
  return <String, dynamic>{
    'schema_version': backupSchemaVersion,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'data': data,
  };
}

/// Белый список таблиц дампа (A15): единственный источник имён для
/// SELECT-интерполяции; должен совпадать с набором `data` выше.
const Set<String> dumpedTables = <String>{
  'currencies',
  'accounts',
  'categories',
  'transactions',
  'budgets',
  'attachments',
};

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
        // v5 (D-54): необязательное поле; нет поля = NULL («учитывать»,
        // файлы v1–v4). Строгая валидация по образцу icon_code (D-25):
        // не-булево значение — отказ импорта, не тихая нормализация.
        excludeFromBalance: switch (row['exclude_from_balance']) {
          null => null,
          final bool value => value,
          _ => throw BackupValidationException(
              'accounts.exclude_from_balance должен быть булевым или отсутствовать',
              kind: BackupFailure.invalidData,
            ),
        },
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
        // v4 (D-54): необязательное поле; нет поля = NULL (v1/v2/v3).
        // Строгая валидация: неизвестный справочнику код — отказ импорта
        // (прецедент D-25), не тихий пропуск.
        iconCode: switch (_optionalString(row['icon_code'], 'categories.icon_code')) {
          null => null,
          final String code when categoryIconByCode(code) != null => code,
          final String code => throw BackupValidationException(
              'categories.icon_code: неизвестный справочнику код «$code» — '
              'отказ импорта (D-54/D-25)',
              kind: BackupFailure.invalidData,
            ),
        },
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
        // v3 (D-21): необязательное поле; нет поля = NULL (файлы v1/v2).
        targetAmountMinor: row['target_amount_minor'] == null
            ? null
            : _requireInt(
                row['target_amount_minor'],
                'transactions.target_amount_minor',
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

  final List<BackupBudget> budgets = <BackupBudget>[
    for (final Map<String, dynamic> row in _requireTable(data['budgets'], 'budgets'))
      BackupBudget(
        id: _requireString(row['id'], 'budgets.id'),
        categoryId: _requireString(row['category_id'], 'budgets.category_id'),
        limitMinor: _requireInt(row['limit_minor'], 'budgets.limit_minor'),
        createdAt: _requireDate(row['created_at'], 'budgets.created_at'),
        updatedAt: _requireDate(row['updated_at'], 'budgets.updated_at'),
        deletedAt: row['deleted_at'] == null
            ? null
            : _requireDate(row['deleted_at'], 'budgets.deleted_at'),
      ),
  ];

  // v6 (D-64): чтение v1–v5 не меняется — нет ключа `attachments` =
  // пустой список (образец v1→v2 в каркасе миграций формата); ключ есть,
  // но не массив — отказ invalidFormat по общему правилу _requireTable.
  final List<BackupAttachment> attachments = <BackupAttachment>[
    for (final Map<String, dynamic> row in data['attachments'] == null
        ? const <Map<String, dynamic>>[]
        : _requireTable(data['attachments'], 'attachments'))
      BackupAttachment(
        id: _requireString(row['id'], 'attachments.id'),
        transactionId: _requireString(
          row['transaction_id'],
          'attachments.transaction_id',
        ),
        // Строгая валидация строки (D-64): mime — только из белого
        // списка (широкий isMimeTypeAllowed), размер — неотрицательный
        // int; отказ импорта, не тихая нормализация (прецедент D-25).
        filePath: _requireString(row['file_path'], 'attachments.file_path'),
        mimeType: switch (_requireString(row['mime_type'], 'attachments.mime_type')) {
          final String mime when AttachmentsStorage.isMimeTypeAllowed(mime) =>
            mime,
          final String mime => throw BackupValidationException(
              'attachments.mime_type: тип «$mime» вне белого списка '
              '(image/*, application/pdf) — отказ импорта (D-64)',
              kind: BackupFailure.invalidData,
            ),
        },
        fileSize: switch (_requireInt(row['file_size'], 'attachments.file_size')) {
          final int size when size >= 0 => size,
          final int size => throw BackupValidationException(
              'attachments.file_size: отрицательный размер $size — '
              'отказ импорта (D-64)',
              kind: BackupFailure.invalidData,
            ),
        },
        createdAt: _requireDate(row['created_at'], 'attachments.created_at'),
        updatedAt: _requireDate(row['updated_at'], 'attachments.updated_at'),
        deletedAt: row['deleted_at'] == null
            ? null
            : _requireDate(row['deleted_at'], 'attachments.deleted_at'),
      ),
  ];

  return DecodedBackup(
    schemaVersion: version,
    exportedAt: exportedAt,
    currencies: currencies,
    accounts: accounts,
    categories: categories,
    transactions: transactions,
    budgets: budgets,
    attachments: attachments,
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
    required this.budgets,
    required this.attachments,
    this.exportedAt,
  });

  /// Версия формата исходного файла (до миграции).
  final int schemaVersion;
  final DateTime? exportedAt;
  final List<BackupCurrency> currencies;
  final List<BackupAccount> accounts;
  final List<BackupCategory> categories;
  final List<BackupTransaction> transactions;
  final List<BackupBudget> budgets;

  /// Метаданные вложений (v6, D-64); у файлов v1–v5 ключа нет — пустой
  /// список. Файлов на диске бэкап не переносит: импорт восстанавливает
  /// только метаданные (D-63).
  final List<BackupAttachment> attachments;
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
    this.excludeFromBalance,
    this.deletedAt,
  });

  final String id;
  final String name;
  final AccountKind kind;
  final String currencyCode;
  final int initialBalanceMinor;
  final int sortOrder;

  /// Флаг «не учитывать в балансе» (v5, D-54): NULL/false = учитывать;
  /// у файлов v1–v4 поля нет — читается как NULL.
  final bool? excludeFromBalance;
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
    this.iconCode,
    this.color,
    this.deletedAt,
  });

  final String id;
  final String name;
  final CategoryKind kind;
  final String? parentId;
  final String? icon;

  /// Код иконки из справочника (v4, D-54): NULL = без иконки; у файлов
  /// v1/v2/v3 поля нет — читается как NULL. Значение уже сверено
  /// со справочником при декодировании (строгая валидация).
  final String? iconCode;
  final String? color;
  final bool isSystem;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Бюджет дампа.
class BackupBudget {
  const BackupBudget({
    required this.id,
    required this.categoryId,
    required this.limitMinor,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String categoryId;
  final int limitMinor;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}

/// Вложение дампа (v6, D-64): только метаданные — файл на диске бэкап
/// не переносит (D-63), после импорта отсутствие файла — норма.
class BackupAttachment {
  const BackupAttachment({
    required this.id,
    required this.transactionId,
    required this.filePath,
    required this.mimeType,
    required this.fileSize,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  final String id;
  final String transactionId;
  final String filePath;
  final String mimeType;
  final int fileSize;
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
    this.targetAmountMinor,
    this.categoryId,
    this.note,
    this.deletedAt,
  });

  final String id;
  final TransactionType type;
  final String accountId;
  final String? targetAccountId;

  /// Сумма зачисления перевода (v3, D-17/D-21): NULL = перевод в одной
  /// валюте или не-перевод; у файлов v1/v2 поля нет — читается как NULL.
  final int? targetAmountMinor;
  final String? categoryId;
  final int amountMinor;
  final String currencyCode;
  final DateTime date;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
}
