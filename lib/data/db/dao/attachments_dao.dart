import 'package:drift/drift.dart';

import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/tables.dart';

part 'attachments_dao.g.dart';

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
@DriftAccessor(tables: [Attachments, Transactions])
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
    final Transaction? transaction = await (select(transactions)
          ..where(
            (t) => t.id.equals(transactionId) & t.deletedAt.isNull(),
          ))
        .getSingleOrNull();
    if (transaction == null) {
      throw DataValidationException(
        'операция $transactionId не найдена',
        kind: DataFailure.notFound,
      );
    }
    final DateTime now = clock();
    final String id = idGenerator();
    // Правило «один живой файл на операцию» (D-63): прежнее вложение
    // мягко удаляется — замена, не отказ (образец бюджетов; у бюджета
    // отказ, здесь файл единственный, повторное вложение = замена).
    final Attachment? existing = await findByTransaction(transactionId);
    if (existing != null) {
      await (update(attachments)..where((t) => t.id.equals(existing.id))).write(
        AttachmentsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
    }
    return into(attachments).insertReturning(
      AttachmentsCompanion.insert(
        id: id,
        transactionId: transactionId,
        filePath: filePath,
        mimeType: mimeType,
        fileSize: fileSize,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живое вложение операции (или NULL).
  Future<Attachment?> findByTransaction(String transactionId) =>
      (select(attachments)..where(
            (t) =>
                t.transactionId.equals(transactionId) & t.deletedAt.isNull(),
          ))
          .getSingleOrNull();

  /// Живое вложение по id (или NULL).
  Future<Attachment?> findById(String id) =>
      (select(attachments)..where(
            (t) => t.id.equals(id) & t.deletedAt.isNull(),
          ))
          .getSingleOrNull();

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
    final Attachment? attachment = await (select(attachments)
          ..where((t) => t.id.equals(id) & t.deletedAt.isNull()))
        .getSingleOrNull();
    if (attachment == null) {
      throw DataValidationException(
        'вложение $id не найдено',
        kind: DataFailure.notFound,
      );
    }
    return attachment;
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
