import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/export/backup_codec.dart';

/// Импорт/экспорт данных (ARCHITECTURE.md §4): JSON-бэкап полного дампа,
/// CSV-экспорт операций, автобэкап при запуске с ротацией последних 10.
///
/// Работает поверх той же БД, что и DAO, но пишет дампа-строки напрямую
/// (это единственное место с прямым SQL, кроме DAO): экспорт обязан дать
/// полный дамп с мягко удалёнными строками, а импорт — атомарно заменить
/// всё содержимое, что через API живых записей не выражается.
class BackupService {
  BackupService(this.db, {this.clock = utcNow});

  final AppDatabase db;
  final Clock clock;

  /// Экспорт полного дампа в JSON-строку (формат v2, см. кодек).
  Future<String> exportJson() async =>
      jsonEncode(await exportToJson(db));

  /// Атомарно заменяет содержимое БД на данные бэкапа.
  ///
  /// Порядок транзакции: всё снести → валюты → счета → категории →
  /// операции (внешние ключи включены, `PRAGMA foreign_keys = ON` из
  /// beforeOpen). Транзакция drift атомарна: падение посреди импорта
  /// оставляет базу нетронутой. Валидация формата выполняется ДО транзакции.
  Future<void> importJson(String json) async {
    final Map<String, dynamic> document;
    try {
      final Object? decoded = jsonDecode(json);
      document = decoded is Map<String, dynamic>
          ? decoded
          : throw BackupValidationException(
              'корневой элемент должен быть объектом',
              kind: BackupFailure.invalidFormat,
            );
    } on BackupValidationException {
      rethrow;
    } on FormatException catch (error) {
      throw BackupValidationException(
        'файл не является корректным JSON: ${error.message}',
        kind: BackupFailure.invalidFormat,
      );
    }

    final DecodedBackup backup = decodeJson(document);
    await _validateReferences(backup);

    await db.transaction(() async {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      try {
        await db.customUpdate('DELETE FROM budgets');
        await db.customUpdate('DELETE FROM transactions');
        await db.customUpdate('DELETE FROM categories');
        await db.customUpdate('DELETE FROM accounts');
        await db.customUpdate('DELETE FROM currencies');

        for (final BackupCurrency row in backup.currencies) {
          await db.into(db.currencies).insert(
                CurrenciesCompanion.insert(
                  code: row.code,
                  symbol: row.symbol,
                  isBase: Value(row.isBase),
                  rateToBase: Value(row.rateToBase),
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  deletedAt: Value(row.deletedAt),
                ),
              );
        }
        for (final BackupAccount row in backup.accounts) {
          await db.into(db.accounts).insert(
                AccountsCompanion.insert(
                  id: row.id,
                  name: row.name,
                  kind: row.kind.dbValue,
                  currencyCode: row.currencyCode,
                  initialBalanceMinor: Value(row.initialBalanceMinor),
                  sortOrder: Value(row.sortOrder),
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  deletedAt: Value(row.deletedAt),
                ),
              );
        }
        for (final BackupCategory row in backup.categories) {
          await db.into(db.categories).insert(
                CategoriesCompanion.insert(
                  id: row.id,
                  name: row.name,
                  kind: row.kind.dbValue,
                  parentId: Value(row.parentId),
                  icon: Value(row.icon),
                  color: Value(row.color),
                  isSystem: Value(row.isSystem),
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  deletedAt: Value(row.deletedAt),
                ),
              );
        }
        for (final BackupTransaction row in backup.transactions) {
          await db.into(db.transactions).insert(
                TransactionsCompanion.insert(
                  id: row.id,
                  type: row.type.dbValue,
                  accountId: row.accountId,
                  targetAccountId: Value(row.targetAccountId),
                  categoryId: Value(row.categoryId),
                  amountMinor: row.amountMinor,
                  currencyCode: row.currencyCode,
                  date: row.date,
                  note: Value(row.note),
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  deletedAt: Value(row.deletedAt),
                ),
              );
        }
        for (final BackupBudget row in backup.budgets) {
          await db.into(db.budgets).insert(
                BudgetsCompanion.insert(
                  id: row.id,
                  categoryId: row.categoryId,
                  limitMinor: row.limitMinor,
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  deletedAt: Value(row.deletedAt),
                ),
              );
        }
      } finally {
        await db.customStatement('PRAGMA foreign_keys = ON');
      }
    });
  }

  /// Внутренние ссылки дампа обязаны сходиться (FK включён, но ошибка
  /// SQLite не объясняет пользователю, ЧТО битое; валюта целостности —
  /// верхнего уровня: строки могут ссылаться на мягко удалённые записи,
  /// это нормально, поэтому проверяем только существование PK).
  Future<void> _validateReferences(DecodedBackup backup) async {
    final Set<String> currencyCodes = <String>{
      for (final BackupCurrency row in backup.currencies) row.code,
    };
    final Set<String> accountIds = <String>{
      for (final BackupAccount row in backup.accounts) row.id,
    };
    final Set<String> categoryIds = <String>{
      for (final BackupCategory row in backup.categories) row.id,
    };

    for (final BackupAccount row in backup.accounts) {
      if (!currencyCodes.contains(row.currencyCode)) {
        throw BackupValidationException(
          'счёт «${row.name}» ссылается на отсутствующую валюту ${row.currencyCode}',
          kind: BackupFailure.invalidData,
        );
      }
    }
    for (final BackupCategory row in backup.categories) {
      if (row.parentId != null && !categoryIds.contains(row.parentId)) {
        throw BackupValidationException(
          'категория «${row.name}» ссылается на отсутствующего родителя',
          kind: BackupFailure.invalidData,
        );
      }
    }
    for (final BackupTransaction row in backup.transactions) {
      if (!accountIds.contains(row.accountId)) {
        throw BackupValidationException(
          'операция ссылается на отсутствующий счёт ${row.accountId}',
          kind: BackupFailure.invalidData,
        );
      }
      if (row.targetAccountId != null &&
          !accountIds.contains(row.targetAccountId)) {
        throw BackupValidationException(
          'перевод ссылается на отсутствующий счёт зачисления',
          kind: BackupFailure.invalidData,
        );
      }
      if (row.categoryId != null && !categoryIds.contains(row.categoryId)) {
        throw BackupValidationException(
          'операция ссылается на отсутствующую категорию',
          kind: BackupFailure.invalidData,
        );
      }
    }
    for (final BackupBudget row in backup.budgets) {
      if (!categoryIds.contains(row.categoryId)) {
        throw BackupValidationException(
          'бюджет ссылается на отсутствующую категорию ${row.categoryId}',
          kind: BackupFailure.invalidData,
        );
      }
    }
  }

  /// CSV-экспорт ЖИВЫХ операций (для Excel/таблиц): новые сверху, суммы —
  /// мажорными числами, человекочитаемые значения. Данные дампом уже
  /// покрывает JSON-бэкап, CSV — отчётный формат, поэтому здесь только
  /// живые записи и без служебных колонок (created_at и т. п.).
  Future<String> exportTransactionsCsv() async {
    final List<Transaction> rows = await db.transactionsDao.getFiltered();
    final List<Account> accounts = await db.accountsDao.getAlive();
    final List<Category> categories = await db.categoriesDao.getAlive();
    final Map<String, String> accountNames = <String, String>{
      for (final Account account in accounts) account.id: account.name,
    };
    final Map<String, String> categoryNames = <String, String>{
      for (final Category category in categories) category.id: category.name,
    };

    final StringBuffer csv = StringBuffer(
      'id;date;type;account;target_account;category;amount;currency;note\n',
    );
    for (final Transaction row in rows) {
      final String type = switch (TransactionType.fromDb(row.type)) {
        TransactionType.income => 'income',
        TransactionType.expense => 'expense',
        TransactionType.transfer => 'transfer',
      };
      final String amount =
          '${row.amountMinor ~/ 100}.'
          '${(row.amountMinor % 100).toString().padLeft(2, '0')}';
      csv.writeln(<String>[
        row.id,
        row.date.toUtc().toIso8601String(),
        type,
        _csvField(accountNames[row.accountId] ?? row.accountId),
        _csvField(
          row.targetAccountId == null
              ? ''
              : (accountNames[row.targetAccountId!] ?? row.targetAccountId!),
        ),
        _csvField(
          row.categoryId == null
              ? ''
              : (categoryNames[row.categoryId!] ?? row.categoryId!),
        ),
        _csvField(amount),
        row.currencyCode,
        _csvField(row.note ?? ''),
      ].join(';'));
    }
    return csv.toString();
  }

  String _csvField(String value) =>
      (value.contains(';') || value.contains('"') || value.contains('\n'))
          ? '"${value.replaceAll('"', '""')}"'
          : value;

  /// Автобэкап при запуске (§4): JSON в выбранный пользователем каталог,
  /// хранить последние 10.
  ///
  /// Каталог не выбран — автобэкап отключён. Ошибки файловой системы не
  /// должны мешать запуску приложения: они возвращаются результатом.
  Future<AutoBackupResult> runAutoBackup(Directory directory) async {
    try {
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final String json = await exportJson();
      final DateTime now = clock();
      final String stamp = now.toIso8601String().replaceAll(':', '-');
      final File file = File(
        '${directory.path}${Platform.pathSeparator}kopilka-backup-$stamp.json',
      );
      await file.writeAsString(json, flush: true);
      final int removed = await _rotateBackups(directory, keep: 10);
      return AutoBackupCreated(file: file, removedOld: removed);
    } on IOException catch (error) {
      return AutoBackupFailed(reason: error.toString());
    }
  }

  /// Оставляет `keep` самых свежих файлов `kopilka-backup-*.json`.
  Future<int> _rotateBackups(Directory directory, {required int keep}) async {
    final List<File> backups = <File>[
      await for (final FileSystemEntity entity in directory.list())
        if (entity is File &&
            entity.path.contains('kopilka-backup-') &&
            entity.path.endsWith('.json'))
          entity,
    ];
    int removed = 0;
    if (backups.length <= keep) {
      return removed;
    }
    backups.sort(
      (File a, File b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    for (final File stale in backups.skip(keep)) {
      await stale.delete();
      removed++;
    }
    return removed;
  }
}

/// Итог автобэкапа: создан файл (с числом удалённых старых) или отказ.
sealed class AutoBackupResult {
  const AutoBackupResult();
}

/// Автобэкап создан.
class AutoBackupCreated extends AutoBackupResult {
  const AutoBackupCreated({required this.file, required this.removedOld});

  final File file;
  final int removedOld;
}

/// Автобэкап не удался (файловая система); приложение продолжает работу.
class AutoBackupFailed extends AutoBackupResult {
  const AutoBackupFailed({required this.reason});

  final String reason;
}
