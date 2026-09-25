// Тесты экрана «Настройки» без платформенных диалогов: хранилище каталога
// автобэкапа (файл в support-dir), тихий запуск автобэкапа из main,
// поведение контроллера при отсутствии каталога.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/export/backup_codec.dart';
import 'package:kopilka/data/export/backup_service.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kopilka_settings_test');
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seedDefaultsIfEmpty(db);
    final AutoBackupDirectoryStore store = AutoBackupDirectoryStore(
      baseDirectory: tempDir,
    );
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        autoBackupDirectoryStoreProvider.overrideWithValue(store),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await tempDir.delete(recursive: true);
  });

  test('хранилище каталога: пусто по умолчанию, сохраняется и читается',
      () async {
    final AutoBackupDirectoryStore store =
        container.read(autoBackupDirectoryStoreProvider);

    expect(await store.read(), '');

    await store.write(p.join(tempDir.path, 'backups'));
    expect(await store.read(), p.join(tempDir.path, 'backups'));

    // Пустая строка отключает автобэкап: файл удаляется.
    await store.write('');
    expect(await store.read(), '');
  });

  test(
      'контроллер каталога: setDirectory пишет в хранилище и состояние, load читает',
      () async {
    final AutoBackupDirectoryController controller = container.read(
      autoBackupDirectoryProvider.notifier,
    );
    expect(container.read(autoBackupDirectoryProvider), '');

    final String path = p.join(tempDir.path, 'auto');
    await controller.setDirectory(path);
    expect(container.read(autoBackupDirectoryProvider), path);

    // Новый экземпляр контроллера (как при перезапуске приложения)
    // загружает сохранённое значение из хранилища.
    final AutoBackupDirectoryController reloaded =
        container.read(autoBackupDirectoryProvider.notifier);
    await reloaded.load();
    expect(container.read(autoBackupDirectoryProvider), path);
  });

  test('runAutoBackupNow без каталога — null и без файлов', () async {
    final AutoBackupResult? result = await container
        .read(settingsControllerProvider.notifier)
        .runAutoBackupNow();
    expect(result, isNull);
  });

  test('runAutoBackupNow создаёт файл в выбранном каталоге', () async {
    final String target = p.join(tempDir.path, 'chosen');
    await container
        .read(autoBackupDirectoryProvider.notifier)
        .setDirectory(target);

    final AutoBackupResult? result = await container
        .read(settingsControllerProvider.notifier)
        .runAutoBackupNow();

    expect(result, isA<AutoBackupCreated>());
    final List<FileSystemEntity> files = await Directory(target).list().toList();
    expect(files, hasLength(1));
    // Файл — корректный бэкап v1: читается кодеком.
    final Map<String, dynamic> document =
        jsonDecode(await File(files.single.path).readAsString())
            as Map<String, dynamic>;
    final DecodedBackup backup = decodeJson(document);
    expect(backup.currencies.single.code, 'RUB');
  });

  test('runAutoBackupOnLaunch: нет каталога — ничего не делает', () async {
    final AutoBackupDirectoryStore store =
        container.read(autoBackupDirectoryStoreProvider);
    await runAutoBackupOnLaunch(store: store, db: db);
    // В каталоге хранилища не появилось ничего, кроме файла настроек.
    expect(await tempDir.list().length, lessThanOrEqualTo(1));
  });

  test('runAutoBackupOnLaunch: с каталогом создаёт бэкап, IOException глотает',
      () async {
    final String target = p.join(tempDir.path, 'launch');
    final AutoBackupDirectoryStore store =
        container.read(autoBackupDirectoryStoreProvider);
    await store.write(target);

    await runAutoBackupOnLaunch(store: store, db: db);

    final List<FileSystemEntity> files = await Directory(target).list().toList();
    expect(files, hasLength(1));
    expect(
      p.basename(files.single.path).startsWith('kopilka-backup-'),
      isTrue,
    );
    expect(p.basename(files.single.path).endsWith('.json'), isTrue);
  });

  test('runAutoBackupOnLaunch: недоступный каталог не роняет запуск',
      () async {
    // Каталог, путь которого конфликтует с файлом, — create(recursive)
    // бросит IOException, функция обязана его поглотить.
    final String blockerPath = p.join(tempDir.path, 'blocker');
    await File(blockerPath).writeAsString('x');
    final AutoBackupDirectoryStore store =
        container.read(autoBackupDirectoryStoreProvider);
    await store.write(p.join(blockerPath, 'inside'));

    // Не бросает.
    await runAutoBackupOnLaunch(store: store, db: db);
  });

  test('decodeDocument парсит строку в Map', () {
    final Map<String, dynamic> document = decodeDocument(
      jsonEncode(<String, dynamic>{'schema_version': 1, 'data': <String, dynamic>{}}),
    );
    expect(document['schema_version'], 1);
  });
}
