import 'package:drift/drift.dart';

import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/tables.dart';

part 'attachments_dao.g.dart';

/// Ключ владельца вложения в колонке `transaction_id` (M6/D-82: обобщение
/// на долга без миграции таблицы). Живой прецедент «владелец за
/// строкой-ссылкой» — чтение v1–v6 в `BackupCodec` (D-64/D-87).
abstract final class AttachmentOwner {
  /// Владелец — операция (M5): значение без префикса — сырой PK операции.
  /// Префиксов у UUID (§3) нет, двоеточие однозначно.
  static const String _transactionPrefix = 't:';

  /// Владелец — долг (M6): `d:<uuid>` в той же колонке.
  static const String _debtPrefix = 'd:';

  /// Владелец — операция: ключ из [AttachmentOwner.transaction] и
  /// его же id (обратное преобразование).
  static String? transactionOwner(String? value) =>
      value == null || value.startsWith(_transactionPrefix) ? null : value;

  /// Владелец — долг; NULL — в значении нет ключа долга.
  static String? debtOwner(String? value) =>
      value == null || !value.startsWith(_debtPrefix)
      ? null
      : value.substring(_debtPrefix.length);

  /// Ключ владельца-долга для записи в колонку.
  static String debt(String debtId) => '$_debtPrefix$debtId';
}

/// Вложения к операциям (v6, D-63): метаданные файла рядом с операцией.
///
/// Правила:
/// - ровно один живой файл на операцию — правило DAO, не SQL (образец
///   «один живой бюджет на категорию»): повторное вложение той же операции
///   заменяет прежнее — старая запись уходит в soft delete; расширение до
///   многих вложений — без миграции;
/// - запись создаётся только на живую операцию ([DataFailure.notFound]);
/// - MIME ограничен белым списком (image/*, application/pdf), размер —
///   лимитом-константой: проверка по месту — в сервисе вложений, DAO
///   повторяет её как последняя линия защиты;
/// - удаление — только soft delete записи, без каскадов (§3): мягкое
///   удаление операции файл не трогает. Файл на диске удаляет сервис
///   вложений ([AttachmentsService.delete]) — слой БД файлами не ведает.
@DriftAccessor(tables: [Attachments, Transactions, Debts])
class AttachmentsDao extends DatabaseAccessor<AppDatabase>
    with _$AttachmentsDaoMixin {
  AttachmentsDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт запись вложения для живой операции. Если у операции уже есть
  /// живое вложение — оно мягко удаляется (замена прежнего файла, D-63).
  ///
  /// [filePath] — относительное имя файла в каталоге вложений, как его
  /// вернуло хранилище (`<uuid><расширение>`); [mimeType] — из белого
  /// списка; [fileSize] — размер файла в байтах, положительный.
  Future<Attachment> create({
    required String transactionId,
    required String filePath,
    required String mimeType,
    required int fileSize,
  }) async {
    _ensureFileMeta(mimeType: mimeType, filePath: filePath, fileSize: fileSize);
    final Transaction? transaction = _transactionOf(transactionId) == null
        ? null
        : await (select(transactions)..where(
                (t) => t.id.equals(transactionId) & t.deletedAt.isNull(),
              ))
              .getSingleOrNull();
    if (_transactionOf(transactionId) != null && transaction == null) {
      throw DataValidationException(
        'операция $transactionId не найдена',
        kind: DataFailure.notFound,
      );
    }
    if (_transactionOf(transactionId) == null &&
        await _requireAliveDebtOwner(transactionId) == null) {
      throw DataValidationException(
        'владелец вложения $transactionId не найден (операция или долг)',
        kind: DataFailure.notFound,
      );
    }
    final DateTime now = clock();
    // Правило «один живой файл на операцию» (D-63): прежнее вложение
    // мягко удаляется — замена, не отказ (образец бюджетов; у бюджета
    // отказ, здесь файл единственный, повторное вложение = замена).
    await _replaceExisting(await findByTransaction(transactionId), now: now);
    return into(attachments).insertReturning(
      AttachmentsCompanion.insert(
        id: idGenerator(),
        transactionId: transactionId,
        filePath: filePath,
        mimeType: mimeType,
        fileSize: fileSize,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живое вложение операции (или NULL): без префикса и с ним — истории
  /// M5 старые ключи не имеют.
  Future<Attachment?> findByTransaction(String transactionId) =>
      _findByOwner(AttachmentOwner.transactionOwner(transactionId));

  /// Живое вложение долга (или NULL): ключ с префиксом `d:` (M6/D-82).
  Future<Attachment?> findByDebt(String debtId) =>
      _findByOwner(AttachmentOwner.debt(debtId));

  Future<Attachment?> _findByOwner(String? owner) => owner == null
      ? Future<Attachment?>.value()
      : (select(attachments)..where(
              (t) => t.transactionId.equals(owner) & t.deletedAt.isNull(),
            ))
            .getSingleOrNull();

  /// Живое вложение по id (или NULL).
  Future<Attachment?> findById(String id) => (select(
    attachments,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Живое вложение по id или отказ [DataFailure.notFound] — для сервиса
  /// вложений перед удалением файла.
  Future<Attachment> requireAliveById(String id) => _requireAlive(id);

  /// Мягко удаляет запись вложения. Файл на диске не трогает: удаление
  /// файла — решение сервиса (см. `AttachmentsService.delete`), DAO
  /// работает только с БД.
  Future<void> softDelete(String id) async {
    await _requireAlive(id);
    final DateTime now = clock();
    await (update(attachments)..where((t) => t.id.equals(id))).write(
      AttachmentsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  Future<Attachment> _requireAlive(String id) async {
    final Attachment? attachment = await (select(
      attachments,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (attachment == null) {
      throw DataValidationException(
        'вложение $id не найдено',
        kind: DataFailure.notFound,
      );
    }
    return attachment;
  }

  /// Ид операции из ключа владельца; NULL — ключ долга.
  static String? _transactionOf(String ownerValue) =>
      AttachmentOwner.transactionOwner(ownerValue);

  /// Живой долг-владелец по ключу `d:<id>`; NULL — ключ не долговой или
  /// долг не живой (см. живой прецедент D-87: мягко удалённый владелец
  /// импорту вложения не препятствует).
  Future<Debt?> _requireAliveDebtOwner(String ownerValue) async {
    final String? debtId = AttachmentOwner.debtOwner(ownerValue);
    if (debtId == null) {
      return null;
    }
    return (select(debts)
          ..where((t) => t.id.equals(debtId) & t.deletedAt.isNull()))
        .getSingleOrNull();
  }

  /// Записывает вложение на владельца-долг (M6/D-82): та же строка
  /// `attachments`, ключ `d:<id>` в той же колонке.
  ///
  /// FK `transaction_id → transactions` не выполняется для нот-фолнера
  /// (пробник шага C: FOREIGN KEY constraint failed при `foreign_keys = ON`;
  /// выключение внутри транзакции — no-op). Живой прецедент записи мимо
  /// FK — импорт бэкапа: окно `PRAGMA foreign_keys = OFF` вокруг одной
  /// вставки, **вне** [DatabaseAccessor.transaction]. Отказ посреди
  /// невозможен: проверки (владелец, MIME, размер, дубликат «один живой»)
  /// выше — сам INSERT упасть уже не может, ошибку FK сюда сознательно не
  /// глушим.
  Future<Attachment> createForDebt({
    required String debtId,
    required String filePath,
    required String mimeType,
    required int fileSize,
  }) async {
    _ensureFileMeta(mimeType: mimeType, filePath: filePath, fileSize: fileSize);
    final Debt? debt = await _requireAliveDebtOwner(
      AttachmentOwner.debt(debtId),
    );
    if (debt == null) {
      throw DataValidationException(
        'долг $debtId не найден',
        kind: DataFailure.notFound,
      );
    }
    final DateTime now = clock();
    // Правило «один живой файл на владельца» (D-63): прежнее вложение
    // мягко удаляется — замена, как у операций.
    await _replaceExisting(await findByDebt(debt.id), now: now);
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await into(attachments).insert(
        AttachmentsCompanion.insert(
          id: idGenerator(),
          transactionId: AttachmentOwner.debt(debt.id),
          filePath: filePath,
          mimeType: mimeType,
          fileSize: fileSize,
          createdAt: now,
          updatedAt: now,
        ),
      );
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
    return (select(attachments)..where(
          (t) =>
              t.transactionId.equals(AttachmentOwner.debt(debt.id)) &
              t.deletedAt.isNull(),
        ))
        .getSingle();
  }

  /// Проверки метаданных файла, общие для [create] и [createForDebt]
  /// (D-96): MIME-белый список, размер, непустой путь — последняя линия
  /// защиты DAO за проверкой в сервисе вложений (D-63). Тексты отказов
  /// и порядок проверок — прежние (поведение не меняется).
  void _ensureFileMeta({
    required String mimeType,
    required String filePath,
    required int fileSize,
  }) {
    if (!AttachmentsStorageRules.isMimeTypeAllowed(mimeType)) {
      throw DataValidationException(
        'mime-тип «$mimeType» вне белого списка вложений '
        '(image/*, application/pdf)',
        kind: DataFailure.invalidInput,
      );
    }
    if (fileSize <= 0 || fileSize > AttachmentsStorageRules.maxFileSizeBytes) {
      throw DataValidationException(
        'размер вложения $fileSize вне допустимого диапазона '
        '(лимит ${AttachmentsStorageRules.maxFileSizeBytes} байт)',
        kind: DataFailure.invalidInput,
      );
    }
    if (filePath.trim().isEmpty) {
      throw DataValidationException(
        'путь файла вложения пуст',
        kind: DataFailure.invalidInput,
      );
    }
  }

  /// Замена прежнего живого вложения владельца (правило «один живой файл»,
  /// D-63; сводка дублей — D-96): прежняя запись уходит в soft delete.
  Future<void> _replaceExisting(
    Attachment? existing, {
    required DateTime now,
  }) async {
    if (existing == null) {
      return;
    }
    await (update(attachments)..where((t) => t.id.equals(existing.id))).write(
      AttachmentsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }
}

/// Константы правил вложений (D-63), доступные DAO без импорта сервиса
/// файлов: белый список MIME и лимит размера. Единый источник —
/// `AttachmentsStorage` (`data/attachments_storage.dart`); здесь —
/// перенаправление, чтобы слой DAO не зависел от dart:io.
abstract final class AttachmentsStorageRules {
  /// Лимит размера файла вложения — константа, не настройка (D-63).
  static const int maxFileSizeBytes = AttachmentsStorage.maxFileSizeBytes;

  /// Белый список MIME: image/* или application/pdf (D-63).
  static bool isMimeTypeAllowed(String mimeType) =>
      AttachmentsStorage.isMimeTypeAllowed(mimeType);
}
