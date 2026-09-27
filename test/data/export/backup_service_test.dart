// Тесты сервиса бэкапов (§4): атомарная замена при импорте, CSV-экспорт
// живых операций, автобэкап с ротацией последних 10 файлов. Часы сервиса
// подменяются (H3): имена автобэкапов и даты CSV детерминированы.
//
// drift импортируется с hide isNotNull/isNull; даты сравниваются через
// toUtc (drift отдаёт локальную зону).
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/export/backup_codec.dart';
import 'package:kopilka/data/export/backup_service.dart';

/// Мини-парсер CSV (RFC-4180) для проверок (P5): ';' — разделитель, '"' —
/// кавычки с удвоением внутри, перенос строки внутри кавычек остаётся частью
/// значения поля. Нужен вместо тупого split: экспорт обязан закрывать
/// многострочные заметки в кавычки, и это проверяется разбором, а не строками.
List<List<String>> parseCsv(String input) {
  final List<List<String>> records = <List<String>>[];
  List<String> record = <String>[];
  final StringBuffer field = StringBuffer();
  bool inQuotes = false;
  for (int i = 0; i < input.length; i++) {
    final String ch = input[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ';') {
      record.add(field.toString());
      field.clear();
    } else if (ch == '\n') {
      record.add(field.toString());
      field.clear();
      records.add(record);
      record = <String>[];
    } else {
      field.write(ch);
    }
  }
  if (field.isNotEmpty || record.isNotEmpty) {
    record.add(field.toString());
    records.add(record);
  }
  return records;
}

/// БД в памяти с севом: валюта, счёт, категория, операция.
Future<AppDatabase> seeded() async {
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  await seedDefaultsIfEmpty(database);
  await database.accountsDao.create(
    name: 'Наличные',
    kind: AccountKind.cash,
    currencyCode: 'RUB',
    initialBalanceMinor: 5000,
  );
  return database;
}

void main() {
  test('импорт восстанавливает полный дамп, включая мягко удалённые строки',
      () async {
    final AppDatabase source = await seeded();
    addTearDown(source.close);
    // Пользовательская (не системная) категория — DAO разрешает её удалять.
    final Category custom = await source.categoriesDao.create(
      name: 'Моё удалённое',
      kind: CategoryKind.expense,
    );
    await source.categoriesDao.softDelete(custom.id);
    final String json = await BackupService(source).exportJson();

    final AppDatabase target = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(target.close);
    // Импорт в непустую базу: содержимое обязано полностью замениться.
    await seedDefaultsIfEmpty(target);

    await BackupService(target).importJson(json);

    expect(await target.accountsDao.getAlive(), hasLength(1));
    expect(await target.transactionsDao.getFiltered(), hasLength(0));
    final List<Category> categories = await target.categoriesDao.getAlive();
    // 9 расходных системных + 3 доходных системных; пользовательская
    // категория мягко удалена в дампе и в живой список не попадает.
    expect(categories, hasLength(12));
    // Мягко удалённая строка сохранена физически (soft delete, §3).
    final List<QueryRow> deleted =
        await target.customSelect('SELECT COUNT(*) AS c FROM categories '
                'WHERE deleted_at IS NOT NULL')
            .get();
    expect(deleted.single.read<int>('c'), 1);
  });

  test('импорт битого файла не трогает базу (атомарность)', () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    final int accountsBefore =
        (await database.accountsDao.getAlive()).length;

    final String broken = jsonEncode(<String, dynamic>{
      'schema_version': 1,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[
          <String, dynamic>{
            'id': 'acc-x',
            'name': 'Счёт без валюты',
            'kind': 'cash',
            'currency_code': 'USD',
            'created_at': '2026-09-25T00:00:00.000Z',
            'updated_at': '2026-09-25T00:00:00.000Z',
          },
        ],
        'categories': <dynamic>[],
        'transactions': <dynamic>[],
      },
    });

    expect(
      () => BackupService(database).importJson(broken),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException error) => error.kind,
          'kind',
          BackupFailure.invalidData,
        ),
      ),
    );
    // База не тронута: счёт на месте, таблицы не сносились.
    expect((await database.accountsDao.getAlive()).length, accountsBefore);
    expect(await database.currenciesDao.getAlive(), isNotEmpty);
  });

  test('импорт не-JSON файла — отказ invalidFormat', () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    expect(
      () => BackupService(database).importJson('не json'),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException error) => error.kind,
          'kind',
          BackupFailure.invalidFormat,
        ),
      ),
    );
  });

  test('CSV-экспорт: живые операции, категории и имена счетов, сумма точками',
      () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    // Часы сервиса подменены (H3): даты CSV-строк детерминированы.
    final DateTime fixed = DateTime.utc(2026, 9, 26, 12);
    final List<Category> expense =
        await database.categoriesDao.getAlive(kind: CategoryKind.expense);
    // В справочнике посева первым расходом идёт «Жильё» (сортировка DAO:
    // вид, затем имя) — берём его по имени, чтобы тест не зависел от порядка.
    final Category category = expense
        .where((Category category) => category.name == 'Жильё')
        .single;
    final String accountId = (await database.accountsDao.getAlive()).single.id;
    await database.transactionsDao.create(
      type: TransactionType.expense,
      accountId: accountId,
      categoryId: category.id,
      amountMinor: 12345,
      // P5: заметка с разделителями И переносом строки внутри кавычек.
      note: 'кофе; с "дополнением"\nи булкой',
    );
    // Вторая строка — перевод без категории.
    await database.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: 'RUB',
    );
    final String targetId =
        (await database.accountsDao.getAlive()).last.id;
    await database.transactionsDao.create(
      type: TransactionType.transfer,
      accountId: accountId,
      targetAccountId: targetId,
      amountMinor: 100,
    );

    final String csv = await BackupService(database, clock: () => fixed)
        .exportTransactionsCsv();

    // Список отсортирован по дате сверху: обе операции за один фиксированный
    // момент (часы подменены — H3), поэтому ищем записи по типу.
    // Заметка (P5): разделители и перенос строки закрыты в кавычки (двойные
    // внутри удвоены) — заметка остаётся ОДНИМ логическим полем CSV, поэтому
    // логических записей три (шапка + 2 операции) даже при переносе внутри
    // заметки; тупой split по \n дал бы 4 физических строки.
    final List<List<String>> records = parseCsv(csv);
    expect(records, hasLength(3));
    expect(records.first, <String>[
      'id',
      'date',
      'type',
      'account',
      'target_account',
      'category',
      'amount',
      'currency',
      'note',
    ]);

    final List<String> expenseLine = records
        .where((List<String> record) => record.contains('expense'))
        .single;
    expect(expenseLine[3], 'Наличные');
    expect(expenseLine[5], 'Жильё');
    expect(expenseLine[6], '123.45');
    // Перенос строки внутри кавычек восстановлен как часть значения поля.
    expect(expenseLine.last, 'кофе; с "дополнением"\nи булкой');

    final List<String> transferRecord = records
        .where((List<String> record) => record.contains('transfer'))
        .single;
    expect(transferRecord[4], 'Карта');
    expect(transferRecord[5], isEmpty);
  });

  group('CSV-экспорт по экспоненту валюты счёта (D-15/A14, M3-шаг 2)', () {
    /// БД с счетами в трёх валютах (разные экспоненты ISO: 2/0/3).
    Future<AppDatabase> multiCurrency() async {
      final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
      await seedDefaultsIfEmpty(database);
      // RUB уже засеян; добавляем валюты с экспонентами 0 и 3.
      await database.currenciesDao.create(code: 'JPY', symbol: '¥');
      await database.currenciesDao.create(code: 'KWD', symbol: 'د.ك');
      await database.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: 'RUB',
      );
      await database.accountsDao.create(
        name: 'Иены',
        kind: AccountKind.cash,
        currencyCode: 'JPY',
      );
      await database.accountsDao.create(
        name: 'Динары',
        kind: AccountKind.cash,
        currencyCode: 'KWD',
      );
      return database;
    }

    test('экспонент 0 (JPY): сумма без дробной части', () async {
      final AppDatabase database = await multiCurrency();
      addTearDown(database.close);
      final String accountId = (await database.accountsDao.getAlive())
          .where((Account a) => a.currencyCode == 'JPY')
          .single
          .id;
      await database.transactionsDao.create(
        type: TransactionType.expense,
        accountId: accountId,
        amountMinor: 12345,
      );

      final String csv = await BackupService(database).exportTransactionsCsv();
      final List<List<String>> records = parseCsv(csv);
      final List<String> line = records
          .where((List<String> r) => r.contains('JPY'))
          .single;
      // 12345 минорных йены = 12345 мажорных (экспонент 0 — без разделителя).
      expect(line[6], '12345');
    });

    test('экспонент 3 (KWD): три знака после разделителя', () async {
      final AppDatabase database = await multiCurrency();
      addTearDown(database.close);
      final String accountId = (await database.accountsDao.getAlive())
          .where((Account a) => a.currencyCode == 'KWD')
          .single
          .id;
      await database.transactionsDao.create(
        type: TransactionType.expense,
        accountId: accountId,
        amountMinor: 1234,
      );

      final String csv = await BackupService(database).exportTransactionsCsv();
      final List<List<String>> records = parseCsv(csv);
      final List<String> line = records
          .where((List<String> r) => r.contains('KWD'))
          .single;
      // 1234 минорных динара = 1.234 мажорного (экспонент 3).
      expect(line[6], '1.234');
    });

    test('экспонент 2 (RUB): вывод не изменился (параметризация, не смена формата)', () async {
      final AppDatabase database = await multiCurrency();
      addTearDown(database.close);
      final String accountId = (await database.accountsDao.getAlive())
          .where((Account a) => a.currencyCode == 'RUB')
          .single
          .id;
      await database.transactionsDao.create(
        type: TransactionType.expense,
        accountId: accountId,
        amountMinor: 12345,
      );

      final String csv = await BackupService(database).exportTransactionsCsv();
      final List<List<String>> records = parseCsv(csv);
      final List<String> line = records
          .where((List<String> r) => r.contains('RUB'))
          .single;
      expect(line[6], '123.45');
    });
  });

  test('автобэкап создаёт файл и ротирует до последних 10', () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    final Directory directory =
        await Directory.systemTemp.createTemp('kopilka_backup_test');
    addTearDown(() => directory.delete(recursive: true));

    final BackupService service = BackupService(database);
    for (int i = 0; i < 12; i++) {
      final AutoBackupResult result = await service.runAutoBackup(directory);
      expect(result, isA<AutoBackupCreated>());
    }
    final List<FileSystemEntity> files = await directory.list().toList();
    expect(files, hasLength(10));
    expect(
      files.every(
        (FileSystemEntity file) =>
            file.path.contains('kopilka-backup-') &&
            file.path.endsWith('.json'),
      ),
      isTrue,
    );
  });

  test('P6: имя автобэкапа — точный шаблон kopilka-backup-<ISO>.json', () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    final Directory directory =
        await Directory.systemTemp.createTemp('kopilka_backup_test');
    addTearDown(() => directory.delete(recursive: true));

    // Часы подменены (H3): имя файла строится из фиксированного момента.
    final DateTime fixed = DateTime.utc(2026, 9, 26, 12, 0, 0);
    final AutoBackupResult result =
        await BackupService(database, clock: () => fixed).runAutoBackup(directory);
    expect(result, isA<AutoBackupCreated>());
    final AutoBackupCreated created = result as AutoBackupCreated;

    // Формат заморожен сознательно (решение по P6): ISO-штамп UTC
    // с заменой двоеточий на дефис (хвостовой Z остаётся); по имени файлы
    // рескьюят и сортирует ротация (A16).
    final String name = created.file.uri.pathSegments.last;
    expect(name, 'kopilka-backup-2026-09-26T12-00-00.000Z.json');
    expect(
      (await directory.list().toList()).single.uri.pathSegments.last,
      name,
    );
  });

  test('P6/A16: ротация оставляет самые свежие по штампу из имени, не по mtime', () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    final Directory directory =
        await Directory.systemTemp.createTemp('kopilka_backup_test');
    addTearDown(() => directory.delete(recursive: true));

    // Файлы создаются подряд, mtime у всех почти равен; часы двигаем явно,
    // чтобы штампы в именах различались.
    DateTime now = DateTime.utc(2026, 9, 26, 12, 0, 0);
    final BackupService service = BackupService(database, clock: () => now);
    for (int i = 0; i < 12; i++) {
      now = now.add(const Duration(minutes: 1));
      final AutoBackupResult result = await service.runAutoBackup(directory);
      expect(result, isA<AutoBackupCreated>());
    }

    final List<String> names = (await directory.list().toList())
        .map((FileSystemEntity file) => file.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(names, hasLength(10));
    // Удалены два самых СТАРЫХ штампа (12:01 и 12:02), а не «первые попавшиеся»
    // — при равном mtime это различимо только по штампу из имени (A16).
    expect(names.first, 'kopilka-backup-2026-09-26T12-03-00.000Z.json');
    expect(names.last, 'kopilka-backup-2026-09-26T12-12-00.000Z.json');
    expect(names, isNot(contains('kopilka-backup-2026-09-26T12-01-00.000Z.json')));
  });

  group('строгая валидация формы перевода (A13/D-21)', () {
    // Хелпер: документ с двумя счетами (RUB и USD) и одной транзакцией;
    // форму/суммы задаёт вызывающий тест.
    Future<Map<String, dynamic>> documentWithTransaction(
      Map<String, dynamic> transaction,
    ) async =>
        <String, dynamic>{
          'schema_version': 3,
          'data': <String, dynamic>{
            'currencies': <dynamic>[
              <String, dynamic>{
                'code': 'RUB',
                'symbol': '₽',
                'is_base': true,
                'rate_to_base': 1,
                'created_at': '2026-09-26T00:00:00.000Z',
                'updated_at': '2026-09-26T00:00:00.000Z',
              },
              <String, dynamic>{
                'code': 'USD',
                'symbol': r'$',
                'is_base': false,
                'rate_to_base': 79.5,
                'created_at': '2026-09-26T00:00:00.000Z',
                'updated_at': '2026-09-26T00:00:00.000Z',
              },
            ],
            'accounts': <dynamic>[
              <String, dynamic>{
                'id': 'acc-rub',
                'name': 'Рублёвый',
                'kind': 'card',
                'currency_code': 'RUB',
                'created_at': '2026-09-26T00:00:00.000Z',
                'updated_at': '2026-09-26T00:00:00.000Z',
              },
              <String, dynamic>{
                'id': 'acc-rub2',
                'name': 'Рублёвый второй',
                'kind': 'bank',
                'currency_code': 'RUB',
                'created_at': '2026-09-26T00:00:00.000Z',
                'updated_at': '2026-09-26T00:00:00.000Z',
              },
              <String, dynamic>{
                'id': 'acc-usd',
                'name': 'Долларовый',
                'kind': 'cash',
                'currency_code': 'USD',
                'created_at': '2026-09-26T00:00:00.000Z',
                'updated_at': '2026-09-26T00:00:00.000Z',
              },
            ],
            'categories': <dynamic>[],
            'transactions': <dynamic>[transaction],
            'budgets': <dynamic>[],
          },
        };

    final Map<String, dynamic> baseRow = <String, dynamic>{
      'id': 'tx-1',
      'amount_minor': 7900,
      'date': '2026-09-26T00:00:00.000Z',
      'created_at': '2026-09-26T00:00:00.000Z',
      'updated_at': '2026-09-26T00:00:00.000Z',
    };

    test('перевод между разными валютами без target_amount_minor — отказ',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'transfer',
        'account_id': 'acc-rub',
        'target_account_id': 'acc-usd',
        'currency_code': 'RUB',
      }));
      expect(
        () => BackupService(database).importJson(json),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException e) => e.kind,
            'kind',
            BackupFailure.invalidData,
          ),
        ),
      );
    });

    test('перевод в одной валюте с target_amount_minor — отказ', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'transfer',
        'account_id': 'acc-rub',
        'target_account_id': 'acc-rub2',
        'currency_code': 'RUB',
        'target_amount_minor': 90,
      }));
      expect(
        () => BackupService(database).importJson(json),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException e) => e.kind,
            'kind',
            BackupFailure.invalidData,
          ),
        ),
      );
    });

    test('не-перевод с заполненным target_amount_minor — отказ', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'expense',
        'account_id': 'acc-rub',
        'currency_code': 'RUB',
        'target_amount_minor': 100,
      }));
      expect(
        () => BackupService(database).importJson(json),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException e) => e.kind,
            'kind',
            BackupFailure.invalidData,
          ),
        ),
      );
    });

    test('target_account_id без type=transfer — отказ (в т.ч. старый файл)',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'income',
        'account_id': 'acc-rub',
        'target_account_id': 'acc-usd',
        'currency_code': 'RUB',
      }));
      expect(
        () => BackupService(database).importJson(json),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException e) => e.kind,
            'kind',
            BackupFailure.invalidData,
          ),
        ),
      );
    });

    test('transfer без target_account_id — отказ (в т.ч. старый файл)',
        () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'transfer',
        'account_id': 'acc-rub',
        'currency_code': 'RUB',
      }));
      expect(
        () => BackupService(database).importJson(json),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException e) => e.kind,
            'kind',
            BackupFailure.invalidData,
          ),
        ),
      );
    });

    test('валидный мультивалютный перевод импортируется целиком', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'transfer',
        'account_id': 'acc-rub',
        'target_account_id': 'acc-usd',
        'currency_code': 'RUB',
        'target_amount_minor': 100,
      }));
      await BackupService(database).importJson(json);
      final Transaction imported =
          await database.transactionsDao.getFiltered().then((r) => r.single);
      expect(imported.amountMinor, 7900);
      expect(imported.targetAmountMinor, 100);
    });

    test('валидный одно-валютный перевод v2 (NULL) импортируется', () async {
      final AppDatabase database = await seeded();
      addTearDown(database.close);
      final String json = jsonEncode(await documentWithTransaction(<String, dynamic>{
        ...baseRow,
        'type': 'transfer',
        'account_id': 'acc-rub',
        'target_account_id': 'acc-rub2',
        'currency_code': 'RUB',
      }));
      await BackupService(database).importJson(json);
      final Transaction imported =
          await database.transactionsDao.getFiltered().then((r) => r.single);
      expect(imported.targetAmountMinor, isNull);
    });
  });

  test('автобэкап создаёт вложенный каталог, если его нет', () async {
    final AppDatabase database = await seeded();
    addTearDown(database.close);
    final Directory base =
        await Directory.systemTemp.createTemp('kopilka_backup_base');
    addTearDown(() => base.delete(recursive: true));
    final Directory nested = Directory(
      '${base.path}${Platform.pathSeparator}auto${Platform.pathSeparator}deep',
    );

    final AutoBackupResult result =
        await BackupService(database).runAutoBackup(nested);
    expect(result, isA<AutoBackupCreated>());
    expect(await nested.list().length, 1);
  });
}
