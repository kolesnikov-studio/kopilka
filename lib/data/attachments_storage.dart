import 'dart:io';
import 'dart:math';

import 'package:kopilka/core/errors.dart';
import 'package:path/path.dart' as p;

/// Хранилище файлов вложений (v6, D-63): файлы живут вне БД, в каталоге
/// `attachments/` рядом с `kopilka.sqlite`. Запись — атомарная: сначала во
/// временный файл в том же каталоге, затем rename на имя `<uuid>.<ext>`
/// (id = имя файла; после записи имя не меняется). Любой отказ файловой
/// системы — машиночитаемый `DataValidationException` с видом
/// [DataFailure.storageFailure]: решение «операция создаётся без вложения»
/// принимает вызывающий код, хранилище отказ не глушит.
///
/// Без новых зависимостей (фаза 1, D-63): расширение и MIME — чистые
/// функции этого файла.
class AttachmentsStorage {
  AttachmentsStorage({required this.rootDirectory, Random? random})
    : _random = random ?? Random.secure();

  /// Каталог вложений: `attachments/` рядом с `kopilka.sqlite` (D-63).
  final Directory rootDirectory;

  /// Источник имён временных файлов записи.
  final Random _random;

  /// Лимит размера файла — константа, не настройка (D-63): ~10 МБ.
  /// Контролируется вызывающим кодом (сервисом вложений), хранилище пишет
  /// то, что ему дали.
  static const int maxFileSizeBytes = 10 * 1024 * 1024;

  /// MIME → расширение имени файла (нижний регистр, с точкой). Расширение
  /// обязано однозначно восстанавливаться из MIME, поэтому список
  /// изображений конечен — «image/*» без конкретного подтипа сюда не
  /// попадает и в записи отвергается.
  static const Map<String, String> _extensionByMime = <String, String>{
    'application/pdf': '.pdf',
    'image/jpeg': '.jpg',
    'image/png': '.png',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/heic': '.heic',
    'image/heif': '.heif',
  };

  /// Белый список D-63 дословно: MIME из `image/*` или ровно
  /// `application/pdf`. Двухступенчатая проверка: сначала белый список
  /// (широкий, для валидации данных из бэкапа и UI), затем карта расширений
  /// (узкая, для записи файла) — см. [extensionForMimeType].
  static bool isMimeTypeAllowed(String mimeType) {
    final String normalized = mimeType.trim().toLowerCase();
    return normalized == 'application/pdf' || normalized.startsWith('image/');
  }

  /// Расширение файла по MIME из карты выше; тип вне белого списка или
  /// generic `image/*` без конкретного подтипа — null.
  static String? extensionForMimeType(String mimeType) =>
      _extensionByMime[mimeType.trim().toLowerCase()];

  /// MIME по расширению имени файла (обратная карта [_extensionByMime]);
  /// неизвестное расширение — null.
  static String? mimeTypeForFileName(String fileName) {
    final String extension = p.extension(fileName).toLowerCase();
    for (final MapEntry<String, String> entry in _extensionByMime.entries) {
      if (entry.value == extension) {
        return entry.key;
      }
    }
    return null;
  }

  /// Записывает байты вложения атомарно (tmp + rename) и возвращает имя
  /// файла `<id><расширение>`. MIME вне белого списка — отказ
  /// [DataFailure.invalidInput] до касания файловой системы. Отказ ФС на
  /// любом шаге (каталог не создать, tmp не записать, rename не удался) —
  /// [DataFailure.storageFailure]; временный файл при этом убирается.
  Future<String> writeAtomically({
    required String id,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final String? extension = extensionForMimeType(mimeType);
    if (extension == null) {
      throw DataValidationException(
        'mime-тип «$mimeType» вне белого списка вложений '
        '(image/*, application/pdf)',
        kind: DataFailure.invalidInput,
      );
    }
    try {
      await rootDirectory.create(recursive: true);
      // Имена tmp-файлов с префиксом «tmp-» не пересекаются с именами
      // вложений (id — UUID, имена `<uuid>.<ext>`).
      final File tmp = File(
        p.join(rootDirectory.path, 'tmp-${_random.nextInt(0x7fffffff)}'),
      );
      try {
        await tmp.writeAsBytes(bytes, flush: true);
        // rename поверх существующего имени заменяет файл (dart:io) —
        // содержимое меняется атомарно, имя постоянно (D-63).
        await tmp.rename(p.join(rootDirectory.path, '$id$extension'));
      } on Exception {
        // rename не удался — tmp остался; убираем, чтобы не копить мусор.
        try {
          if (await tmp.exists()) {
            await tmp.delete();
          }
        } on IOException {
          // Не сумели убрать tmp — первая ошибка важнее.
        }
        rethrow;
      }
      return '$id$extension';
    } on IOException {
      throw DataValidationException(
        'каталог вложений недоступен для записи: ${rootDirectory.path}',
        kind: DataFailure.storageFailure,
      );
    }
  }

  /// Удаляет файл по относительному имени (как в `attachments.file_path`).
  /// Отсутствующий файл — не отказ (после сбоя или ручной чистки запись
  /// должна удаляться, а не застревать); путь, занятый не файлом (каталог),
  /// и любой другой отказ ФС — [DataFailure.storageFailure].
  Future<void> deleteFile(String fileName) async {
    try {
      final String path = p.join(rootDirectory.path, fileName);
      // File.exists() различает тип: для каталога и «нет пути» он false,
      // поэтому тип пути смотрим отдельно — занятое не файлом имя не
      // должно тихо пропускаться.
      final FileSystemEntityType type = await FileSystemEntity.type(path);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      await File(path).delete();
    } on IOException {
      throw DataValidationException(
        'файл вложения не удаётся удалить: $fileName',
        kind: DataFailure.storageFailure,
      );
    }
  }
}
