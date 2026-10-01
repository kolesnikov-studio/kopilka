// Виджет-тесты контекстного меню плитки операций (M6-шаг D, D-67.в/D-92,
// спека §5): долгое нажатие открывает showModalBottomSheet — «Просмотр
// вложения» только при живых метаданных (row.hasAttachment), удаление —
// прежний поток с подтверждением; без вложения меню из одного пункта.
//
// Тестовая зона §7: шов открытия вложения — openAttachment из секции
// (проверка файла — через attachmentsIoProvider, подменённый харнессом
// на фейк шима; образец attachment_section_test). Сервис вложений —
// фейк с in-memory файлами.
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/attachments_service.dart'
    show AttachmentOwnerKind, AttachmentsService;
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/dao/attachments_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import '../../helpers/app_harness.dart';

const List<int> _pngBytes = <int>[0x89, 0x50, 0x4E, 0x47, 5, 6, 7, 8];

/// Фейковый сервис вложений с in-memory файлами (образец
/// attachment_section_test.dart): тесту нужно живое вложение операции.
class _FakeAttachmentsService extends AttachmentsService {
  _FakeAttachmentsService(this.dao)
    : super(
        AttachmentsStorage(rootDirectory: Directory.systemTemp),
        _UnusedDao(),
      );

  AttachmentsDao? dao;

  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<Attachment> attachToOwner({
    required AttachmentOwnerKind owner,
    required String ownerId,
    required String mimeType,
    required List<int> bytes,
  }) async {
    // Тесты меню — только владелец-операция.
    assert(owner == AttachmentOwnerKind.transaction);
    final AttachmentsDao dao = this.dao!;
    final Attachment created = await dao.create(
      transactionId: ownerId,
      filePath: 'fake-${_seq++}.png',
      mimeType: mimeType,
      fileSize: bytes.length,
    );
    files[created.filePath] = Uint8List.fromList(bytes);
    return created;
  }

  @override
  Future<Attachment?> findForTransaction(String transactionId) =>
      dao!.findByTransaction(transactionId);

  @override
  Directory get directory => Directory('/fake-attachments');

  int _seq = 0;
}

/// Заглушка DAO для конструктора базового класса: фейк перекрывает все
/// методы, работающие с DAO, своими (с реальным DAO из харнесса).
class _UnusedDao extends AttachmentsDao {
  _UnusedDao() : super(AppDatabase.forTesting(NativeDatabase.memory()));
}

/// Счёт и живой расход с суммой 100,00 (кнопка суммы — мишень долгого тапа).
Future<Transaction> _seedExpense(AppHarness app) async {
  final Account account = await app.db.accountsDao.create(
    name: 'Карта',
    kind: AccountKind.card,
    currencyCode: baseCurrencyCode,
  );
  return app.db.transactionsDao.create(
    type: TransactionType.expense,
    accountId: account.id,
    amountMinor: 10000,
  );
}

/// Приложение открывается на вкладке счетов: переключаемся на операции.
Future<void> _openTransactionsTab(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navTransactions).last);
  await tester.pumpAndSettle();
}

void main() {
  Future<(AppHarness, _FakeAttachmentsService)> pump(
    WidgetTester tester,
  ) async {
    final _FakeAttachmentsService service = _FakeAttachmentsService(null);
    final AppHarness app = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
      tempDirPrefix: 'kopilka_tx_menu_test',
      attachmentsService: service,
    );
    // DAO присваиваем после создания БД в харнессе.
    service.dao = app.db.attachmentsDao;
    return (app, service);
  }

  testWidgets(
    'D-67.в(а): у операции с вложением в меню есть «Просмотр вложения»',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) = await pump(tester);
      final Transaction tx = await _seedExpense(app);
      await fake.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: _pngBytes,
      );
      await _openTransactionsTab(tester, app);

      // Долгий тап по плитке открывает меню из двух пунктов.
      await tester.longPress(find.textContaining('100'));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.transactionViewAttachment), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      // Подтверждение удаления сразу не открывается — его вызывает пункт меню.
      expect(find.text(app.l10n.transactionDeleteTitle), findsNothing);
    },
  );

  testWidgets(
    'D-67.в(б): без вложения пункта «Просмотр вложения» нет — меню из одного удаления',
    (WidgetTester tester) async {
      final (AppHarness app, _) = await pump(tester);
      await _seedExpense(app);
      await _openTransactionsTab(tester, app);

      await tester.longPress(find.textContaining('100'));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.transactionViewAttachment), findsNothing);
      expect(find.text(app.l10n.deleteAction), findsOneWidget);
    },
  );

  testWidgets(
    'D-67.в(в): тап пункта открывает шов просмотра — fullscreen-вьюер, меню закрыто',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) = await pump(tester);
      final Transaction tx = await _seedExpense(app);
      await fake.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: _pngBytes,
      );
      await _openTransactionsTab(tester, app);

      await tester.longPress(find.textContaining('100'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.transactionViewAttachment));
      await tester.pumpAndSettle();

      // Шов открытия (openAttachment): фото — fullscreen-вьюер поверх
      // приложения, меню закрыто; файла по пути шима нет — errorBuilder
      // вьюера показывает честный отказ (сценарий отсутствия файла
      // покрыт тестами секции вложения), падения нет.
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'D-67.в(г): регресс — удаление из меню работает как прежний поток',
    (WidgetTester tester) async {
      final (AppHarness app, _) = await pump(tester);
      final Transaction tx = await _seedExpense(app);
      await _openTransactionsTab(tester, app);

      await tester.longPress(find.textContaining('100'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.deleteAction).last);
      await tester.pumpAndSettle();

      // Подтверждение — прежний диалог; подтверждаем — мягкое удаление.
      expect(find.text(app.l10n.transactionDeleteTitle), findsOneWidget);
      await tester.tap(find.text(app.l10n.deleteAction).last);
      await tester.pumpAndSettle();

      expect(
        await app.db.transactionsDao.findById(tx.id),
        isNull,
        reason: 'findById фильтрует мягко удалённые (§3)',
      );
      final List<Transaction> rawRows = await app.db
          .select(app.db.transactions)
          .get();
      expect(rawRows.single.deletedAt, isNotNull);
    },
  );
}
