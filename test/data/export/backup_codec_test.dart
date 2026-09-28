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

    expect(backup.schemaVersion, backupSchemaVersion);
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

  test('миграция v1 → v2: budgets дополняется пустым списком', () {
    // Файл формата v1 (релиз v0.1) не содержит budgets: миграция формата
    // обязана дополнить его пустой таблицей, данные — без изменений.
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
    expect(backup.budgets, isEmpty);
    expect(backup.currencies, isEmpty);
    expect(backup.exportedAt?.toUtc().toIso8601String(),
        '2026-09-25T10:00:00.000Z');
  });

  test('декод читает таблицу budgets формата v2', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 2,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[
          <String, dynamic>{
            'id': 'bud-1',
            'category_id': 'cat-1',
            'limit_minor': 250000,
            'created_at': '2026-10-01T00:00:00.000Z',
            'updated_at': '2026-10-02T00:00:00.000Z',
            'deleted_at': null,
          },
        ],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.budgets, hasLength(1));
    expect(backup.budgets.single.id, 'bud-1');
    expect(backup.budgets.single.categoryId, 'cat-1');
    expect(backup.budgets.single.limitMinor, 250000);
    expect(backup.budgets.single.deletedAt, isNull);
  });

  test('битая строка budgets — отказ invalidData', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 2,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[
          <String, dynamic>{
            'id': 'bud-1',
            'category_id': 'cat-1',
            'limit_minor': 'не число',
            'created_at': '2026-10-01T00:00:00.000Z',
            'updated_at': '2026-10-01T00:00:00.000Z',
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

  test('v3: строка перевода с target_amount_minor читается типизированно', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 3,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[
          <String, dynamic>{
            'id': 'tx-mc',
            'type': 'transfer',
            'account_id': 'acc-1',
            'target_account_id': 'acc-2',
            'amount_minor': 7900,
            'target_amount_minor': 100,
            'currency_code': 'RUB',
            'date': '2026-09-26T00:00:00.000Z',
            'created_at': '2026-09-26T00:00:00.000Z',
            'updated_at': '2026-09-26T00:00:00.000Z',
          },
        ],
        'budgets': <dynamic>[],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.transactions.single.type, TransactionType.transfer);
    expect(backup.transactions.single.amountMinor, 7900);
    expect(backup.transactions.single.targetAmountMinor, 100);
  });

  test('v1/v2 без поля target_amount_minor: читается как NULL (D-21)', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 2,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[
          <String, dynamic>{
            'id': 'tx-old',
            'type': 'transfer',
            'account_id': 'acc-1',
            'target_account_id': 'acc-2',
            'amount_minor': 5000,
            'currency_code': 'RUB',
            'date': '2026-09-26T00:00:00.000Z',
            'created_at': '2026-09-26T00:00:00.000Z',
            'updated_at': '2026-09-26T00:00:00.000Z',
          },
        ],
        'budgets': <dynamic>[],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.transactions.single.targetAmountMinor, isNull);
  });

  test('v4: строка категории с icon_code читается типизированно (D-54)', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 4,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[
          <String, dynamic>{
            'id': 'cat-1',
            'name': 'Продукты',
            'kind': 'expense',
            'is_system': true,
            'icon_code': 'groceries',
            'created_at': '2026-09-29T00:00:00.000Z',
            'updated_at': '2026-09-29T00:00:00.000Z',
          },
          <String, dynamic>{
            'id': 'cat-2',
            'name': 'Кафе',
            'kind': 'expense',
            'is_system': true,
            'created_at': '2026-09-29T00:00:00.000Z',
            'updated_at': '2026-09-29T00:00:00.000Z',
          },
        ],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.categories, hasLength(2));
    expect(backup.categories.first.iconCode, 'groceries');
    // Нет поля = NULL: категория без иконки — валидное состояние.
    expect(backup.categories.last.iconCode, isNull);
  });

  test('v1/v2/v3 без поля icon_code: категории читаются как NULL (D-54)', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 3,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[
          <String, dynamic>{
            'id': 'cat-1',
            'name': 'Продукты',
            'kind': 'expense',
            'is_system': true,
            'created_at': '2026-09-29T00:00:00.000Z',
            'updated_at': '2026-09-29T00:00:00.000Z',
          },
        ],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.schemaVersion, 3);
    expect(backup.categories.single.iconCode, isNull);
  });

  test('неизвестный справочнику icon_code — отказ импорта (D-54/D-25)', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 4,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[
          <String, dynamic>{
            'id': 'cat-1',
            'name': 'Продукты',
            'kind': 'expense',
            'is_system': true,
            'icon_code': 'нет-такого',
            'created_at': '2026-09-29T00:00:00.000Z',
            'updated_at': '2026-09-29T00:00:00.000Z',
          },
        ],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[],
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

  test('битый icon_code (не строка) — отказ invalidData', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 4,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[
          <String, dynamic>{
            'id': 'cat-1',
            'name': 'Продукты',
            'kind': 'expense',
            'is_system': true,
            'icon_code': 42,
            'created_at': '2026-09-29T00:00:00.000Z',
            'updated_at': '2026-09-29T00:00:00.000Z',
          },
        ],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[],
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

  test('битый target_amount_minor (не число) — отказ invalidData', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 3,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[
          <String, dynamic>{
            'id': 'tx-mc',
            'type': 'transfer',
            'account_id': 'acc-1',
            'target_account_id': 'acc-2',
            'amount_minor': 7900,
            'target_amount_minor': 'не число',
            'currency_code': 'RUB',
            'date': '2026-09-26T00:00:00.000Z',
            'created_at': '2026-09-26T00:00:00.000Z',
            'updated_at': '2026-09-26T00:00:00.000Z',
          },
        ],
        'budgets': <dynamic>[],
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
}
