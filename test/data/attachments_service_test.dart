// Тесты сервиса вложений (M5-шаг 6а, D-63): правило «операция создаётся
// без вложения при отказе ФС», замена прежнего вложения с удалением
// старого файла, удаление = soft delete записи + удаление файла.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/attachments_service.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'db/dao/dao_test_utils.dart';

void main() {
  late DataLayerFixture f;
  late Directory tempDir;
  late AttachmentsStorage storage;
  late AttachmentsService service;

  setUp(() async {
    f = DataLayerFixture();
    tempDir = await Directory.systemTemp.createTemp('kopilka_att_service');
    storage = AttachmentsStorage(rootDirectory: tempDir);
    service = AttachmentsService(
      storage,
      f.attachments,
      idGenerator: sequentialIds('file'),
    );
  });

  tearDown(() async {
    await f.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<Transaction> seedTransaction() async {
    await f.ensureRub();
    final Account account = await f.seedAccount();
    return f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      amountMinor: 100000,
    );
  }

  File attachmentFile(String name) =>
      File('${tempDir.path}${Platform.pathSeparator}$name');

  group('attach (файл + запись БД)', () {
    test('успех: файл на диске и живая запись с путём файла', () async {
      final Transaction tx = await seedTransaction();

      final Attachment att = await service.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: <int>[1, 2, 3],
      );

      expect(att.filePath, 'file-1.png');
      expect(att.fileSize, 3);
      expect(att.mimeType, 'image/png');
      expect(await attachmentFile('file-1.png').readAsBytes(), <int>[1, 2, 3]);
      expect(await f.attachments.findByTransaction(tx.id), att);
    });

    test('превышение лимита-константы — invalidInput до записи файла',
        () async {
      final Transaction tx = await seedTransaction();

      await expectLater(
        service.attach(
          transactionId: tx.id,
          mimeType: 'image/png',
          bytes: List<int>.filled(AttachmentsStorage.maxFileSizeBytes + 1, 0),
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

    test('отказ ФС — storageFailure; БД не тронута, tmp убран (D-63)',
        () async {
      final Transaction tx = await seedTransaction();
      final File blocker = File('${tempDir.path}${Platform.pathSeparator}b');
      await blocker.writeAsString('not a dir');
      final AttachmentsStorage blocked = AttachmentsStorage(
        rootDirectory: Directory(blocker.path),
      );
      final AttachmentsService blockedService = AttachmentsService(
        blocked,
        f.attachments,
        idGenerator: sequentialIds('file'),
      );

      await expectLater(
        blockedService.attach(
          transactionId: tx.id,
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
      // Операция цела, вложения нет: «операция создаётся без вложения».
      expect(await f.transactions.findById(tx.id), isNotNull);
      expect(await f.attachments.findByTransaction(tx.id), isNull);
      expect(await rawRowCount(f.db, 'attachments'), 0);
    });

    test('операция не найдена: файл-сирота убран, БД не тронута', () async {
      await expectLater(
        service.attach(
          transactionId: 'nope',
          mimeType: 'image/png',
          bytes: <int>[1],
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
      expect(tempDir.listSync(), isEmpty);
    });

    test('замена: старый файл удалён с диска, живая запись одна', () async {
      final Transaction tx = await seedTransaction();
      await service.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: <int>[1],
      );
      f.clock.advance(const Duration(minutes: 1));

      final Attachment second = await service.attach(
        transactionId: tx.id,
        mimeType: 'application/pdf',
        bytes: <int>[2, 2],
      );

      expect(second.filePath, 'file-2.pdf');
      expect(await attachmentFile('file-1.png').exists(), isFalse);
      expect(await attachmentFile('file-2.pdf').exists(), isTrue);
      expect(await f.attachments.findByTransaction(tx.id), second);
      expect(await rawRowCount(f.db, 'attachments'), 2);
    });
  });

  group('delete (soft delete записи + удаление файла, D-63)', () {
    test('запись мягко удалена, файл с диска удалён', () async {
      final Transaction tx = await seedTransaction();
      final Attachment att = await service.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: <int>[7],
      );
      f.clock.advance(const Duration(minutes: 1));

      await service.delete(att.id);

      expect(await f.attachments.findById(att.id), isNull);
      expect(await rawRowCount(f.db, 'attachments'), 1);
      expect(await attachmentFile('file-1.png').exists(), isFalse);
    });

    test('файл уже отсутствует — удаление продолжается', () async {
      final Transaction tx = await seedTransaction();
      final Attachment att = await service.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: <int>[7],
      );
      await attachmentFile('file-1.png').delete();

      await service.delete(att.id);

      expect(await f.attachments.findById(att.id), isNull);
    });

    test('живого вложения нет — отказ notFound', () async {
      await expectLater(
        service.delete('nope'),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });
  });

  group('замки приёмки (D-63, чистое состояние при отказе ФС)', () {
    test(
      'замена: отказ ФС на удалении старого файла не задевает новое вложение',
      () async {
        final Transaction tx = await seedTransaction();
        await service.attach(
          transactionId: tx.id,
          mimeType: 'image/png',
          bytes: <int>[1],
        );
        f.clock.advance(const Duration(minutes: 1));

        // Старый файл заменяем каталогом: deleteFile наткнётся на отказ
        // ФС уже после того, как новая запись в БД создана.
        await attachmentFile('file-1.png').delete();
        final Directory fakeOldFile =
            Directory('${tempDir.path}${Platform.pathSeparator}file-1.png');
        await fakeOldFile.create();

        await expectLater(
          service.attach(
            transactionId: tx.id,
            mimeType: 'application/pdf',
            bytes: <int>[2],
          ),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.storageFailure,
            ),
          ),
        );
        final Attachment? second = await service.findForTransaction(tx.id);

        // Замена состоялась: живая запись — новая, файл на месте.
        expect(second, isNotNull);
        expect(second!.filePath, 'file-2.pdf');
        expect(await attachmentFile('file-2.pdf').exists(), isTrue);
      },
    );
  });

  group('findForTransaction', () {
    test('NULL до вложения, вложение после', () async {
      final Transaction tx = await seedTransaction();
      expect(await service.findForTransaction(tx.id), isNull);

      final Attachment att = await service.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: <int>[1],
      );

      expect((await service.findForTransaction(tx.id))?.id, att.id);
    });
  });
}
