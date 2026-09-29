import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/attachments_service.dart';

void main() {
  late Directory tempDir;
  late AttachmentsStorage storage;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('kopilka_attachments');
    storage = AttachmentsStorage(rootDirectory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('writeAtomically', () {
    test('пишет файл <uuid>.<ext>, tmp-файлов не остаётся', () async {
      final String fileName = await storage.writeAtomically(
        id: 'att-1',
        mimeType: 'image/png',
        bytes: <int>[1, 2, 3],
      );

      expect(fileName, 'att-1.png');
      final File written = File('${tempDir.path}${Platform.pathSeparator}att-1.png');
      expect(await written.exists(), isTrue);
      expect(await written.readAsBytes(), <int>[1, 2, 3]);
      // Атомарная запись не оставляет временных файлов.
      expect(
        tempDir.listSync().map((FileSystemEntity e) => e.path.endsWith('tmp-')),
        everyElement(isFalse),
      );
    });

    test('повторная запись того же id заменяет содержимое', () async {
      await storage.writeAtomically(
        id: 'att-1',
        mimeType: 'image/png',
        bytes: <int>[1],
      );
      await storage.writeAtomically(
        id: 'att-1',
        mimeType: 'image/png',
        bytes: <int>[9, 9, 9],
      );

      final File written = File('${tempDir.path}${Platform.pathSeparator}att-1.png');
      expect(await written.readAsBytes(), <int>[9, 9, 9]);
      expect(tempDir.listSync(), hasLength(1));
    });

    test('mime вне белого списка — отказ invalidInput до записи', () async {
      await expectLater(
        storage.writeAtomically(
          id: 'att-1',
          mimeType: 'application/zip',
          bytes: <int>[1],
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('каталог не существует — создаётся при записи', () async {
      final Directory nested = Directory(
        '${tempDir.path}${Platform.pathSeparator}nested',
      );
      final AttachmentsStorage fresh = AttachmentsStorage(
        rootDirectory: nested,
      );

      final String fileName = await fresh.writeAtomically(
        id: 'att-2',
        mimeType: 'application/pdf',
        bytes: <int>[5],
      );

      expect(fileName, 'att-2.pdf');
      expect(await File('${nested.path}${Platform.pathSeparator}att-2.pdf').exists(), isTrue);
    });

    test('недоступный каталог — отказ storageFailure (DataFailure, D-63)',
        () async {
      // Файл вместо каталога: create(recursive) поверх файла падает
      // гарантированно на всех платформах.
      final File blocker = File('${tempDir.path}${Platform.pathSeparator}blocker');
      await blocker.writeAsString('not a dir');
      final AttachmentsStorage blocked = AttachmentsStorage(
        rootDirectory: Directory(blocker.path),
      );

      await expectLater(
        blocked.writeAtomically(
          id: 'att-3',
          mimeType: 'image/png',
          bytes: <int>[1],
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.storageFailure,
          ),
        ),
      );
    });

    test('запись поверх файла-блокера: rename не проходит — storageFailure',
        () async {
      // Целевое имя занято каталогом: rename поверх каталога невозможен.
      final Directory target = Directory(
        '${tempDir.path}${Platform.pathSeparator}att-4.png',
      );
      await target.create();
      final File inner = File('${target.path}${Platform.pathSeparator}x');
      await inner.writeAsString('x');

      await expectLater(
        storage.writeAtomically(
          id: 'att-4',
          mimeType: 'image/png',
          bytes: <int>[1],
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.storageFailure,
          ),
        ),
      );
      // tmp-мусор убран, файл-каталог не задет.
      expect(
        tempDir.listSync().where((FileSystemEntity e) =>
            e.path.contains('tmp-')),
        isEmpty,
      );
    });
  });

  group('deleteFile', () {
    test('удаляет файл по имени', () async {
      await storage.writeAtomically(
        id: 'att-1',
        mimeType: 'image/png',
        bytes: <int>[1],
      );

      await storage.deleteFile('att-1.png');

      expect(
        await File('${tempDir.path}${Platform.pathSeparator}att-1.png').exists(),
        isFalse,
      );
    });

    test('отсутствующий файл — не отказ', () async {
      await storage.deleteFile('gone.png');
    });

    test('отказ ФС — storageFailure', () async {
      // Каталог вложений заменён на одноимённый каталог-«блокер» с
      // подкаталогом att-1.png: file.exists() на этом пути видит каталог
      // и file.delete() гарантированно отказывает (каталог непуст).
      final Directory blocker = Directory(
        '${tempDir.path}${Platform.pathSeparator}blocker',
      );
      await Directory(
        '${blocker.path}${Platform.pathSeparator}att-1.png',
      ).create(recursive: true);
      final AttachmentsStorage blocked = AttachmentsStorage(
        rootDirectory: blocker,
      );

      await expectLater(
        blocked.deleteFile('att-1.png'),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.storageFailure,
          ),
        ),
      );
    });
  });

  group('правила mime/расширений (D-63)', () {
    test('белый список: image/* и application/pdf разрешены', () {
      expect(AttachmentsStorage.isMimeTypeAllowed('image/png'), isTrue);
      expect(AttachmentsStorage.isMimeTypeAllowed('image/jpeg'), isTrue);
      expect(AttachmentsStorage.isMimeTypeAllowed('IMAGE/SVG+XML'), isTrue);
      expect(AttachmentsStorage.isMimeTypeAllowed('application/pdf'), isTrue);
      expect(AttachmentsStorage.isMimeTypeAllowed('application/zip'), isFalse);
      expect(AttachmentsStorage.isMimeTypeAllowed('text/plain'), isFalse);
      expect(AttachmentsStorage.isMimeTypeAllowed('video/mp4'), isFalse);
    });

    test('расширение восстанавливается из mime и обратно', () {
      expect(AttachmentsStorage.extensionForMimeType('application/pdf'), '.pdf');
      expect(AttachmentsStorage.extensionForMimeType('image/jpeg'), '.jpg');
      expect(AttachmentsStorage.extensionForMimeType('image/png'), '.png');
      // Generic image/* не даёт расширения — запись отвергается.
      expect(AttachmentsStorage.extensionForMimeType('image/svg+xml'), isNull);
      expect(AttachmentsStorage.mimeTypeForFileName('a.pdf'), 'application/pdf');
      expect(AttachmentsStorage.mimeTypeForFileName('b.jpg'), 'image/jpeg');
      expect(AttachmentsStorage.mimeTypeForFileName('c.bin'), isNull);
    });

    test('лимит размера — константа, не настройка (D-63)', () {
      expect(AttachmentsStorage.maxFileSizeBytes, 10 * 1024 * 1024);
    });
  });
}
