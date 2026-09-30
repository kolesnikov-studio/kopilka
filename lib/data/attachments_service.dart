import 'dart:io';

import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/dao/attachments_dao.dart';
import 'package:kopilka/data/db/database.dart';

/// Сервис вложений (v6, D-63): единый метод «запись файла + запись БД».
///
/// Правило D-63: при отказе файловой системы операция **создаётся без
/// вложения**, не падает — «сначала файл, затем БД» (иначе файл был бы
/// потерян до отката записи). Успех — вложение целиком (файл + метаданные),
/// отказ — чистое состояние: хранилище убирает временные файлы, БД не
/// тронута. Замена прежнего вложения (правило DAO «один живой на
/// операцию») удаляет и старый файл.
///
/// Проверка размера — здесь (лимит — константа [AttachmentsStorage.maxFileSizeBytes],
/// не настройка): превышение — [DataValidationException.invalidInput],
/// до касания файловой системы.
class AttachmentsService {
  AttachmentsService(this._storage, this._dao, {IdGenerator? idGenerator})
    : _idGenerator = idGenerator ?? newId;

  final AttachmentsStorage _storage;
  final AttachmentsDao _dao;
  final IdGenerator _idGenerator;

  /// Каталог вложений (для путей просмотра в UI шага 6в).
  Directory get directory => _storage.rootDirectory;

  /// Прикладывает файл к операции: валидация размера → запись файла
  /// (атомарно) → запись БД (правило «один живой на операцию» внутри DAO)
  /// → удаление старого файла, если вложение было заменой.
  /// При отказе ФС пробрасывает [DataFailure.storageFailure] — вызывающий
  /// код обязан продолжить создание операции без вложения (D-63).
  Future<Attachment> attach({
    required String transactionId,
    required String mimeType,
    required List<int> bytes,
  }) async {
    if (bytes.length > AttachmentsStorage.maxFileSizeBytes) {
      throw DataValidationException(
        'файл ${bytes.length} байт превышает лимит вложения '
        '${AttachmentsStorage.maxFileSizeBytes} байт',
        kind: DataFailure.invalidInput,
      );
    }
    // Прежнее вложение читаем до записи: его файл удаляется после
    // успешной замены записи в БД (см. ниже).
    final Attachment? previous = await _dao.findByTransaction(transactionId);
    final String fileName = await _storage.writeAtomically(
      id: _idGenerator(),
      mimeType: mimeType,
      bytes: bytes,
    );
    final Attachment created;
    try {
      created = await _dao.create(
        transactionId: transactionId,
        filePath: fileName,
        mimeType: mimeType,
        fileSize: bytes.length,
      );
    } on Exception {
      // БД-запись не прошла (операция не найдена, MIME не прошёл вторую
      // линию защиты DAO, сбой БД): файл без записи — мусор; убираем и
      // пробрасываем причину дальше.
      await _storage.deleteFile(fileName);
      rethrow;
    }
    // Замена (D-63): старая запись уже мягко удалена правилом DAO,
    // удаляем её файл. Вне try: отказ ФС здесь не должен задевать новый
    // файл — вложение уже заменено, а файл-сирота безвреден (как в
    // [delete]).
    if (previous != null) {
      await _storage.deleteFile(previous.filePath);
    }
    return created;
  }

  /// Живое вложение операции (или NULL).
  Future<Attachment?> findForTransaction(String transactionId) =>
      _dao.findByTransaction(transactionId);

  /// Удаляет вложение: soft delete записи + удаление файла с диска (D-63).
  /// Файл без живой записи — мусор, его потеря не страшна: удаление
  /// продолжается. Отказ ФС при удалении файла — [DataFailure.storageFailure].
  Future<void> delete(String attachmentId) async {
    final Attachment attachment = await _dao.requireAliveById(attachmentId);
    await _dao.softDelete(attachment.id);
    // Файл удаляем последним: при отказе ФС запись уже мягко удалена —
    // состояние «файл-сирота», но UI живое вложение уже не видит.
    await _storage.deleteFile(attachment.filePath);
  }
}
