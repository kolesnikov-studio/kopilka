// Шов FilePicker для виджет-тестов, где нужен настоящий
// [CsvImportController.pickDraft] (замки T-1/Dz-2): в тестах нативный
// пикер недоступен, платформенный шов подменяется фейком, как у других
// platform-интерфейсов Flutter. Класс [FakePlatformFile] живёт здесь,
// потому что файл-результат пикера больше нигде в проекте не строится.
//
// Грабли fake_async: сеттап теста заранее читает байты файла в реальном
// I/O (tester.runAsync), фейк-пикер только возвращает их — никаких
// файловых операций внутри pumpWidget и тестового тела.
//
// M5-шаг 6в: тот же файл отдаёт [FakeAttachmentsIo] — шов I/O контроллера
// вложений (lib/features/transactions/attachments_controller.dart), чтобы
// чтение байтов выбранного файла не падало в fake_async.
import 'dart:async';
import 'dart:io' show FileSystemException;
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:kopilka/features/transactions/attachments_controller.dart';

/// Файл, «выбранный» пикером: только то, что читает pickDraft (path).
final class FakePlatformFile extends PlatformFile {
  FakePlatformFile.file(this.filePath, this.bytes);

  final String filePath;

  final Uint8List bytes;

  @override
  String? get path => filePath;

  @override
  String get name => Uri.file(filePath).pathSegments.last;

  @override
  Uri get uri => Uri.file(filePath);

  @override
  XFile get xFile => XFile.fromData(bytes, name: name);

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream<Uint8List>.value(bytes);
}

/// Счётчик вызовов фейк-пикера (диагностика тестов).
int fakeFilePickerCalls = 0;

/// Подменяет платформенный шов FilePicker на фейк: следующий
/// [FilePicker.pickFile] вернёт файл [path] с байтами [bytes]
/// (path или bytes null — отмена выбора).
void installFilePickerShim({String? path, List<int>? bytes}) {
  fakeFilePickerCalls = 0;
  _lastPath = path;
  shimBytes = bytes;
  FilePickerPlatform.instance = _FakeFilePickerPlatform(path, bytes);
}

/// Восстанавливает шов по умолчанию (addTearDown в тесте).
void restoreFilePickerPlatform() {
  FilePickerPlatform.instance = MethodChannelFilePicker();
}

/// Шов I/O выбора вложений: отдаёт байты, заданные в
/// [installFilePickerShim], без чтения с диска (реальное чтение внутри
/// тестовой fake_async-зоны не завершается — грабли §7).
class FakeAttachmentsIo implements AttachmentsIo {
  const FakeAttachmentsIo();

  @override
  Future<Uint8List> readBytes(String path) async {
    final List<int>? bytes = shimBytes;
    if (bytes == null) {
      throw const FileSystemException('шейм не задан');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<bool> exists(String path) async =>
      // Сценарий D-64: отсутствие файла при живых метаданных фейк
      // определяет по суффиксу пути — тест с missing-файлом помечает
      // имя файла вложения через [markShimFileMissing].
      !path.endsWith(missingSuffix);
}

/// Суффикс имени файла, для которого фейк отвечает «файла нет».
String missingSuffix = '.never-matches';

/// Байты последнего [installFilePickerShim] — читает [FakeAttachmentsIo].
List<int>? shimBytes;

final class _FakeFilePickerPlatform extends FilePickerPlatform {
  _FakeFilePickerPlatform(this.path, this.bytes);

  final String? path;

  final List<int>? bytes;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    fakeFilePickerCalls++;
    final String? picked = path;
    final List<int>? pickedBytes = bytes;
    if (picked == null || pickedBytes == null) {
      return null;
    }
    return FakePlatformFile.file(picked, Uint8List.fromList(pickedBytes));
  }
}

/// Путь последнего шима — для сообщений об ошибках тестов.
String? get shimPath => _lastPath;

String? _lastPath;
