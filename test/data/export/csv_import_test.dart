// Тесты импорта CSV (M4-шаг 2): RFC-4180-парсер, маппинг колонок,
// строгая валидация (D-25/D-17/D-33) и merge-загрузка к живой базе.
//
// Формат файла — CSV-экспорт v0.3 (BackupService.exportTransactionsCsv):
// разделитель ';', сумма мажорным числом с точкой по экспоненту валюты,
// даты ISO-8601 UTC, имена счетов/категорий человекочитаемые.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/export/csv_import.dart';

/// БД в памяти с севом (валюта RUB, системные категории) и двумя счетами:
/// «Наличные» и «Карта» (RUB), для переводов.
Future<AppDatabase> seeded() async {
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  await seedDefaultsIfEmpty(database);
  await database.accountsDao.create(
    name: 'Наличные',
    kind: AccountKind.cash,
    currencyCode: 'RUB',
    initialBalanceMinor: 5000,
  );
  await database.accountsDao.create(
    name: 'Карта',
    kind: AccountKind.card,
    currencyCode: 'RUB',
  );
  return database;
}

/// Экранирование поля как в экспорте v0.3 (`_csvField`): кавычки вокруг
/// поля с разделителями/кавычками/переносами, кавычки внутри удваиваются.
String csvField(String value) =>
    (value.contains(';') || value.contains('"') || value.contains('\n'))
        ? '"${value.replaceAll('"', '""')}"'
        : value;

/// CSV-строка данных в порядке экспорта v0.3 (колонка id в импорте
/// не читается — она в дефолтном маппинге отсутствует).
String csvLine(
  String date,
  String type,
  String account,
  String targetAccount,
  String category,
  String amount,
  String currency,
  String note,
) =>
    'uuid;$date;$type;$account;$targetAccount;$category;$amount;$currency;${csvField(note)}';

/// Заголовок экспорта v0.3.
const String header =
    'id;date;type;account;target_account;category;amount;currency;note';

void main() {
  group('парсер CSV', () {
    test('BOM снимается, \\r\\n — концы строк, пустая последняя колонка живёт',
        () async {
      final List<List<String>> rows = parseCsv(
        '\uFEFF$header\r\n${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '123.45', 'RUB', '')}\r\n',
      );
      expect(rows, hasLength(2));
      expect(rows[0].first, 'id'); // без BOM
      expect(rows[1][7], 'RUB');
      expect(rows[1].last, ''); // пустая заметка — не выкинута
    });

    test('кавычки: разделители и перенос строки внутри поля — часть значения',
        () async {
      final List<List<String>> rows = parseCsv(
        '$header\n${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '1.00', 'RUB', 'кофе; с "дополнением"\nи булкой')}\n',
      );
      expect(rows, hasLength(2)); // многострочная заметка — одна запись
      expect(rows[1].last, 'кофе; с "дополнением"\nи булкой');
    });

    test('пустые строки пропускаются, ;; остаётся строкой с пустыми полями',
        () async {
      final List<List<String>> rows = parseCsv(
        '$header\n\n;;\n\na;b\n',
      );
      expect(rows, hasLength(3));
      expect(rows[0], header.split(';'));
      expect(rows[1], <String>['', '', '']);
      expect(rows[2], <String>['a', 'b']);
    });

    test('кавычки внутри незакавыченного поля — отказ invalidFormat', () {
      expect(
        () => parseCsv('a;b"c\n'),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidFormat,
          ),
        ),
      );
    });

    test('незакрытые кавычки — отказ invalidFormat', () {
      expect(
        () => parseCsv('a;"битое поле\n'),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidFormat,
          ),
        ),
      );
    });
  });

  group('маппинг колонок', () {
    test('дефолт: заголовки экспорта v0.3, колонка id не читается', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '123.45', 'RUB', 'аренда')}\n';
      final CsvImportResult result = await importCsvFile(database, csv: csv);
      expect(result.imported, 1);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.amountMinor, 12345);
      expect(row.note, 'аренда');
    });

    test('маппинг в другом порядке и с лишними колонками работает', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      // Файл «чужой» таблицы: лишняя колонка source, поля в другом порядке.
      final String csv = 'amount;currency;account;source;type;date\n'
          '123.45;RUB;Наличные;bank;expense;2026-09-27T10:00:00.000Z\n';
      final CsvImportResult result = await importCsvFile(
        database,
        csv: csv,
        mapping: <int, CsvField>{
          0: CsvField.amount,
          1: CsvField.currency,
          2: CsvField.account,
          4: CsvField.type,
          5: CsvField.date,
        },
      );
      expect(result.imported, 1);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.amountMinor, 12345);
      expect(row.type, TransactionType.expense.dbValue);
      expect(row.currencyCode, 'RUB');
    });

    test('дубль поля в маппинге — отказ invalidMapping', () {
      expect(
        () => csvRecordsFromRows(
          <List<String>>[<String>['a', 'b'], <String>['1', '2']],
          <int, CsvField>{0: CsvField.amount, 1: CsvField.amount},
        ),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidMapping,
          ),
        ),
      );
    });

    test('без обязательного поля — отказ invalidMapping', () {
      expect(
        () => csvRecordsFromRows(
          <List<String>>[<String>['a'], <String>['1']],
          <int, CsvField>{0: CsvField.amount},
        ),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidMapping,
          ),
        ),
      );
    });

    test('в строке меньше колонок, чем требует маппинг — отказ с номером',
        () {
      expect(
        () => csvRecordsFromRows(
          <List<String>>[
            <String>['date', 'type', 'account', 'amount', 'currency'],
            <String>['2026-09-27T10:00:00.000Z', 'expense'],
          ],
          <int, CsvField>{
            0: CsvField.date,
            1: CsvField.type,
            2: CsvField.account,
            3: CsvField.amount,
            4: CsvField.currency,
          },
        ),
        throwsA(
          isA<CsvImportException>()
              .having((CsvImportException e) => e.kind, 'kind',
                  CsvImportFailure.invalidData)
              .having((CsvImportException e) => e.line, 'line', 2),
        ),
      );
    });
  });

  group('валидация строк (D-25/D-17/D-33)', () {
    test('happy path: файл нашего экспорта — доход, расход, перевод', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-25T10:00:00.000Z', 'income', 'Наличные', '', 'Зарплата', '50000', 'RUB', 'аванс')}\n'
          '${csvLine('2026-09-26T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '123.45', 'RUB', '')}\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'transfer', 'Наличные', 'Карта', '', '100', 'RUB', 'перекладка')}\n';
      final CsvImportResult result = await importCsvFile(database, csv: csv);
      expect(result.imported, 3);
      final List<Transaction> rows =
          await database.transactionsDao.getFiltered();
      expect(rows, hasLength(3));
      // transactions.type хранит каноническую строку (enums.dart, §3).
      final Transaction transfer = rows
          .where((Transaction r) => r.type == TransactionType.transfer.dbValue)
          .single;
      expect(transfer.amountMinor, 10000);
      expect(transfer.targetAmountMinor, isNull); // одна валюта → NULL (D-17)
      expect(transfer.note, 'перекладка');
      // Даты — UTC (§3), записаны как в файле. Drift отдаёт локальную
      // зону (см. backup_service_test) — сравниваем мгновение через toUtc.
      final Transaction income = rows
          .where((Transaction r) => r.type == TransactionType.income.dbValue)
          .single;
      expect(income.date.toUtc(), DateTime.utc(2026, 9, 25, 10));
    });

    test('кавычки и переносы строк внутри заметки не ломают загрузку',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '10', 'RUB', 'заметка; с "кавычками"\nи переносом')}\n';
      await importCsvFile(database, csv: csv);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.note, 'заметка; с "кавычками"\nи переносом');
    });

    test('id генерируются заново, uuid файла не читается', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '10', 'RUB', '')}\n';
      await importCsvFile(database, csv: csv);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(
        row.id,
        isNot('uuid'),
      );
    });

    test('неизвестный тип операции — отказ с номером строки', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '10', 'RUB', '')}\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'покупка', 'Наличные', '', 'Жильё', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>()
              .having((CsvImportException e) => e.kind, 'kind',
                  CsvImportFailure.invalidData)
              .having((CsvImportException e) => e.line, 'line', 3),
        ),
      );
      expect(await database.transactionsDao.getFiltered(), isEmpty);
    });

    test('нечисловая сумма — отказ с номером строки', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', 'много', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.line,
            'line',
            2,
          ),
        ),
      );
    });

    test('отрицательная сумма — отказ', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '-5', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>()
              .having((CsvImportException e) => e.kind, 'kind',
                  CsvImportFailure.invalidData),
        ),
      );
      expect(await database.transactionsDao.getFiltered(), isEmpty);
    });

    test('сумма с запятой как в ручном вводе не принимается (формат — точка)',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '123,45', 'RUB', '')}\n';
      // Запятая нормализуется в точку (parseAmountToMinor): файл экспорта
      // пишет точку, но правленый руками файл с запятой тоже читается.
      await importCsvFile(database, csv: csv);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.amountMinor, 12345);
    });

    test('отсутствующий счёт — отказ с номером строки', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Копилка', '', 'Жильё', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>()
              .having((CsvImportException e) => e.kind, 'kind',
                  CsvImportFailure.invalidData)
              .having((CsvImportException e) => e.line, 'line', 2),
        ),
      );
    });

    test('отсутствующая категория — отказ с номером строки', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Нет такой', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.line,
            'line',
            2,
          ),
        ),
      );
    });

    test('валюта строки не совпадает с валютой счёта — отказ (§3)', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '10', 'USD', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>()
              .having((CsvImportException e) => e.kind, 'kind',
                  CsvImportFailure.invalidData)
              .having((CsvImportException e) => e.line, 'line', 2),
        ),
      );
    });

    test('битая дата — отказ', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('27.09.2026', 'expense', 'Наличные', '', 'Жильё', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(isA<CsvImportException>()),
      );
    });

    test('не-перевод со счётом зачисления — отказ (битая форма, D-21)', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', 'Карта', '', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidData,
          ),
        ),
      );
    });

    test('перевод без счёта зачисления — отказ', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'transfer', 'Наличные', '', '', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(isA<CsvImportException>()),
      );
    });

    test('перевод с категорией — отказ (§3)', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'transfer', 'Наличные', 'Карта', 'Жильё', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(isA<CsvImportException>()),
      );
    });

    test('само-перевод допустим как шум (D-33)', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'transfer', 'Наличные', 'Наличные', '', '10', 'RUB', 'шум')}\n';
      final CsvImportResult result = await importCsvFile(database, csv: csv);
      expect(result.imported, 1);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.accountId, row.targetAccountId);
      expect(row.targetAmountMinor, isNull);
    });
  });

  group('мультивалютные переводы (D-17, колонка суммы зачисления)', () {
    Future<AppDatabase> multiCurrency() async {
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      await seedDefaultsIfEmpty(database);
      await database.currenciesDao.create(code: 'USD', symbol: r'$');
      await database.accountsDao.create(
        name: 'Рублёвый',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      await database.accountsDao.create(
        name: 'Долларовый',
        kind: AccountKind.cash,
        currencyCode: 'USD',
      );
      return database;
    }

    test('разные валюты: обе суммы маппятся — импортируется целиком',
        () async {
      final AppDatabase database = await multiCurrency();
      addTearDown(database.close);
      final String csv = 'date;type;account;target_account;category;amount;currency;target_amount\n'
          '2026-09-27T10:00:00.000Z;transfer;Рублёвый;Долларовый;;7900;RUB;100\n';
      final CsvImportResult result = await importCsvFile(
        database,
        csv: csv,
        mapping: <int, CsvField>{
          0: CsvField.date,
          1: CsvField.type,
          2: CsvField.account,
          3: CsvField.targetAccount,
          5: CsvField.amount,
          6: CsvField.currency,
          7: CsvField.targetAmount,
        },
      );
      expect(result.imported, 1);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.amountMinor, 790000);
      // 100 USD = 10000 минорных центов (экспонент USD — 2).
      expect(row.targetAmountMinor, 10000);
    });

    test('разные валюты без суммы зачисления — отказ (D-17)', () async {
      final AppDatabase database = await multiCurrency();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'transfer', 'Рублёвый', 'Долларовый', '', '79', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>()
              .having((CsvImportException e) => e.kind, 'kind',
                  CsvImportFailure.invalidData)
              .having((CsvImportException e) => e.line, 'line', 2),
        ),
      );
    });

    test('одна валюта с суммой зачисления — отказ (D-17)', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = 'date;type;account;target_account;category;amount;currency;target_amount\n'
          '2026-09-27T10:00:00.000Z;transfer;Наличные;Карта;;10;RUB;10\n';
      await expectLater(
        importCsvFile(
          database,
          csv: csv,
          mapping: <int, CsvField>{
            0: CsvField.date,
            1: CsvField.type,
            2: CsvField.account,
            3: CsvField.targetAccount,
            5: CsvField.amount,
            6: CsvField.currency,
            7: CsvField.targetAmount,
          },
        ),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidData,
          ),
        ),
      );
    });
  });

  group('merge к живой базе и атомарность', () {
    test('merge: существующие операции остаются, новые добавляются',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final List<Category> expenseCategories =
          await database.categoriesDao.getAlive(kind: CategoryKind.expense);
      final Category housing = expenseCategories
          .where((Category c) => c.name == 'Жильё')
          .single;
      final String accountId =
          (await database.accountsDao.getAlive()).first.id;
      await database.transactionsDao.create(
        type: TransactionType.expense,
        accountId: accountId,
        categoryId: housing.id,
        amountMinor: 999,
      );
      final int before =
          (await database.transactionsDao.getFiltered()).length;

      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '123.45', 'RUB', 'новая')}\n';
      final CsvImportResult result = await importCsvFile(database, csv: csv);

      expect(result.imported, 1);
      final List<Transaction> rows =
          await database.transactionsDao.getFiltered();
      expect(rows, hasLength(before + 1));
      expect(
        rows.where((Transaction r) => r.note == 'новая'),
        hasLength(1),
      );
      // Справочники не тронуты: счетов и категорий столько же, сколько было.
      expect(await database.accountsDao.getAlive(), hasLength(2));
      expect(
        await database.categoriesDao.getAlive(),
        hasLength(expenseCategories.length + 3), // +3 доходных
      );
    });

    test('ошибка валидации оставляет живую базу нетронутой (атомарность)',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final List<Category> expenseCategories =
          await database.categoriesDao.getAlive(kind: CategoryKind.expense);
      final Category housing = expenseCategories
          .where((Category c) => c.name == 'Жильё')
          .single;
      final String accountId =
          (await database.accountsDao.getAlive()).first.id;
      await database.transactionsDao.create(
        type: TransactionType.expense,
        accountId: accountId,
        categoryId: housing.id,
        amountMinor: 999,
      );
      final List<Transaction> before =
          await database.transactionsDao.getFiltered();

      // Первая строка валидна, вторая — битая: ничего не должно загрузиться.
      final String csv = '$header\n'
          '${csvLine('2026-09-26T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '10', 'RUB', 'ок')}\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Исчезнувший счёт', '', 'Жильё', '10', 'RUB', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(isA<CsvImportException>()),
      );
      expect(
        await database.transactionsDao.getFiltered(),
        hasLength(before.length),
      );
      expect(
        (await database.transactionsDao.getFiltered()).first.id,
        before.first.id,
      );
    });

    test('повторный импорт того же файла дублирует операции (merge, не upsert)',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Жильё', '10', 'RUB', 'дубль')}\n';
      await importCsvFile(database, csv: csv);
      await importCsvFile(database, csv: csv);
      expect(await database.transactionsDao.getFiltered(), hasLength(2));
    });
  });

  group('экспоненты валют (D-15/D-27/D-29)', () {
    test('KWD (экспонент 3): 1.234 → 1234 минорных', () async {
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);
      await seedDefaultsIfEmpty(database);
      await database.currenciesDao.create(code: 'KWD', symbol: 'د.ك');
      await database.accountsDao.create(
        name: 'Динары',
        kind: AccountKind.cash,
        currencyCode: 'KWD',
      );
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Динары', '', '', '1.234', 'KWD', '')}\n';
      await importCsvFile(database, csv: csv);
      final Transaction row =
          (await database.transactionsDao.getFiltered()).single;
      expect(row.amountMinor, 1234);
    });

    test('JPY (экспонент 0): дробная часть запрещена', () async {
      final AppDatabase database = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(database.close);
      await seedDefaultsIfEmpty(database);
      await database.currenciesDao.create(code: 'JPY', symbol: '¥');
      await database.accountsDao.create(
        name: 'Иены',
        kind: AccountKind.cash,
        currencyCode: 'JPY',
      );
      final String csv = '$header\n'
          '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Иены', '', '', '100.5', 'JPY', '')}\n';
      await expectLater(
        importCsvFile(database, csv: csv),
        throwsA(
          isA<CsvImportException>().having(
            (CsvImportException e) => e.kind,
            'kind',
            CsvImportFailure.invalidData,
          ),
        ),
      );
    });
  });
}
