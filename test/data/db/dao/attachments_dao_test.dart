// Тесты DAO вложений (M5-шаг 6а, D-63): правило «один живой файл на
// операцию», white-list MIME, лимит размера, soft delete и _requireAlive —
// по образцу budgets_dao_test. Хранилище файлов здесь не участвует:
// DAO работает только с БД (файл+БД вместе — тесты AttachmentsService).
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;

  setUp(() {
    f = DataLayerFixture();
  });

  tearDown(() => f.dispose());

  Future<Transaction> seedTransaction() async {
    await f.ensureRub();
    final Account account = await f.seedAccount();
    return f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      amountMinor: 100000,
    );
  }

  group('создание', () {
    test('вложение создаётся на живую операцию', () async {
      final Transaction tx = await seedTransaction();
      final Attachment att = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-1.png',
        mimeType: 'image/png',
        fileSize: 1234,
      );

      expect(att.id, 'att-1');
      expect(att.transactionId, tx.id);
      expect(att.filePath, 'att-1.png');
      expect(att.mimeType, 'image/png');
      expect(att.fileSize, 1234);
      expect(att.deletedAt, isNull);
      expect(att.createdAt.toUtc(), f.clock.read());
      expect(att.updatedAt.toUtc(), f.clock.read());
    });

    test('несуществующая операция — отказ notFound', () async {
      await expectLater(
        f.attachments.create(
          transactionId: 'nope',
          filePath: 'att-1.png',
          mimeType: 'image/png',
          fileSize: 1234,
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('мягко удалённая операция — тоже notFound (файл не крепится)',
        () async {
      final Transaction tx = await seedTransaction();
      await f.transactions.softDelete(tx.id);

      await expectLater(
        f.attachments.create(
          transactionId: tx.id,
          filePath: 'att-1.png',
          mimeType: 'image/png',
          fileSize: 1234,
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
    });

    test('mime вне белого списка — отказ invalidInput (D-63)', () async {
      final Transaction tx = await seedTransaction();
      for (final String mime in <String>['application/zip', 'text/plain']) {
        await expectLater(
          f.attachments.create(
            transactionId: tx.id,
            filePath: 'att-1.bin',
            mimeType: mime,
            fileSize: 1234,
          ),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.invalidInput,
            ),
          ),
        );
      }
    });

    test('лимит размера — константа (D-63): 0 и больше лимита — отказ',
        () async {
      final Transaction tx = await seedTransaction();
      for (final int size in <int>[0, -1, 10 * 1024 * 1024 + 1]) {
        await expectLater(
          f.attachments.create(
            transactionId: tx.id,
            filePath: 'att-1.png',
            mimeType: 'image/png',
            fileSize: size,
          ),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.invalidInput,
            ),
          ),
        );
      }
      // Граница включена: ровно лимит проходит.
      final Attachment att = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-big.pdf',
        mimeType: 'application/pdf',
        fileSize: 10 * 1024 * 1024,
      );
      expect(att.fileSize, 10 * 1024 * 1024);
    });

    test('пустой путь файла — отказ invalidInput', () async {
      final Transaction tx = await seedTransaction();
      await expectLater(
        f.attachments.create(
          transactionId: tx.id,
          filePath: '   ',
          mimeType: 'image/png',
          fileSize: 1234,
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
    });
  });

  group('правило «один живой файл на операцию» (D-63)', () {
    test('повторное вложение заменяет прежнее: старая запись soft delete',
        () async {
      final Transaction tx = await seedTransaction();
      final Attachment first = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-1.png',
        mimeType: 'image/png',
        fileSize: 111,
      );
      f.clock.advance(const Duration(minutes: 1));
      final Attachment second = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-2.pdf',
        mimeType: 'application/pdf',
        fileSize: 222,
      );

      final Attachment? alive = await f.attachments.findByTransaction(tx.id);
      expect(alive?.id, second.id);
      expect(alive?.filePath, 'att-2.pdf');
      // Старая запись осталась в таблице, но мягко удалена (§3).
      expect(await rawRowCount(f.db, 'attachments'), 2);
      final Attachment? firstById = await f.attachments.findById(first.id);
      expect(firstById, isNull, reason: 'findById — только живые');
      // Обе записи физически существуют (soft delete).
      final List<Attachment> all = await f.db.select(f.db.attachments).get();
      expect(all, hasLength(2));
      expect(
        all.firstWhere((Attachment a) => a.id == first.id).deletedAt,
        isNotNull,
      );
    });

    test('вложения разных операций не мешают друг другу', () async {
      final Transaction tx1 = await seedTransaction();
      final Transaction tx2 = await seedTransaction();
      await f.attachments.create(
        transactionId: tx1.id,
        filePath: 'att-1.png',
        mimeType: 'image/png',
        fileSize: 111,
      );
      final Attachment second = await f.attachments.create(
        transactionId: tx2.id,
        filePath: 'att-2.png',
        mimeType: 'image/png',
        fileSize: 222,
      );

      expect((await f.attachments.findByTransaction(tx1.id))?.filePath,
          'att-1.png');
      expect((await f.attachments.findByTransaction(tx2.id))?.id, second.id);
    });

    test('после замены мягко удалённое вложение не复活', () async {
      final Transaction tx = await seedTransaction();
      final Attachment first = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-1.png',
        mimeType: 'image/png',
        fileSize: 111,
      );
      await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-2.png',
        mimeType: 'image/png',
        fileSize: 222,
      );
      f.clock.advance(const Duration(minutes: 1));
      await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-3.png',
        mimeType: 'image/png',
        fileSize: 333,
      );

      final List<Attachment> all = await f.db.select(f.db.attachments).get();
      expect(all, hasLength(3));
      final Iterable<Attachment> dead = all.where(
        (Attachment a) => a.id == first.id || a.filePath == 'att-2.png',
      );
      expect(dead, hasLength(2));
      expect(dead.every((Attachment a) => a.deletedAt != null), isTrue);
      expect((await f.attachments.findByTransaction(tx.id))?.filePath,
          'att-3.png');
    });
  });

  group('чтение и удаление', () {
    test('findById / findByTransaction: NULL для отсутствующего', () async {
      expect(await f.attachments.findById('nope'), isNull);
      expect(await f.attachments.findByTransaction('nope'), isNull);
    });

    test('soft delete помечает запись, строка остаётся (§3)', () async {
      final Transaction tx = await seedTransaction();
      final Attachment att = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-1.png',
        mimeType: 'image/png',
        fileSize: 111,
      );
      f.clock.advance(const Duration(minutes: 1));

      await f.attachments.softDelete(att.id);

      expect(await f.attachments.findById(att.id), isNull);
      expect(await f.attachments.findByTransaction(tx.id), isNull);
      expect(await rawRowCount(f.db, 'attachments'), 1);
      final List<Attachment> all = await f.db.select(f.db.attachments).get();
      expect(all.single.deletedAt?.toUtc(), f.clock.read());
      expect(all.single.updatedAt.toUtc(), f.clock.read());
    });

    test('повторный soft delete / чужой id — отказ notFound (_requireAlive)',
        () async {
      final Transaction tx = await seedTransaction();
      final Attachment att = await f.attachments.create(
        transactionId: tx.id,
        filePath: 'att-1.png',
        mimeType: 'image/png',
        fileSize: 111,
      );
      await f.attachments.softDelete(att.id);

      await expectLater(
        f.attachments.softDelete(att.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
      await expectLater(
        f.attachments.softDelete('nope'),
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
}
