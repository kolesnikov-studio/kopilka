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
  final List<Category> expense = await database.categoriesDao.getAlive(
    kind: CategoryKind.expense,
  );
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
  test(
    'экспорт даёт формат v1 с полным дампом, включая мягко удалённые',
    () async {
      final AppDatabase database = db();
      addTearDown(database.close);
      await seedWithSoftDeleted(database);

      final Map<String, dynamic> document = jsonDecode(
        await BackupService(database).exportJson(),
      ) as Map<String, dynamic>;

      expect(document['schema_version'], backupSchemaVersion);
      expect(
        DateTime.parse(document['exported_at'] as String).toUtc(),
        isA<DateTime>(),
      );
      final Map<String, dynamic> data =
          document['data'] as Map<String, dynamic>;
      expect(
        data.keys,
        containsAll(<String>[
          'currencies',
          'accounts',
          'categories',
          'transactions',
        ]),
      );
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
    },
  );

  test('декод возвращает типизированные строки и версию исходника', () async {
    final AppDatabase database = db();
    addTearDown(database.close);
    await seedWithSoftDeleted(database);

    final String json = await BackupService(database).exportJson();
    final DecodedBackup backup = decodeJson(
      jsonDecode(json) as Map<String, dynamic>,
    );

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
    expect(
      backup.exportedAt?.toUtc().toIso8601String(),
      '2026-09-25T10:00:00.000Z',
    );
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

  test(
    'v5: строка счёта с exclude_from_balance читается типизированно (D-54)',
    () {
      final Map<String, dynamic> document = <String, dynamic>{
        'schema_version': 5,
        'data': <String, dynamic>{
          'currencies': <dynamic>[],
          'accounts': <dynamic>[
            <String, dynamic>{
              'id': 'acc-1',
              'name': 'Накопительный',
              'kind': 'bank',
              'currency_code': 'RUB',
              'initial_balance_minor': 9900000,
              'sort_order': 0,
              'exclude_from_balance': true,
              'created_at': '2026-09-29T00:00:00.000Z',
              'updated_at': '2026-09-29T00:00:00.000Z',
            },
            <String, dynamic>{
              'id': 'acc-2',
              'name': 'Карта',
              'kind': 'card',
              'currency_code': 'RUB',
              'initial_balance_minor': 100000,
              'sort_order': 1,
              'exclude_from_balance': false,
              'created_at': '2026-09-29T00:00:00.000Z',
              'updated_at': '2026-09-29T00:00:00.000Z',
            },
          ],
          'categories': <dynamic>[],
          'transactions': <dynamic>[],
          'budgets': <dynamic>[],
        },
      };
      final DecodedBackup backup = decodeJson(document);
      expect(backup.accounts, hasLength(2));
      expect(backup.accounts.first.excludeFromBalance, isTrue);
      // false — валидное явное «учитывать».
      expect(backup.accounts.last.excludeFromBalance, isFalse);
    },
  );

  test(
    'v4-файл без поля exclude_from_balance: счёт читается как NULL (D-54)',
    () {
      final Map<String, dynamic> document = <String, dynamic>{
        'schema_version': 4,
        'data': <String, dynamic>{
          'currencies': <dynamic>[],
          'accounts': <dynamic>[
            <String, dynamic>{
              'id': 'acc-1',
              'name': 'Карта',
              'kind': 'card',
              'currency_code': 'RUB',
              'initial_balance_minor': 100000,
              'sort_order': 0,
              'created_at': '2026-09-29T00:00:00.000Z',
              'updated_at': '2026-09-29T00:00:00.000Z',
            },
          ],
          'categories': <dynamic>[],
          'transactions': <dynamic>[],
          'budgets': <dynamic>[],
        },
      };
      final DecodedBackup backup = decodeJson(document);
      expect(backup.schemaVersion, 4);
      expect(
        backup.accounts.single.excludeFromBalance,
        isNull,
        reason: 'нет поля = NULL = «учитывать» (v1–v4)',
      );
    },
  );

  test('битый exclude_from_balance (не булево) — отказ invalidData (D-25)', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 5,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[
          <String, dynamic>{
            'id': 'acc-1',
            'name': 'Карта',
            'kind': 'card',
            'currency_code': 'RUB',
            'initial_balance_minor': 100000,
            'sort_order': 0,
            'exclude_from_balance': 'да',
            'created_at': '2026-09-29T00:00:00.000Z',
            'updated_at': '2026-09-29T00:00:00.000Z',
          },
        ],
        'categories': <dynamic>[],
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

  // --- v6: вложения в формате экспорта (D-64) ---

  /// Минимальный документ v6 с одной строкой attachments (задаёт тест).
  Map<String, dynamic> v6Document(Map<String, dynamic> attachment) =>
      <String, dynamic>{
        'schema_version': 6,
        'data': <String, dynamic>{
          'currencies': <dynamic>[],
          'accounts': <dynamic>[],
          'categories': <dynamic>[],
          'transactions': <dynamic>[],
          'budgets': <dynamic>[],
          'attachments': <dynamic>[attachment],
        },
      };

  final Map<String, dynamic> baseAttachment = <String, dynamic>{
    'id': 'att-1',
    'transaction_id': 'tx-1',
    'file_path': 'e0abf12c-9.jpg',
    'mime_type': 'image/jpeg',
    'file_size': 123456,
    'created_at': '2026-09-30T00:00:00.000Z',
    'updated_at': '2026-09-30T00:00:00.000Z',
    'deleted_at': null,
  };

  test('v6: строка вложения читается типизированно (D-64)', () {
    final DecodedBackup backup = decodeJson(v6Document(baseAttachment));
    expect(backup.schemaVersion, 6);
    expect(backup.attachments, hasLength(1));
    expect(backup.attachments.single.id, 'att-1');
    expect(backup.attachments.single.transactionId, 'tx-1');
    expect(backup.attachments.single.filePath, 'e0abf12c-9.jpg');
    expect(backup.attachments.single.mimeType, 'image/jpeg');
    expect(backup.attachments.single.fileSize, 123456);
    expect(backup.attachments.single.deletedAt, isNull);
  });

  test('v5-файл без ключа attachments: вложений ноль (D-64)', () {
    final Map<String, dynamic> document = <String, dynamic>{
      'schema_version': 5,
      'data': <String, dynamic>{
        'currencies': <dynamic>[],
        'accounts': <dynamic>[],
        'categories': <dynamic>[],
        'transactions': <dynamic>[],
        'budgets': <dynamic>[],
      },
    };
    final DecodedBackup backup = decodeJson(document);
    expect(backup.schemaVersion, 5);
    expect(
      backup.attachments,
      isEmpty,
      reason: 'нет ключа = пустой список (образец v1→v2 в миграциях формата)',
    );
  });

  test(
    'attachments не массив — отказ invalidFormat (общее правило таблиц)',
    () {
      final Map<String, dynamic> document = v6Document(baseAttachment);
      (document['data'] as Map<String, dynamic>)['attachments'] = 'мусор';
      expect(
        () => decodeJson(document),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException error) => error.kind,
            'kind',
            BackupFailure.invalidFormat,
          ),
        ),
      );
    },
  );

  test('пустой file_path — отказ invalidData (D-64)', () {
    final Map<String, dynamic> document = v6Document(<String, dynamic>{
      ...baseAttachment,
      'file_path': '',
    });
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

  test('mime вне белого списка — отказ invalidData (D-64)', () {
    final Map<String, dynamic> document = v6Document(<String, dynamic>{
      ...baseAttachment,
      'mime_type': 'application/zip',
    });
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

  test('отрицательный file_size — отказ invalidData (D-64)', () {
    final Map<String, dynamic> document = v6Document(<String, dynamic>{
      ...baseAttachment,
      'file_size': -1,
    });
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

  test('битый file_size (не число) — отказ invalidData (D-64)', () {
    final Map<String, dynamic> document = v6Document(<String, dynamic>{
      ...baseAttachment,
      'file_size': 'много',
    });
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

  // --- v7: долги и платежи в формате экспорта (D-85) ---

  /// Минимальный документ v7 с одной строкой долгов (задаёт тест).
  Map<String, dynamic> v7Document({
    Map<String, dynamic>? debt,
    Map<String, dynamic>? payment,
    List<dynamic>? accounts,
  }) => <String, dynamic>{
    'schema_version': 7,
    'data': <String, dynamic>{
      'currencies': <dynamic>[],
      'accounts': accounts ?? <dynamic>[],
      'categories': <dynamic>[],
      'transactions': <dynamic>[],
      'budgets': <dynamic>[],
      'attachments': <dynamic>[],
      if (debt != null) 'debts': <dynamic>[debt],
      if (payment != null) 'debt_payments': <dynamic>[payment],
    },
  };

  final Map<String, dynamic> baseDebt = <String, dynamic>{
    'id': 'debt-1',
    'person': 'Алексей',
    'direction': 'they_owe_me',
    'amount_minor': 500000,
    'extra_minor': 25000,
    'currency_code': 'RUB',
    'due_date': '2026-11-01T00:00:00.000Z',
    'note': 'под расписку',
    'created_at': '2026-09-30T00:00:00.000Z',
    'updated_at': '2026-09-30T00:00:00.000Z',
    'deleted_at': null,
  };

  final Map<String, dynamic> basePayment = <String, dynamic>{
    'id': 'pay-1',
    'debt_id': 'debt-1',
    'transaction_id': 'tx-1',
    'amount_minor': 100000,
    'paid_at': '2026-10-02T00:00:00.000Z',
    'created_at': '2026-09-30T00:00:00.000Z',
    'updated_at': '2026-09-30T00:00:00.000Z',
    'deleted_at': null,
  };

  test('v7: долг и платёж читаются типизированно (D-85)', () {
    final DecodedBackup backup = decodeJson(
      v7Document(debt: baseDebt, payment: basePayment),
    );
    expect(backup.schemaVersion, 7);
    expect(backup.debts, hasLength(1));
    expect(backup.debts.single.id, 'debt-1');
    expect(backup.debts.single.person, 'Алексей');
    expect(backup.debts.single.direction, DebtDirection.theyOweMe);
    expect(backup.debts.single.amountMinor, 500000);
    expect(backup.debts.single.extraMinor, 25000);
    expect(backup.debts.single.currencyCode, 'RUB');
    expect(backup.debts.single.dueDate?.toUtc(), DateTime.utc(2026, 11, 1));
    expect(backup.debts.single.note, 'под расписку');
    expect(backup.debtPayments, hasLength(1));
    expect(backup.debtPayments.single.debtId, 'debt-1');
    expect(backup.debtPayments.single.transactionId, 'tx-1');
    expect(backup.debtPayments.single.amountMinor, 100000);
    expect(
      backup.debtPayments.single.paidAt.toUtc(),
      DateTime.utc(2026, 10, 2),
    );
  });

  test('v7: долг без срока и заметки, платёж без перевода — NULL (D-85)', () {
    final DecodedBackup backup = decodeJson(
      v7Document(
        debt: <String, dynamic>{...baseDebt, 'due_date': null, 'note': null},
        payment: <String, dynamic>{...basePayment, 'transaction_id': null},
      ),
    );
    expect(backup.debts.single.dueDate, isNull);
    expect(backup.debts.single.note, isNull);
    expect(backup.debtPayments.single.transactionId, isNull);
  });

  test('v6-файл без ключей debts/debt_payments: пустые списки (D-85)', () {
    final Map<String, dynamic> document = v7Document(debt: baseDebt);
    (document['data'] as Map<String, dynamic>)
      ..remove('debts')
      ..remove('debt_payments')
      ..remove('attachments');
    document['schema_version'] = 6;
    final DecodedBackup backup = decodeJson(document);
    expect(backup.schemaVersion, 6);
    expect(backup.debts, isEmpty);
    expect(backup.debtPayments, isEmpty);
  });

  test('неизвестный direction — отказ invalidData (D-85/D-25)', () {
    final Map<String, dynamic> document = v7Document(
      debt: <String, dynamic>{...baseDebt, 'direction': 'both'},
    );
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

  test('пустой person — отказ invalidData (D-85)', () {
    final Map<String, dynamic> document = v7Document(
      debt: <String, dynamic>{...baseDebt, 'person': ''},
    );
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

  test('amount_minor = 0 и отрицательный extra_minor — отказ invalidData', () {
    for (final Map<String, dynamic> broken in <Map<String, dynamic>>[
      <String, dynamic>{...baseDebt, 'amount_minor': 0},
      <String, dynamic>{...baseDebt, 'extra_minor': -1},
      <String, dynamic>{...basePayment, 'amount_minor': -5},
    ]) {
      final Map<String, dynamic> document = broken.containsKey('debt_id')
          ? v7Document(payment: broken)
          : v7Document(debt: broken);
      expect(
        () => decodeJson(document),
        throwsA(
          isA<BackupValidationException>().having(
            (BackupValidationException error) => error.kind,
            'kind',
            BackupFailure.invalidData,
          ),
        ),
        reason: 'строка ${broken['id']}',
      );
    }
  });

  test(
    'v7: interest_reminder_date счёта читается, v6-строка — NULL (D-85)',
    () {
      final Map<String, dynamic> accountRow = <String, dynamic>{
        'id': 'acc-1',
        'name': 'Накопительный',
        'kind': 'bank',
        'currency_code': 'RUB',
        'initial_balance_minor': 9900000,
        'sort_order': 0,
        'interest_reminder_date': '2026-10-30T00:00:00.000Z',
        'created_at': '2026-09-30T00:00:00.000Z',
        'updated_at': '2026-09-30T00:00:00.000Z',
      };
      final DecodedBackup backup = decodeJson(
        v7Document(accounts: <dynamic>[accountRow]),
      );
      expect(
        backup.accounts.single.interestReminderDate?.toUtc(),
        DateTime.utc(2026, 10, 30),
      );

      // Нет поля (v1–v6) = NULL.
      final Map<String, dynamic> withoutField = Map<String, dynamic>.from(
        accountRow,
      )..remove('interest_reminder_date');
      final DecodedBackup oldFile = decodeJson(
        v7Document(accounts: <dynamic>[withoutField]),
      );
      expect(oldFile.accounts.single.interestReminderDate, isNull);
    },
  );

  test(
    'импорт v5-файла восстанавливает флаг счёта (round-trip кодека)',
    () async {
      final AppDatabase database = db();
      addTearDown(database.close);
      await seedDefaultsIfEmpty(database);
      await database.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
        initialBalanceMinor: 9900000,
        excludeFromBalance: true,
      );

      final String json = await BackupService(database).exportJson();
      final Map<String, dynamic> document =
          jsonDecode(json) as Map<String, dynamic>;
      expect(document['schema_version'], backupSchemaVersion);
      // Замок версии формата (прецедент замков миграций D-55): экспорт
      // обязан быть v7 — долги и платежи в дампе (M6, D-85).
      expect(backupSchemaVersion, 7);

      final AppDatabase restored = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(restored.close);
      await BackupService(restored).importJson(json);

      final List<Account> accounts = await restored.accountsDao.getAlive();
      final Account savings = accounts.singleWhere(
        (Account a) => a.name == 'Накопительный',
      );
      expect(savings.excludeFromBalance, isTrue);
    },
  );
}
