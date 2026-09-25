import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/export/backup_codec.dart';
import 'package:kopilka/data/export/backup_service.dart';
import 'package:kopilka/data/providers.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Исход операции настроек, доведённый до конца: что показать пользователю.
///
/// Тексты подбирает экран по вариантам; отказы машиночитаемы
/// ([BackupFailure]) и локализуются там же.
sealed class SettingsOutcome {
  const SettingsOutcome();
}

/// Пользователь отменил диалог выбора файла/каталога.
class SettingsCancelled extends SettingsOutcome {
  const SettingsCancelled();
}

/// Бэкап восстановлен: показать «Бэкап восстановлен».
class SettingsImported extends SettingsOutcome {
  const SettingsImported();
}

/// Файл сохранён и отправлен через системный share-диалог.
class SettingsFileSaved extends SettingsOutcome {
  const SettingsFileSaved({required this.path});

  final String path;
}

/// Отказ операции: машиночитаемый вид для локализованного текста.
class SettingsFailure extends SettingsOutcome {
  const SettingsFailure(this.failure);

  final BackupFailure failure;
}

/// Хранилище выбранного каталога автобэкапа: одна строка пути в файле
/// каталога поддержки приложения.
///
/// Файл, а не новая зависимость: схему БД менять нельзя без миграции
/// (правило эпох), а path_provider уже есть. Каталог подменяется в тестах.
class AutoBackupDirectoryStore {
  AutoBackupDirectoryStore({required this.baseDirectory});

  /// Каталог, в котором лежит файл настроек (в тестах — временный).
  final Directory baseDirectory;

  File get _file =>
      File(p.join(baseDirectory.path, 'autobackup-directory.txt'));

  /// Прочитать сохранённый путь; '' — каталог не выбран.
  Future<String> read() async {
    try {
      if (!await _file.exists()) {
        return '';
      }
      return (await _file.readAsString()).trim();
    } on IOException {
      return '';
    }
  }

  /// Сохранить путь ('' = отключить автобэкап).
  Future<void> write(String directoryPath) async {
    try {
      if (directoryPath.isEmpty) {
        if (await _file.exists()) {
          await _file.delete();
        }
        return;
      }
      await _file.writeAsString(directoryPath, flush: true);
    } on IOException {
      // Не критично: автобэкап просто не сохранится между запусками.
    }
  }
}

/// Провайдер хранилища каталога; файл — в каталоге поддержки приложения.
final autoBackupDirectoryStoreProvider = Provider<AutoBackupDirectoryStore>(
  (ref) {
    throw UnimplementedError(
      'создаётся в main после открытия БД: AutoBackupDirectoryStore(baseDirectory: getApplicationSupportDirectory())',
    );
  },
);

/// Выбранный каталог автобэкапа в состоянии ('' = не выбран).
final autoBackupDirectoryProvider =
    NotifierProvider<AutoBackupDirectoryController, String>(
  AutoBackupDirectoryController.new,
);

class AutoBackupDirectoryController extends Notifier<String> {
  @override
  String build() => '';

  /// Загружает сохранённый путь (вызывается экраном при старте).
  Future<void> load() async {
    state = await ref.read(autoBackupDirectoryStoreProvider).read();
  }

  Future<void> setDirectory(String path) async {
    await ref.read(autoBackupDirectoryStoreProvider).write(path);
    state = path;
  }
}

/// Контроллер экрана «Настройки»: экспорт/импорт/CSV/автобэкап через
/// [BackupService]; нативные диалоги — [FilePicker], отправка файла —
/// [SharePlus]. UI не обращается к БД напрямую (§2).
class SettingsController extends Notifier {
  @override
  void build() {}

  BackupService get _service =>
      BackupService(ref.watch(appDatabaseProvider));

  static String _stamp() => DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '-');

  /// Диалог выбора каталога; возвращает выбранный путь или null.
  Future<String?> pickDirectory() => FilePicker.getDirectoryPath();

  /// Экспорт JSON-бэкапа: диалог «куда сохранить», запись файла и его
  /// отправка через share-диалог (файл уходит пользователю сам).
  Future<SettingsOutcome> exportJson() async {
    final String? directory = await FilePicker.getDirectoryPath();
    if (directory == null) {
      return const SettingsCancelled();
    }
    try {
      final String json = await _service.exportJson();
      final File file = File(p.join(
        directory,
        'kopilka-backup-${_stamp()}.json',
      ));
      await file.writeAsString(json, flush: true);
      await _share(file);
      return SettingsFileSaved(path: file.path);
    } on IOException {
      return const SettingsFailure(BackupFailure.invalidFormat);
    }
  }

  /// Импорт: выбор файла JSON; валидацию выполняет сервис. Экран обязан
  /// предупредить о замене данных ДО вызова этого метода.
  Future<SettingsOutcome> importJson() async {
    final PlatformFile? picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
    );
    if (picked == null || picked.path == null) {
      return const SettingsCancelled();
    }
    try {
      final String json = await File(picked.path!).readAsString();
      await _service.importJson(json);
      return const SettingsImported();
    } on BackupValidationException catch (error) {
      return SettingsFailure(error.kind);
    }
  }

  /// CSV-экспорт живых операций + share.
  Future<SettingsOutcome> exportCsv() async {
    final String? directory = await FilePicker.getDirectoryPath();
    if (directory == null) {
      return const SettingsCancelled();
    }
    try {
      final String csv = await _service.exportTransactionsCsv();
      final File file = File(p.join(
        directory,
        'kopilka-transactions-${_stamp()}.csv',
      ));
      await file.writeAsString(csv, flush: true);
      await _share(file);
      return SettingsFileSaved(path: file.path);
    } on IOException {
      return const SettingsFailure(BackupFailure.invalidFormat);
    }
  }

  /// Автобэкап сейчас в выбранный каталог; каталог не выбран — null.
  Future<AutoBackupResult?> runAutoBackupNow() async {
    final String path = ref.read(autoBackupDirectoryProvider);
    if (path.isEmpty) {
      return null;
    }
    return _service.runAutoBackup(Directory(path));
  }

  Future<void> _share(File file) async {
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(file.path)]),
    );
  }
}

final settingsControllerProvider =
    NotifierProvider<SettingsController, void>(SettingsController.new);

/// Автобэкап при запуске приложения (§4): каталог читается из
/// [AutoBackupDirectoryStore], результат игнорируется тихо — запуск не
/// должен зависеть от доступности файловой системы. Вызывается из `main`.
Future<void> runAutoBackupOnLaunch({
  required AutoBackupDirectoryStore store,
  required AppDatabase db,
  Clock? clock,
}) async {
  try {
    final String path = await store.read();
    if (path.isEmpty) {
      return;
    }
    await BackupService(db, clock: clock ?? utcNow)
        .runAutoBackup(Directory(path));
  } on IOException {
    // Тихо: автобэкап не критичен для запуска (§4).
  }
}

/// Декодирует JSON-документ бэкапа; нужен тестам, чтобы работать со строкой
/// так же, как контроллер.
Map<String, dynamic> decodeDocument(String json) =>
    jsonDecode(json) as Map<String, dynamic>;
