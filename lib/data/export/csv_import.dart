import 'package:drift/drift.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

// Импорт CSV (M4-шаг 2): слой данных для «файла нашего экспорта» и чужих
// таблиц с тем же набором полей. Экспорт — отчётный формат v0.3
// (BackupService.exportTransactionsCsv): разделитель ';', кавычки '"'
// с удвоением, сумма мажорным числом с точкой по экспоненту валюты (D-15),
// даты ISO-8601 UTC (§3), имена счетов/категорий — человекочитаемые.
//
// Контракт (бриф M4-шага 2):
// - merge, а не полная замена (как у JSON-бэкапа): операции ДОБАВЛЯЮТСЯ
//   к живой базе, справочники не трогаются;
// - id генерируются заново, ссылки на счета/категории — по имени;
// - валидация строгая по образцу D-25: любое нарушение — отказ ВСЕГО
//   импорта с номером строки, частичной загрузки нет (одна транзакция).
//
// Кодек не знает про UI: ошибки — CsvImportException с машиночитаемым
// видом, локализованный текст подбирает вызывающий код.

/// CSV-колонки v0.3 в порядке экспорта — дефолт маппинга.
const List<String> csvExportColumnsV03 = <String>[
  'id',
  'date',
  'type',
  'account',
  'target_account',
  'category',
  'amount',
  'currency',
  'note',
];

/// Поле CSV-строки, в которое маппится колонка файла.
enum CsvField {
  /// Момент операции, ISO-8601 UTC — как в экспорте v0.3.
  date,

  /// Тип операции: `income` | `expense` | `transfer` (enums.dart).
  type,

  /// Имя счёта списания (для не-перевода — просто счёт операции).
  account,

  /// Сумма мажорным числом с точкой (формат экспорта A14/D-15).
  amount,

  /// Код валюты ISO 4217.
  currency,

  /// Имя счёта зачисления (только перевод; пустая ячейка = не перевод).
  targetAccount,

  /// Сумма зачисления мажорным числом (D-17): обязательна у перевода между
  /// разными валютами, пустая у одно-валютного перевода и не-перевода.
  /// В CSV-экспорте v0.3 этой колонки нет — маппинг по умолчанию её не
  /// задаёт (см. `csvMappingFromExportV03`).
  targetAmount,

  /// Имя категории (у перевода пусто; пустая ячейка = без категории).
  category,

  /// Комментарий; пустая ячейка = без заметки.
  note,
}

/// Нарушение CSV-файла или маппинга: [line] — номер логической строки
/// файла (1 = шапка, данные со 2; строки с кавычками-переносами считаются
/// одной строкой), [detail] — причина для логов/UI.
class CsvImportException implements Exception {
  CsvImportException(this.detail, {required this.kind, required this.line});

  final String detail;
  final CsvImportFailure kind;
  final int line;

  @override
  String toString() => 'CsvImportException($kind, line $line): $detail';
}

/// Виды отказа импорта CSV, объясняемые пользователю.
enum CsvImportFailure {
  /// Файл не разобрался: незакрытые кавычки, кавычки вне поля и т. п.
  invalidFormat,

  /// Маппинг колонок пуст, с дублями или без обязательных полей.
  invalidMapping,

  /// Строка данных не соответствует правилам слоя данных (D-25/D-17).
  invalidData,
}

/// Маппинг «индекс колонки файла → поле»: ключи — индексы колонок
/// разобранной шапки/строк, значения — поля импорта.
typedef CsvColumnMapping = Map<int, CsvField>;

/// Дефолтный маппинг по заголовкам CSV-экспорта v0.3: позиции известны,
/// шапка файла нужна только человеку.
CsvColumnMapping csvMappingFromExportV03() => <int, CsvField>{
      1: CsvField.date,
      2: CsvField.type,
      3: CsvField.account,
      6: CsvField.amount,
      7: CsvField.currency,
      4: CsvField.targetAccount,
      5: CsvField.category,
      8: CsvField.note,
    };

/// Разбирает CSV-текст RFC-4180 с разделителем `;` (формат экспорта v0.3):
/// кавычки закрывают поля с `;`, `"` и переносами строк, `""` внутри
/// кавычек = `"`, BOM первой ячейки снимается, `\r\n` и `\n` — концы
/// строк, `\r` внутри кавычек — часть значения. Последняя строка без
/// перевода строки — полноценная строка данных.
///
/// Возвращает «логические» строки (строка с переносом внутри кавычек —
/// одна запись). Пустые физические строки (только `\n` / `\r\n`) — шум
/// файлов, правленных руками: пропускаются. Пустые ячейки сохраняются:
/// `a;` — две колонки, вторая пустая; `;;` — три пустых (валидация строки
/// объяснит, чего ей не хватило).
List<List<String>> parseCsv(String input) {
  // BOM любой UTF-серии (EF BB BF / FE FF / FF FE) — снимаем целиком:
  // в первой ячейке он остался бы значением поля и сломал бы шапку/дату.
  const String bom = '\uFEFF';
  String text = input;
  if (text.startsWith(bom)) {
    text = text.substring(1);
  }

  final List<List<String>> records = <List<String>>[];
  List<String> record = <String>[];
  final StringBuffer field = StringBuffer();
  bool inQuotes = false;
  bool fieldQuoted = false;
  bool anyFieldWritten = false;

  void endField() {
    final String value = field.toString();
    // Поле из одних пробелов вне кавычек — пустое: экспорт пустых полей
    // выдаёт '', правленый руками файл может выдать ' '. Кавычки снимаются
    // парсером, пробелы внутри кавычек — данные и сохраняются.
    record.add(fieldQuoted ? value : value.trim());
    field.clear();
    fieldQuoted = false;
    anyFieldWritten = true;
  }

  void endRecord() {
    // Содержательность записи решаем ДО endField: после него флаг уже
    // поднят, и пустая строка `\n` не отличалась бы от `;;`.
    final bool hasContent =
        anyFieldWritten || fieldQuoted || field.isNotEmpty;
    endField();
    if (hasContent) {
      records.add(record);
    }
    record = <String>[];
    anyFieldWritten = false;
  }

  for (int i = 0; i < text.length; i++) {
    final String ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      if (field.isNotEmpty || fieldQuoted) {
        // Кавычки в середине незакавыченного значения (`ab"c`) —
        // невалидный CSV, тихо проглотить нельзя. Состояние прошлых
        // полей записи (anyFieldWritten) сюда не подмешивается:
        // `"a";"b"` — две закавыченные колонки валидной строки.
        throw CsvImportException(
          'кавычки внутри незакавыченного поля — некорректный CSV',
          kind: CsvImportFailure.invalidFormat,
          line: records.length + 1,
        );
      }
      inQuotes = true;
      fieldQuoted = true;
    } else if (ch == ';') {
      endField();
    } else if (ch == '\n') {
      endRecord();
    } else if (ch == '\r') {
      if (i + 1 < text.length && text[i + 1] == '\n') {
        i++;
      }
      endRecord();
    } else {
      field.write(ch);
    }
  }
  // Незакрытые кавычки проверяем ДО конца записи: незакрытое поле —
  // битый файл, а не последняя строка данных.
  if (inQuotes) {
    throw CsvImportException(
      'незакрытые кавычки в конце файла',
      kind: CsvImportFailure.invalidFormat,
      line: records.length + 1,
    );
  }
  if (anyFieldWritten || fieldQuoted || field.isNotEmpty) {
    endRecord();
  }
  return records;
}

/// Строка «маппинг-поле → значение» файла после разбора.
typedef CsvRecord = Map<CsvField, String>;

/// Проверяет маппинг и раскладывает строки данных в записи.
///
/// Отказ [CsvImportFailure.invalidMapping]: пустой маппинг, дубль поля
/// (две колонки → одно поле), отсутствие обязательных полей
/// (date, type, account, amount, currency). Число колонок строки обязано
/// покрывать весь маппинг; лишние колонки файла допускаются (не читаются).
///
/// [header] — фактическая шапка файла (может быть пустой у безголовых
/// файлов): индексы маппинга обязаны существовать в строках, шапка на
/// форму маппинга не влияет.
List<CsvRecord> csvRecordsFromRows(
  List<List<String>> rows,
  CsvColumnMapping mapping,
) {
  if (mapping.isEmpty) {
    throw CsvImportException(
      'маппинг колонок пуст',
      kind: CsvImportFailure.invalidMapping,
      line: 0,
    );
  }
  final Set<int> indexes = mapping.keys.toSet();
  if (indexes.length != mapping.length) {
    throw CsvImportException(
      'маппинг содержит дубликат индекса колонки',
      kind: CsvImportFailure.invalidMapping,
      line: 0,
    );
  }
  final Set<CsvField> fields = mapping.values.toSet();
  if (fields.length != mapping.values.length) {
    throw CsvImportException(
      'две колонки маппятся в одно поле',
      kind: CsvImportFailure.invalidMapping,
      line: 0,
    );
  }
  const Set<CsvField> required = <CsvField>{
    CsvField.date,
    CsvField.type,
    CsvField.account,
    CsvField.amount,
    CsvField.currency,
  };
  final Set<CsvField> missing = required.difference(fields);
  if (missing.isNotEmpty) {
    throw CsvImportException(
      'в маппинге нет обязательных полей: '
      '${missing.map((CsvField f) => f.name).join(', ')}',
      kind: CsvImportFailure.invalidMapping,
      line: 0,
    );
  }
  final int maxIndex = indexes.reduce((int a, int b) => a > b ? a : b);

  final List<CsvRecord> records = <CsvRecord>[];
  // rows[0] — шапка файла (формат экспорта всегда с шапкой), данные идут
  // с физической строки 2. Немаппленные поля остаются пустыми строками.
  for (int rowNumber = 1; rowNumber < rows.length; rowNumber++) {
    final List<String> row = rows[rowNumber];
    final int line = rowNumber + 1;
    if (row.length <= maxIndex) {
      throw CsvImportException(
        'в строке ${row.length} колонок, маппинг требует ${maxIndex + 1} '
        '(число колонок обязано совпадать во всех строках данных)',
        kind: CsvImportFailure.invalidData,
        line: line,
      );
    }
    final CsvRecord record = <CsvField, String>{
      for (final CsvField field in CsvField.values) field: '',
    };
    for (final MapEntry<int, CsvField> entry in mapping.entries) {
      record[entry.value] = row[entry.key];
    }
    records.add(record);
  }
  return records;
}

/// Разобранные и провалидированные операции файла: готовы к записи.
class CsvImportData {
  const CsvImportData({required this.operations});

  /// Операции в порядке строк файла.
  final List<CsvParsedOperation> operations;

  /// Число загружаемых операций.
  int get count => operations.length;
}

/// Одна провалидированная операция CSV-файла.
class CsvParsedOperation {
  const CsvParsedOperation({
    required this.type,
    required this.accountName,
    required this.amountMinor,
    required this.currencyCode,
    required this.date,
    this.targetAccountName,
    this.targetAmountMinor,
    this.categoryName,
    this.note,
  });

  final TransactionType type;
  final String accountName;
  final int amountMinor;
  final String currencyCode;
  final DateTime date;

  /// Имя счёта зачисления; у не-перевода — null.
  final String? targetAccountName;

  /// Сумма зачисления (D-17); у одно-валютного перевода и не-перевода — null.
  final int? targetAmountMinor;

  /// Имя категории; null = без категории.
  final String? categoryName;
  final String? note;
}

/// Парсит строку суммы мажорным числом экспорта (A14): точка-разделитель,
/// по экспоненту валюты (D-15); у базовой — как сложилось (D-29): экспонент
/// из справочника ISO, для кода вне справочника — дефолт 2.
///
/// Отрицательная или нечисловая сумма — отказ: в БД суммы без знака (§3),
/// знак задаёт тип операции.
int parseCsvAmount(String raw, String currencyCode, int line) {
  final String normalized = raw.trim().replaceAll(',', '.');
  final int exponent = currencyExponentByCode(currencyCode);
  final int? minor = parseAmountToMinor(normalized, exponent: exponent);
  if (minor == null) {
    throw CsvImportException(
      'сумма «$raw» не является положительным числом с не более чем '
      '$exponent знаками после разделителя (экспонент $currencyCode, D-15)',
      kind: CsvImportFailure.invalidData,
      line: line,
    );
  }
  return minor;
}

/// Разбирает дату ISO-8601; даты хранятся в UTC (§3), формат — как в
/// экспорте (`DateTime.toUtc().toIso8601String()`). Дата без зоны трактуется
/// как UTC (наивная строка файла — момент по UTC, не по локали машины).
DateTime parseCsvDate(String raw, int line) {
  final String normalized = raw.trim();
  final DateTime? parsed = DateTime.tryParse(normalized);
  if (parsed == null) {
    throw CsvImportException(
      'дата «$raw» не является датой ISO-8601',
      kind: CsvImportFailure.invalidData,
      line: line,
    );
  }
  return parsed.toUtc();
}

/// Строгое декодирование типа операции (enums.dart): неизвестное значение —
/// отказ с номером строки (D-25: не тихая нормализация).
TransactionType parseCsvType(String raw, int line) {
  final String normalized = raw.trim().toLowerCase();
  try {
    return TransactionType.fromDb(normalized);
  } on DataValidationException {
    throw CsvImportException(
      'неизвестный тип операции «$raw» (ожидались income/expense/transfer)',
      kind: CsvImportFailure.invalidData,
      line: line,
    );
  }
}

/// Точная ссылка по имени: имя → запись живого справочника.
/// Регистр значим («продукты» ≠ «Продукты»): имена — данные пользователя,
/// неспешная ручная сверка; нечувствительность внесла бы ложное
/// «слияние» разных счетов при коллизии в нижнем регистре. Решение
/// зафиксировано в отчёте M4-шага 2.
K? exactByName<K>(String name, Map<String, K> byName) => byName[name];

/// Карта «имя → запись» живых записей справочника с отказом при дублях
/// имён: имя — ключ сопоставления CSV (ссылки по имени), а DAO дубли имён
/// не запрещает. Дубль сделал бы выбор записи неопределённым («молча
/// взять последнюю» — ложь данных, D-25): отказ импорта, приведение имён
/// — забота пользователя.
Map<String, K> aliveByName<K>(
  List<K> rows,
  String Function(K) nameOf,
) {
  final Map<String, K> byName = <String, K>{};
  for (final K row in rows) {
    final String name = nameOf(row);
    if (byName.containsKey(name)) {
      throw CsvImportException(
        'в базе несколько живых записей с именем «$name»: импорт по имени '
        'неоднозначен — приведите имена счетов/категорий в порядок',
        kind: CsvImportFailure.invalidData,
        line: 0,
      );
    }
    byName[name] = row;
  }
  return byName;
}

/// Разбирает и строго валидирует CSV-файл целиком (D-25: отказ всего
/// импорта при любом нарушении, без частичной загрузки).
///
/// Правила (бриф M4-шага 2, D-17/D-21/D-25/D-33):
/// - неизвестный тип, нечисловая/неположительная сумма, битая дата — отказ;
/// - счёт списания, валюта, категория по имени — обязаны существовать
///   в живых справочниках базы (регистр значим); категория ищется среди
///   категорий вида операции (доход у income, расход у expense): имена
///   видов независимы («Подарки» в обоих видах — разные категории),
///   дубль имени внутри вида — отказ;
/// - перевод: счёт зачисления обязателен, категории быть не должно;
///   валюта колонки — валюта счёта списания;
/// - не-перевод: ячейка счёта зачисления пустая (заполненная — отказ);
/// - разные валюты счетов перевода ⇔ обе суммы обязательны (обе колонки
///   заполнены); одна валюта ⇔ ячейка суммы зачисления пустая (D-17);
///   само-перевод допустим как шум (D-33);
/// - пустые строки файла пропускаются парсером, имена/заметка — через
///   `optionalText`.
CsvImportData parseCsvImport({
  required String csv,
  required CsvColumnMapping mapping,
  required Map<String, Account> accountsByName,
  required Map<String, Category> expenseCategoriesByName,
  required Map<String, Category> incomeCategoriesByName,
}) {
  final List<List<String>> rows = parseCsv(csv);
  if (rows.isEmpty) {
    throw CsvImportException(
      'файл пуст',
      kind: CsvImportFailure.invalidFormat,
      line: 0,
    );
  }
  final List<CsvRecord> records = csvRecordsFromRows(rows, mapping);
  final List<CsvParsedOperation> operations = <CsvParsedOperation>[];
  for (int i = 0; i < records.length; i++) {
    final CsvRecord record = records[i];
    // Логическая строка файла: шапка = строка 1, данные со строки 2.
    final int line = i + 2;
    String field(CsvField field) => record[field]!.trim();

    final TransactionType type = parseCsvType(field(CsvField.type), line);
    final String accountName = field(CsvField.account);
    if (accountName.isEmpty) {
      throw CsvImportException(
        'пустое имя счёта',
        kind: CsvImportFailure.invalidData,
        line: line,
      );
    }
    final Account? account = exactByName(accountName, accountsByName);
    if (account == null) {
      throw CsvImportException(
        'счёт «$accountName» не найден среди живых счетов базы',
        kind: CsvImportFailure.invalidData,
        line: line,
      );
    }
    final String currencyCode = field(CsvField.currency).toUpperCase();
    if (currencyCode.isEmpty) {
      throw CsvImportException(
        'пустой код валюты',
        kind: CsvImportFailure.invalidData,
        line: line,
      );
    }
    if (currencyCode != account.currencyCode) {
      throw CsvImportException(
        'валюта строки $currencyCode не совпадает с валютой счёта '
        '«$accountName» (${account.currencyCode}): операция хранит валюту '
        'счёта (§3)',
        kind: CsvImportFailure.invalidData,
        line: line,
      );
    }
    final int amountMinor = parseCsvAmount(
      field(CsvField.amount),
      currencyCode,
      line,
    );
    final DateTime date = parseCsvDate(field(CsvField.date), line);

    final String targetName = field(CsvField.targetAccount);
    final String targetAmountRaw = field(CsvField.targetAmount);
    final String categoryName = field(CsvField.category);
    final String note = field(CsvField.note);

    final bool hasTarget = targetName.isNotEmpty;
    final bool hasTargetAmount = targetAmountRaw.isNotEmpty;
    switch (type) {
      case TransactionType.income:
      case TransactionType.expense:
        if (hasTarget) {
          throw CsvImportException(
            'счёт зачисления («$targetName») задаётся только у перевода',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        final Map<String, Category> categoriesByName =
            type == TransactionType.income
                ? incomeCategoriesByName
                : expenseCategoriesByName;
        final Category? category = categoryName.isEmpty
            ? null
            : exactByName(categoryName, categoriesByName);
        if (categoryName.isNotEmpty && category == null) {
          throw CsvImportException(
            'категория «$categoryName» не найдена среди живых категорий '
            '${type == TransactionType.income ? 'доходов' : 'расходов'} базы',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        operations.add(
          CsvParsedOperation(
            type: type,
            accountName: accountName,
            amountMinor: amountMinor,
            currencyCode: currencyCode,
            date: date,
            categoryName: category?.name,
            note: optionalText(note),
          ),
        );
      case TransactionType.transfer:
        if (!hasTarget) {
          throw CsvImportException(
            'у перевода нет счёта зачисления',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        if (categoryName.isNotEmpty) {
          throw CsvImportException(
            'у перевода не бывает категории (§3): в файле «$categoryName»',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        final Account? target = exactByName(targetName, accountsByName);
        if (target == null) {
          throw CsvImportException(
            'счёт зачисления «$targetName» не найден среди живых счетов базы',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        if (!hasTargetAmount && target.currencyCode != account.currencyCode) {
          throw CsvImportException(
            'перевод между разными валютами (${account.currencyCode} → '
            '${target.currencyCode}) требует обеих сумм: списания и '
            'зачисления (D-17). CSV-экспорт v0.3 сумму зачисления не '
            'пишет — мультивалютные переводы переносятся JSON-бэкапом '
            'или файлом с колонкой суммы зачисления',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        if (hasTargetAmount && target.currencyCode == account.currencyCode) {
          throw CsvImportException(
            'перевод в одной валюте (${account.currencyCode}) хранит только '
            'сумму списания: ячейка суммы зачисления обязана быть пустой '
            '(D-17)',
            kind: CsvImportFailure.invalidData,
            line: line,
          );
        }
        final int? targetAmountMinor = hasTargetAmount
            ? parseCsvAmount(targetAmountRaw, target.currencyCode, line)
            : null;
        operations.add(
          CsvParsedOperation(
            type: TransactionType.transfer,
            accountName: accountName,
            amountMinor: amountMinor,
            currencyCode: currencyCode,
            date: date,
            targetAccountName: targetName,
            targetAmountMinor: targetAmountMinor,
            note: optionalText(note),
          ),
        );
    }
  }
  return CsvImportData(operations: operations);
}

/// Итог загрузки: сколько операций добавлено.
class CsvImportResult {
  const CsvImportResult({required this.imported});

  /// Добавлено операций.
  final int imported;
}

/// Загружает провалидированный файл к ЖИВОЙ базе (merge, не полная замена):
/// операции добавляются с новыми id, справочники (валюты, счета, категории)
/// не создаются и не меняются. Одна транзакция drift: падение посреди
/// загрузки оставляет базу нетронутой — частичной загрузки нет.
///
/// Валидация [parseCsvImport] выполняется ДО транзакции (D-25); повторная
/// проверка ссылок внутри транзакции — по образцу DAO (`_requireAlive*`):
/// между парсингом и загрузкой база могла измениться.
///
/// [idGenerator]/[clock] — точки подмены в тестах (как в DAO).
Future<CsvImportResult> importTransactionsCsv(
  AppDatabase db,
  CsvImportData data, {
  IdGenerator idGenerator = newId,
  Clock clock = utcNow,
}) async {
  final Map<String, Account> accountsByName =
      aliveByName(await db.accountsDao.getAlive(), (Account a) => a.name);
  final List<Category> categories = await db.categoriesDao.getAlive();
  final Map<String, Category> expenseCategoriesByName = aliveByName(
    categories
        .where(
          (Category c) =>
              CategoryKind.fromDb(c.kind) == CategoryKind.expense,
        )
        .toList(growable: false),
    (Category c) => c.name,
  );
  final Map<String, Category> incomeCategoriesByName = aliveByName(
    categories
        .where(
          (Category c) =>
              CategoryKind.fromDb(c.kind) == CategoryKind.income,
        )
        .toList(growable: false),
    (Category c) => c.name,
  );

  await db.transaction(() async {
    for (final CsvParsedOperation operation in data.operations) {
      final DateTime now = clock();
      final Account? account = exactByName(
        operation.accountName,
        accountsByName,
      );
      if (account == null) {
        throw CsvImportException(
          'счёт «${operation.accountName}» исчез из базы до записи операции',
          kind: CsvImportFailure.invalidData,
          line: 0,
        );
      }
      String? categoryId;
      if (operation.categoryName != null) {
        final Category? category = exactByName(
          operation.categoryName!,
          operation.type == TransactionType.income
              ? incomeCategoriesByName
              : expenseCategoriesByName,
        );
        if (category == null) {
          throw CsvImportException(
            'категория «${operation.categoryName}» исчезла из базы до записи '
            'операции',
            kind: CsvImportFailure.invalidData,
            line: 0,
          );
        }
        categoryId = category.id;
      }
      String? targetAccountId;
      if (operation.targetAccountName != null) {
        final Account? target = exactByName(
          operation.targetAccountName!,
          accountsByName,
        );
        if (target == null) {
          throw CsvImportException(
            'счёт зачисления «${operation.targetAccountName}» исчез из базы '
            'до записи операции',
            kind: CsvImportFailure.invalidData,
            line: 0,
          );
        }
        targetAccountId = target.id;
      }
      // Суммы/форма перевода проверены парсером; правила DAO (§3, D-17)
      // соблюдаются конструкцией: сумма > 0, валюта = валюта счёта,
      // у перевода с разными валютами обе суммы заданы.
      await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              id: idGenerator(),
              type: operation.type.dbValue,
              accountId: account.id,
              targetAccountId: Value(targetAccountId),
              categoryId: Value(categoryId),
              amountMinor: operation.amountMinor,
              targetAmountMinor: Value(operation.targetAmountMinor),
              currencyCode: account.currencyCode,
              date: operation.date,
              note: Value(operation.note),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  });
  return CsvImportResult(imported: data.operations.length);
}

/// Сквозной импорт: разбор + валидация + загрузка (точка входа для
/// будущего UI). Падение на любом этапе оставляет базу нетронутой.
/// Дубли имён живых счетов/категорий — отказ: ссылка по имени
/// неоднозначна (DAO дубли имён не запрещает).
Future<CsvImportResult> importCsvFile(
  AppDatabase db, {
  required String csv,
  CsvColumnMapping? mapping,
}) async {
  final CsvColumnMapping effectiveMapping =
      mapping ?? csvMappingFromExportV03();
  final Map<String, Account> accountsByName =
      aliveByName(await db.accountsDao.getAlive(), (Account a) => a.name);
  final List<Category> categories = await db.categoriesDao.getAlive();
  final Map<String, Category> expenseCategoriesByName = aliveByName(
    categories
        .where(
          (Category c) =>
              CategoryKind.fromDb(c.kind) == CategoryKind.expense,
        )
        .toList(growable: false),
    (Category c) => c.name,
  );
  final Map<String, Category> incomeCategoriesByName = aliveByName(
    categories
        .where(
          (Category c) =>
              CategoryKind.fromDb(c.kind) == CategoryKind.income,
        )
        .toList(growable: false),
    (Category c) => c.name,
  );
  final CsvImportData data = parseCsvImport(
    csv: csv,
    mapping: effectiveMapping,
    accountsByName: accountsByName,
    expenseCategoriesByName: expenseCategoriesByName,
    incomeCategoriesByName: incomeCategoriesByName,
  );
  return importTransactionsCsv(db, data);
}
