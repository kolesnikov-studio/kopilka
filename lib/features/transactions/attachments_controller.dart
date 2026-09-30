import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/attachments_service.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:path/path.dart' as p;

/// Шов файлового I/O UI вложений: чтение байтов выбранного файла и
/// проверка существования файла вложения на диске (карточка/просмотр).
/// Отдельно от [FilePicker] и хранилища 6а ради виджет-тестов: пикер и
/// проверки подменяются фейками без реального I/O — в тестовой зоне
/// (fake_async, §7) файловые операции не завершаются.
abstract class AttachmentsIo {
  Future<Uint8List> readBytes(String path);

  Future<bool> exists(String path);
}

class AttachmentsIoDisk implements AttachmentsIo {
  const AttachmentsIoDisk();

  @override
  Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  @override
  Future<bool> exists(String path) => File(path).exists();
}

final attachmentsIoProvider = Provider<AttachmentsIo>(
  (ref) => const AttachmentsIoDisk(),
);

/// Исход шага выбора файла для вложения.
sealed class AttachmentPickOutcome {
  const AttachmentPickOutcome();
}

/// Пользователь отменил диалог выбора файла.
class AttachmentPickCancelled extends AttachmentPickOutcome {
  const AttachmentPickCancelled();
}

/// Файл не подходит для вложения (не читается или mime не определяется
/// по имени файла).
class AttachmentPickRejected extends AttachmentPickOutcome {
  const AttachmentPickRejected(this.failure);

  final DataFailure failure;
}

/// Файл больше лимита вложения (10 МБ, D-63) — отклоняется сразу, до
/// диалога подтверждения: сервис всё равно отверг бы его при записи.
class AttachPickTooLarge extends AttachmentPickOutcome {
  const AttachPickTooLarge(this.maxFileSizeBytes);

  final int maxFileSizeBytes;
}

/// Файл выбран и прочитан: готов к записи сервисом вложений.
class AttachmentPickLoaded extends AttachmentPickOutcome {
  const AttachmentPickLoaded(this.fileName, this.bytes, this.mimeType);

  /// Имя файла, как его вернул пикер (отображается в UI при отказе записи).
  final String fileName;

  /// Байты файла (лимит размера проверит сервис вложений до записи).
  final Uint8List bytes;

  /// MIME по расширению имени файла (карта хранилища, D-63).
  final String mimeType;
}

/// Исход прикрепления: что показать пользователю.
/// Образец — исходы импорта CSV: отказы машиночитаемы, тексты подбирает UI.
sealed class AttachOutcome {
  const AttachOutcome();
}

/// Файл прикреплён (впервые или замена прежнего).
class AttachSucceeded extends AttachOutcome {
  const AttachSucceeded(this.attachment);

  final Attachment attachment;
}

/// Отказ слоя данных (лимит размера, mime, storageFailure) — машиночитаемый
/// вид для локализованного текста UI.
class AttachFailed extends AttachOutcome {
  const AttachFailed(this.failure);

  final DataFailure failure;
}

/// Исход удаления вложения.
sealed class DeleteOutcome {
  const DeleteOutcome();
}

/// Вложение удалено (запись мягко удалена, файл убран с диска).
class DeleteSucceeded extends DeleteOutcome {
  const DeleteSucceeded();
}

/// Отказ слоя данных (вложение не найдено или ФС недоступна).
class DeleteFailed extends DeleteOutcome {
  const DeleteFailed(this.failure);

  final DataFailure failure;
}

/// Контроллер вложений к операции (M5-шаг 6в, D-63): выбор файла пикером →
/// `AttachmentsService.attach`, удаление с подтверждением — UI → `delete`.
/// Слой данных (репозиторий/DAO/хранилище) не меняется — только вызовы.
/// Отказы слоя — Result-исходы, UI без try/catch (§2).
class AttachmentsController extends Notifier {
  @override
  void build() {
    // Состояния у контроллера нет: исходы возвращаются методами,
    // живое вложение операции — watch-провайдеры ниже.
  }

  /// Лимит размера вложения для подсказок подтверждения (10 МБ, D-63).
  static int get maxFileSizeBytes => AttachmentsStorage.maxFileSizeBytes;
  AttachmentsService get _service => ref.read(attachmentsServiceProvider);

  /// Выбор файла пикером (image/* и PDF, фильтр расширений) и чтение
  /// байтов. Выбор отделён от записи: UI показывает подтверждение и
  /// вызывает [attachSelected] отдельно; в тестах шов пикера подменяется.
  ///
  /// MIME определяется по расширению имени файла — карта хранилища
  /// (`mimeTypeForFileName`) едина со списком записи: файл с расширением
  /// вне карты («bmp», «tiff») отклоняется сразу, до диалога подтверждения,
  /// — он всё равно был бы отвергнут при записи.
  ///
  /// Файловый I/O выполняется через шов [attachmentsIoProvider] (по
  /// образцу csv-контроллера, где чтение файла отдаётся платформенному
  /// шову): в живом приложении это чтение с диска, в виджет-тестах —
  /// платформенный шов FilePicker отдаёт уже готовые байты (грабли
  /// fake_async: реальное чтение внутри тестовой зоны не завершается).
  Future<AttachmentPickOutcome> pickFile() async {
    final PlatformFile? picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: <String>[
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic',
        'heif',
        'pdf',
      ],
    );
    if (picked == null || picked.path == null) {
      return const AttachmentPickCancelled();
    }
    final String? mimeType =
        AttachmentsStorage.mimeTypeForFileName(picked.path!);
    if (mimeType == null) {
      return const AttachmentPickRejected(DataFailure.invalidInput);
    }
    // Размер смотрим ДО чтения файла целиком: и в отказе, и в подсказке
    // подтверждения размер нужен в человекочитаемом виде.
    final int? size = await picked.length();
    final int limit = AttachmentsStorage.maxFileSizeBytes;
    if (size == null || size > limit) {
      return AttachPickTooLarge(limit);
    }
    final Uint8List bytes;
    try {
      bytes = await ref.read(attachmentsIoProvider).readBytes(picked.path!);
    } on IOException {
      return const AttachmentPickRejected(DataFailure.storageFailure);
    }
    return AttachmentPickLoaded(picked.name, bytes, mimeType);
  }

  /// Записывает выбранное вложение на владельца (M6/D-82): операцию или
  /// долг. Замена прежнего — правило «один живой файл на владельца»
  /// внутри DAO/сервиса (D-63); отказ ФС не задевает ни владельца, ни
  /// прежнее вложение.
  Future<AttachOutcome> attachSelected({
    required String transactionId,
    required Uint8List bytes,
    required String mimeType,
  }) =>
      attachToOwnerKind(
        owner: AttachmentOwnerKind.transaction,
        ownerId: transactionId,
        bytes: bytes,
        mimeType: mimeType,
      );

  /// Записывает выбранное вложение на владельца-долг (M6/D-82) — образец
  /// [attachSelected]; см. [AttachmentOwnerKind.debt].
  Future<AttachOutcome> attachToDebt({
    required String debtId,
    required Uint8List bytes,
    required String mimeType,
  }) =>
      attachToOwnerKind(
        owner: AttachmentOwnerKind.debt,
        ownerId: debtId,
        bytes: bytes,
        mimeType: mimeType,
      );

  /// Единый путь исходов записи на владельца (M6/D-82): отказы слоя —
  /// [AttachFailed] с машиночитаемым видом (§2).
  Future<AttachOutcome> attachToOwnerKind({
    required AttachmentOwnerKind owner,
    required String ownerId,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    try {
      final Attachment attachment = await _service.attachToOwner(
        owner: owner,
        ownerId: ownerId,
        mimeType: mimeType,
        bytes: bytes,
      );
      return AttachSucceeded(attachment);
    } on DataValidationException catch (error) {
      return AttachFailed(error.kind);
    }
  }

  /// Удаляет вложение (запись мягко, файл с диска). Отказ ФС на удалении
  /// файла не задевает запись: живого вложения операция уже не видит.
  Future<DeleteOutcome> delete(String attachmentId) async {
    try {
      await _service.delete(attachmentId);
      return const DeleteSucceeded();
    } on DataValidationException catch (error) {
      return DeleteFailed(error.kind);
    }
  }
}

final attachmentsControllerProvider =
    NotifierProvider<AttachmentsController, void>(
  AttachmentsController.new,
);

/// Всё, что нужно карточке вложения: живая запись и признак «файл есть
/// на диске». Проверка файла — здесь, а не в build виджета: бриф требует
/// показывать восстановленное бэкапом вложение без падения (D-64),
/// и I/O в состоянии провайдера проще подменять в тестах, чем в дереве.
class AttachmentViewData {
  const AttachmentViewData({required this.attachment, required this.fileExists});

  final Attachment attachment;

  /// Файл есть на диске. false — метаданные без файла (норма по D-64).
  final bool fileExists;
}

/// Живое вложение владельца (операции или долга, M6/D-82) — или NULL:
/// читается через сервис из DAO (`findByTransaction`/`findByDebt`, бриф).
/// Потоков у закрытого слоя данных 6а нет, поэтому провайдер перечитывается
/// вызовом [Ref.invalidate] после успешного attach/delete (контроллер не
/// может это сделать сам — исходы возвращаются вызывающему UI).
final ownerAttachmentProvider = FutureProvider.autoDispose
    .family<AttachmentViewData?, (AttachmentOwnerKind, String)>(
  (ref, owner) async {
    final (AttachmentOwnerKind kind, String ownerId) = owner;
    final AttachmentsService service = ref.watch(attachmentsServiceProvider);
    final Attachment? attachment = kind == AttachmentOwnerKind.debt
        ? await service.findForDebt(ownerId)
        : await service.findForTransaction(ownerId);
    if (attachment == null) {
      return null;
    }
    final String path =
        p.join(service.directory.path, attachment.filePath);
    return AttachmentViewData(
      attachment: attachment,
      // Проверка файла — через шов I/O: в виджет-тестах фейк отвечает
      // без реальной файловой системы (§7), в живом приложении — диск.
      fileExists: await ref.watch(attachmentsIoProvider).exists(path),
    );
  },
);

/// Размер в человекочитаемом виде для подсказок подтверждения и отказа:
/// меньше мегабайта — целые килобайты, дальше — мегабайты с одним знаком
/// («977 KB», «12,3 MB»). Единицы KB/MB не локализуются (общеприняты),
/// разделитель — по локали.
String formatAttachmentSize(int bytes, {String? locale}) {
  const int mb = 1024 * 1024;
  final NumberFormat format = NumberFormat.decimalPattern(locale);
  if (bytes < mb) {
    return '${format.format((bytes / 1024).ceil())} KB';
  }
  return '${format.format(bytes / mb)} MB';
}
