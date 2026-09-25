// Тесты сервиса бэкапов (§4): атомарная замена при импорте, CSV-экспорт
// живых операций, автобэкап с ротацией последних 10 файлов.
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
      note: 'кофе; с "дополнением"',
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

    final String csv = await BackupService(database).exportTransactionsCsv();
    final List<String> lines = csv.trim().split('\n');
    expect(lines.first, 'id;date;type;account;target_account;category;amount;currency;note');
    expect(lines, hasLength(3));

    // Список отсортирован по дате сверху: обе операции за один момент
    // (TestClock сервиса не подменён, даты почти равны), поэтому ищем
    // строки по типу, а не по позиции.
    final String expenseLine = lines
        .where((String line) => line.contains(';expense;'))
        .single;
    final List<String> expenseFields = expenseLine.split(';');
    expect(expenseFields[3], 'Наличные');
    expect(expenseFields[5], 'Жильё');
    expect(expenseFields[6], '123.45');
    // Заметка с разделителями закрыта в кавычки (двойные внутри удвоены);
    // внутри кавычек есть ';', поэтому проверяем конец строки целиком.
    expect(expenseLine, endsWith(';"кофе; с ""дополнением"""'));

    final List<String> transferLine = lines
        .where((String line) => line.contains(';transfer;'))
        .single
        .split(';');
    expect(transferLine[4], 'Карта');
    expect(transferLine[5], isEmpty);
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
