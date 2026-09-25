// Тесты кодека JSON-бэкапа (§4): полный дамп включает мягко удалённые,
// декод проверяет схему, версии и битые данные. drift импортируется
// с hide isNotNull/isNull — конфликт с матчерами flutter_test.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/export/backup_codec.dart';
import 'package:kopilka/data/export/backup_service.dart';

AppDatabase db() => AppDatabase.forTesting(NativeDatabase.memory());

/// Засеивает счёт, операцию и мягко удалённую пользовательскую категорию:
/// дамп обязан сохранить все строки, включая мягко удалённые.
Future<void> seedWithSoftDeleted(AppDatabase database) async {
  await seedDefaultsIfEmpty(database);
  await database.accountsDao.create(
    name: 'Наличные',
    kind: AccountKind.cash,
    currencyCode: 'RUB',
    initialBalanceMinor: 1000,
  );
  final List<Category> expense =
      await database.categoriesDao.getAlive(kind: CategoryKind.expense);
  await database.transactionsDao.create(
    type: TransactionType.expense,
    accountId: (await database.accountsDao.getAlive()).single.id,
    categoryId: expense.first.id,
    amountMinor: 250,
    note: 'продукты',
  );
  // Пользовательская (не системная) категория удаляется через API DAO.
  final Category custom = await database.categoriesDao.create(
    name: 'Моё удалённое',
    kind: CategoryKind.expense,
  );
  await database.categoriesDao.softDelete(custom.id);
}

void main() {
  test('экспорт даёт формат v1 с полным дампом, включая мягко удалённые',
      () async {
    final AppDatabase database = db();
    addTearDown(database.close);
    await seedWithSoftDeleted(database);

    final Map<String, dynamic> document =
        jsonDecode(await BackupService(database).exportJson())
            as Map<String, dynamic>;

    expect(document['schema_version'], backupSchemaVersion);
    expect(DateTime.parse(document['exported_at'] as String).toUtc(),
        isA<DateTime>());
    final Map<String, dynamic> data =
        document['data'] as Map<String, dynamic>;
    expect(data.keys, containsAll(<String>[
      'currencies',
      'accounts',
      'categories',
      'transactions',
    ]));
    // Мягко удалённая категория присутствует в дампе.
    final List<dynamic> categories = data['categories'] as List<dynamic>;
    expect(
      categories.where((dynamic row) => row['deleted_at'] != null),
      hasLength(1),
    );
    // Проверка полноты: строка операции с деньгами в минорных единицах.
    final List<dynamic> transactions = data['transactions'] as List<dynamic>;
    expect(transactions.single['amount_minor'], 250);
    expect(transactions.single['currency_code'], 'RUB');
  });

  test('декод возвращает типизированные строки и версию исходника',
      () async {
    final AppDatabase database = db();
    addTearDown(database.close);
    await seedWithSoftDeleted(database);

    final String json =
        await BackupService(database).exportJson();
    final DecodedBackup backup =
        decodeJson(jsonDecode(json) as Map<String, dynamic>);

    expect(backup.schemaVersion, 1);
    expect(backup.currencies.single.code, 'RUB');
    expect(backup.accounts.single.kind, AccountKind.cash);
    // 12 системных посева + 1 пользовательская (мягко удалена).
    expect(backup.categories, hasLength(13));
    expect(
      backup.categories.where((BackupCategory row) => row.deletedAt != null),
      hasLength(1),
    );
    expect(backup.transactions.single.type, TransactionType.expense);
    // Даты нормализованы к UTC.
    expect(
      backup.transactions.single.date.isUtc,
      isTrue,
      reason: 'даты дампа сравниваются через toUtc (§3)',
    );
  });

  test('schema_version новее поддерживаемой — отказ tooNew', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': backupSchemaVersion + 1,
      'data': <String, dynamic>{},
    };
    expect(
      () => decodeJson(document),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException error) => error.kind,
          'kind',
          BackupFailure.tooNew,
        ),
      ),
    );
  });

  test('старые версии без миграции — отказ tooOld', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 0,
      'data': <String, dynamic>{},
    };
    expect(
      () => decodeJson(document),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException error) => error.kind,
          'kind',
          BackupFailure.tooOld,
        ),
      ),
    );
  });

  test('битые данные — отказ invalidData с указанием поля', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 1,
      'data': <String, dynamic>{
        'currencies': <dynamic>[
          <String, dynamic>{
            'code': 'RUB',
            'symbol': '₽',
            'is_base': true,
            'rate_to_base': 1,
            'created_at': 'не дата',
            'updated_at': '2026-09-25T00:00:00.000Z',
            'deleted_at': null,
          },
        ],
      },
    };
    expect(
      () => decodeJson(document),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException error) => error.kind,
          'kind',
          BackupFailure.invalidData,
        ),
      ),
    );
  });

  test('неизвестное значение kind — отказ invalidData', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 1,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[
          <String, dynamic>{
            'id': 'acc-1',
            'name': 'Х',
            'kind': 'crypto',
            'currency_code': 'RUB',
            'created_at': '2026-09-25T00:00:00.000Z',
            'updated_at': '2026-09-25T00:00:00.000Z',
          },
        ],
        'categories': <dynamic>[],
        'transactions': <dynamic>[],
      },
    };
    expect(
      () => decodeJson(document),
      throwsA(
        isA<BackupValidationException>().having(
          (BackupValidationException error) => error.kind,
          'kind',
          BackupFailure.invalidData,
        ),
      ),
    );
  });

  test('каскад миграций применяет формат v1 файла v2', () {
    // Синтетический пример: когда появится формат v2, здесь проверяется
    // его миграция. Пока v1 проходит без изменений.
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 1,
      'exported_at': '2026-09-25T10:00:00.000Z',
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.schemaVersion, 1);
    expect(backup.currencies, isEmpty);
    expect(backup.exportedAt?.toUtc().toIso8601String(),
        '2026-09-25T10:00:00.000Z');
  });
}
