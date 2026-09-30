// Виджет-тесты секции вложения к операции (M5-шаг 6в, D-63/D-64):
// прикрепление файла пикером (шов file_picker_shim), замена (правило
// «один живой файл на операцию»), удаление с подтверждением, отсутствие
// файла на диске (восстановленный бэкап) — без падения, PDF — диалог
// «просмотр недоступен».
//
// Секция строится напрямую над заранее созданной живой операцией —
// тот же виджет, что в диалоге после сохранения (сценарий «диалог
// сохранения остаётся открытым» — в transaction_form_dialog_test.dart
// приёмки). Сервис вложений — фейк с in-memory файлами: реальный
// файловый I/O хранилища/чтения внутри fake_async-зоны не завершается
// (§7); логика отказов фейка повторяет AttachmentsService (лимит до
// записи, storageFailure по флагу), ранние отказы хранилища покрыты
// юнит-тестами слоя 6а. BUSY-замок (D-63): фейк умеет откладывать attach
// (attachGate): повторный тап во время записи не даёт повторную запись.
import 'dart:async';
import 'dart:io';

import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/attachments_service.dart'
    show AttachmentOwnerKind, AttachmentsService;
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/dao/attachments_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/features/transactions/attachment_section.dart';
import 'package:kopilka/features/transactions/attachments_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

import '../../file_picker_shim.dart';
import '../../helpers/app_harness.dart';

const List<int> _pngBytes = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4];
const List<int> _pdfBytes = <int>[0x25, 0x50, 0x44, 0x46, 1, 2];

/// Счёт и живой расход: к нему крепится вложение.
Future<Transaction> _seedTransaction(AppHarness app) async {
  final Account account = await app.db.accountsDao.create(
    name: 'Карта',
    kind: AccountKind.card,
    currencyCode: baseCurrencyCode,
  );
  return app.db.transactionsDao.create(
    type: TransactionType.expense,
    accountId: account.id,
    amountMinor: 100000,
  );
}

/// Публичный тестовый хост: строит секцию на готовой живой операции.
class _AttachmentSectionHost extends StatelessWidget {
  const _AttachmentSectionHost({required this.transactionId});

  final String transactionId;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: AttachmentSection.forTransaction(transactionId),
      );
}

/// Тестовый сервис вложений: логика «файл + БД» с in-memory файлами.
/// Отказы повторяют AttachmentsService: лимит до записи, storageFailure
/// по флагу, замена удаляет прежний файл, delete = soft delete + файл.
class _FakeAttachmentsService extends AttachmentsService {
  _FakeAttachmentsService(this.dao)
      : super(
          AttachmentsStorage(rootDirectory: Directory.systemTemp),
          _UnusedDao(),
        );

  AttachmentsDao? dao;

  final Map<String, Uint8List> files = <String, Uint8List>{};

  bool failStorage = false;

  /// Замок BUSY (D-63): при holdAttach attach замирает до [attachGate];
  /// между вызовом и завершением секция обязана быть занята (кнопки
  /// не активны, второй вызов не проходит). По умолчанию — без гейта.
  bool holdAttach = false;
  final Completer<void> attachGate = Completer<void>();
  int attachCalls = 0;

  @override
  Future<Attachment> attachToOwner({
    required AttachmentOwnerKind owner,
    required String ownerId,
    required String mimeType,
    required List<int> bytes,
  }) async {
    // Тесты секции M5 — только владелец-операция; долги — тесты M6.
    assert(owner == AttachmentOwnerKind.transaction);
    final String transactionId = ownerId;
    final AttachmentsDao dao = this.dao!;
    final int limit = AttachmentsStorage.maxFileSizeBytes;
    attachCalls++;
    if (failStorage) {
      throw DataValidationException(
        'тестовый отказ хранилища',
        kind: DataFailure.storageFailure,
      );
    }
    if (bytes.length > limit) {
      throw DataValidationException(
        'тестовый отказ лимита',
        kind: DataFailure.invalidInput,
      );
    }
    final String? extension =
        AttachmentsStorage.extensionForMimeType(mimeType);
    if (extension == null) {
      throw DataValidationException(
        'тестовый отказ mime',
        kind: DataFailure.invalidInput,
      );
    }
    if (holdAttach && !attachGate.isCompleted) {
      await attachGate.future;
    }
    final Attachment? previous = await dao.findByTransaction(transactionId);
    final Attachment created = await dao.create(
      transactionId: transactionId,
      filePath: 'fake-${_seq++}$extension',
      mimeType: mimeType,
      fileSize: bytes.length,
    );
    files[created.filePath] = Uint8List.fromList(bytes);
    if (previous != null) {
      files.remove(previous.filePath);
    }
    return created;
  }

  @override
  Future<void> delete(String attachmentId) async {
    final AttachmentsDao dao = this.dao!;
    final Attachment attachment = await dao.requireAliveById(attachmentId);
    await dao.softDelete(attachment.id);
    files.remove(attachment.filePath);
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

/// Харнесс с фейковым сервисом вложений: сервис создаётся заранее и
/// передаётся в контейнер при создании (riverpod не даёт менять число
/// оверрайдов после создания).
Future<(AppHarness, _FakeAttachmentsService)> _pumpAppWithFake(
  WidgetTester tester, {
  bool failStorage = false,
}) async {
  final _FakeAttachmentsService service = _FakeAttachmentsService(null)
    ..failStorage = failStorage;
  final AppHarness app = await pumpDialogApp(
    tester,
    size: const Size(600, 1000),
    tempDirPrefix: 'kopilka_attachment_test',
    attachmentsService: service,
  );
  // DAO присваиваем после создания БД в харнессе.
  service.dao = app.db.attachmentsDao;
  return (app, service);
}

Future<void> _pumpSection(
  WidgetTester tester,
  AppHarness app,
  String txId,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: app.container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('ru'),
        home: _AttachmentSectionHost(transactionId: txId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Каталог с готовым файлом; удаляется в демонтаже. Нужен только пикеру:
/// путь читается для mime, байты отдаёт шим.
Future<File> _tempFile(
  WidgetTester tester,
  String name,
  List<int> bytes,
) async {
  final Directory dir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_attachment_pick'),
  ))!;
  addTearDown(() => tester.runAsync(() => dir.delete(recursive: true)));
  final File file = File('${dir.path}${Platform.pathSeparator}$name');
  await tester.runAsync(() => file.writeAsBytes(bytes));
  return file;
}

/// Подтверждает прикрепление в открытом диалоге (кнопка диалога —
/// FilledButton «Прикрепить»; кнопка секции — OutlinedButton).
Future<void> _confirmAttach(WidgetTester tester, AppHarness app) async {
  await tester.tap(
    find.widgetWithText(FilledButton, app.l10n.attachmentPickAction),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'прикрепление: пикер → подтверждение → файл в БД и хранилище фейка',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) =
          await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final File picked = await _tempFile(tester, 'check.png', _pngBytes);
      installFilePickerShim(path: picked.path, bytes: _pngBytes);
      addTearDown(restoreFilePickerPlatform);

      await _pumpSection(tester, app, tx.id);

      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pumpAndSettle();

      // Подтверждение прикрепления: исходное имя файла.
      expect(find.text(app.l10n.attachmentPickTitle), findsOneWidget);
      expect(find.textContaining('check.png'), findsOneWidget);
      await _confirmAttach(tester, app);
      // Перечтение провайдера после invalidate: drift завершает future
      // в микротаске вне кадров — даём ему завершиться (§7).
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();

      expect(find.text(app.l10n.attachmentSaved), findsOneWidget);
      // Карточка: имя вложения `<uuid>.png` (D-63), фото-иконка.
      expect(find.textContaining('.png'), findsOneWidget);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);

      final Attachment? att =
          await app.db.attachmentsDao.findByTransaction(tx.id);
      expect(att, isNotNull);
      expect(att!.mimeType, 'image/png');
      expect(att.fileSize, _pngBytes.length);
      // Файл записан фейковым сервисом «на диск» (в памяти).
      expect(fake.files[att.filePath], isNotNull);
    },
  );

  test('formatAttachmentSize: RU-локаль — запятая-разделитель, «977 KB»', () {
    // RU: дробная часть — через запятую (NumberFormat.decimalPattern('ru')).
    // Единицы KB/MB не локализуются (контракт функции). KB-ветка: целые
    // килобайты (ceil), группировка в ней недостижима (KB < 1024).
    expect(formatAttachmentSize(977 * 1024, locale: 'ru'), '977 KB');
    // MB-ветка: RU — запятая в дробной части, EN — точка.
    expect(
      formatAttachmentSize(5 * 1024 * 1024 + 512 * 1024, locale: 'ru'),
      '5,5 MB',
    );
    expect(
      formatAttachmentSize(5 * 1024 * 1024 + 512 * 1024, locale: 'en'),
      '5.5 MB',
    );
  });

  testWidgets(
    'лимит: файл больше 10 МБ отклоняется до подтверждения, записи нет',
    (WidgetTester tester) async {
      final (AppHarness app, _) = await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final List<int> oversized =
          List<int>.filled(AttachmentsStorage.maxFileSizeBytes + 1, 1);
      final File picked = await _tempFile(tester, 'huge.png', oversized);
      installFilePickerShim(path: picked.path, bytes: oversized);
      addTearDown(restoreFilePickerPlatform);

      await _pumpSection(tester, app, tx.id);

      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pumpAndSettle();

      // Отказ лимита: текст с предформатированным размером, диалога
      // подтверждения нет, записи нет.
      expect(
        find.text(
          app.l10n.attachmentTooLarge(
            formatAttachmentSize(AttachmentsStorage.maxFileSizeBytes),
          ),
        ),
        findsOneWidget,
      );
      expect(find.text(app.l10n.attachmentPickTitle), findsNothing);
      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNull,
      );
    },
  );

  testWidgets(
    'замена: повторный выбор перезаписывает вложение и удаляет старый файл',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) =
          await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final File second = await _tempFile(tester, 'second.jpg', <int>[9, 9, 9]);
      final Attachment att1 = await fake.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: _pngBytes,
      );

      await _pumpSection(tester, app, tx.id);

      // Замена = повторный выбор файла (кнопка «Заменить» в карточке):
      // диалог с явным текстом замены.
      installFilePickerShim(path: second.path, bytes: <int>[9, 9, 9]);
      addTearDown(restoreFilePickerPlatform);
      await tester.tap(find.byIcon(Icons.published_with_changes));
      await tester.pumpAndSettle();

      expect(find.text(app.l10n.attachmentReplaceTitle), findsOneWidget);
      // Content диалога — конкатенация «файл · размер \n\n текст».
      expect(
        find.textContaining(app.l10n.attachmentReplaceBody),
        findsOneWidget,
      );
      expect(find.textContaining('second.jpg'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(FilledButton, app.l10n.attachmentReplaceAction),
      );
      await tester.pumpAndSettle();

      // Замена прошла: одна живая запись, файл новый, старый файл удалён.
      final Attachment? att2 =
          await app.db.attachmentsDao.findByTransaction(tx.id);
      expect(att2, isNotNull);
      expect(att2!.filePath, endsWith('.jpg'));
      expect(att2.id, isNot(att1.id));
      // Старый файл удалён, новый записан (в-memory хранилище фейка).
      expect(fake.files[att1.filePath], isNull);
      expect(fake.files[att2.filePath], isNotNull);
      expect(find.textContaining('.jpg'), findsOneWidget);
    },
  );

  testWidgets(
    'S2 (D-71): тап «Заменить» после pumpAndSettle — подтверждение с текстом замены',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) =
          await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final File second = await _tempFile(tester, 'second.jpg', <int>[9, 9, 9]);
      // Вложение существует до первого кадра секции: именно на таком
      // состоянии гонка S2 — подтверждение замены не должно показывать
      // «Прикрепить» ни при какой загрузке future провайдера.
      final Attachment att1 = await fake.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: _pngBytes,
      );

      await _pumpSection(tester, app, tx.id);

      installFilePickerShim(path: second.path, bytes: <int>[9, 9, 9]);
      addTearDown(restoreFilePickerPlatform);
      await tester.tap(find.byIcon(Icons.published_with_changes));
      await tester.pumpAndSettle();

      // Диалог замены: и заголовок, и кнопка действия — тексты замены.
      expect(find.text(app.l10n.attachmentReplaceTitle), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, app.l10n.attachmentReplaceAction),
        findsOneWidget,
      );

      // Подтверждение выполняет замену: одна живая запись, файл новый,
      // старый убран.
      await tester.tap(
        find.widgetWithText(FilledButton, app.l10n.attachmentReplaceAction),
      );
      await tester.pumpAndSettle();
      final Attachment? att2 =
          await app.db.attachmentsDao.findByTransaction(tx.id);
      expect(att2, isNotNull);
      expect(att2!.id, isNot(att1.id));
      expect(fake.files[att2.filePath], isNotNull);
      expect(fake.files[att1.filePath], isNull);
    },
  );

  testWidgets(
    'удаление: подтверждение — запись мягко удалена, файл убран',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) =
          await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final Attachment att = await fake.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: _pngBytes,
      );

      await _pumpSection(tester, app, tx.id);

      // Удаление: подтверждение обязательно (отмена ничего не меняет).
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.attachmentDeleteTitle), findsOneWidget);
      await tester.tap(find.text(app.l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNotNull,
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.deleteAction));
      await tester.pumpAndSettle();

      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNull,
      );
      // Файл убран «с диска» (из памяти фейка).
      expect(fake.files[att.filePath], isNull);
      // Секция вернулась к пустому состоянию.
      expect(find.text(app.l10n.attachmentPickAction), findsOneWidget);
    },
  );

  testWidgets(
    'отсутствие файла на диске (восстановленный бэкап): без падения, отказ при открытии',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) =
          await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final Attachment att = await fake.attach(
        transactionId: tx.id,
        mimeType: 'image/png',
        bytes: _pngBytes,
      );
      // D-64: импорт бэкапа восстанавливает метаданные без файлов —
      // убираем файл «с диска» (из памяти фейка) и помечаем шов I/O.
      fake.files.remove(att.filePath);
      missingSuffix = att.filePath;
      addTearDown(() => missingSuffix = '.never-matches');

      await _pumpSection(tester, app, tx.id);

      // Карточка показывается (вложение видно), с пометкой отсутствия.
      expect(find.textContaining(att.filePath), findsOneWidget);
      expect(find.text(app.l10n.attachmentFileMissing), findsOneWidget);

      // Открытие — отказ-снекбар, без исключений и без падения UI.
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.attachmentFileMissing), findsWidgets);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PDF: прикрепляется, при открытии — диалог «просмотр недоступен» без падения',
    (WidgetTester tester) async {
      final (AppHarness app, _) = await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final File picked = await _tempFile(tester, 'receipt.pdf', _pdfBytes);
      installFilePickerShim(path: picked.path, bytes: _pdfBytes);
      addTearDown(restoreFilePickerPlatform);

      await _pumpSection(tester, app, tx.id);

      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pumpAndSettle();
      await _confirmAttach(tester, app);

      // PDF-иконка вместо фото-иконки.
      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);

      // Открытие PDF: диалог с метаданными и честным отказом (фаза 2).
      // Content — конкатенация «имя\n\nразмер\n\nотказ».
      await tester.tap(find.byIcon(Icons.open_in_new));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(app.l10n.attachmentPdfUnsupported),
        findsOneWidget,
      );
      // Карточка (fake-0.pdf) и диалог (fake-0.pdf) — имя в двух местах.
      expect(find.textContaining('.pdf'), findsNWidgets(2));

      // Закрытие диалога: секция жива, вложение не тронуто.
      await tester.tap(find.text(app.l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNotNull,
      );
    },
  );

  testWidgets(
    'mime вне белого списка: отказ с текстом о типе файла, записи нет',
    (WidgetTester tester) async {
      final (AppHarness app, _) = await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final File picked = await _tempFile(tester, 'notes.txt', <int>[1, 2, 3]);
      installFilePickerShim(path: picked.path, bytes: <int>[1, 2, 3]);
      addTearDown(restoreFilePickerPlatform);

      await _pumpSection(tester, app, tx.id);

      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pumpAndSettle();

      expect(
        find.text(app.l10n.attachmentMimeTypeUnsupported),
        findsOneWidget,
      );
      expect(find.text(app.l10n.attachmentPickTitle), findsNothing);
      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNull,
      );
    },
  );

  testWidgets(
    'отказ ФС при записи (storageFailure): снекбар, вложения нет, операция цела',
    (WidgetTester tester) async {
      final (AppHarness app, _) =
          await _pumpAppWithFake(tester, failStorage: true);
      final Transaction tx = await _seedTransaction(app);
      final File picked = await _tempFile(tester, 'check.png', _pngBytes);
      installFilePickerShim(path: picked.path, bytes: _pngBytes);
      addTearDown(restoreFilePickerPlatform);

      await _pumpSection(tester, app, tx.id);
      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pumpAndSettle();
      await _confirmAttach(tester, app);

      expect(find.text(app.l10n.errorAttachmentStorage), findsOneWidget);
      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNull,
      );
      // Операция цела (D-63: отказ не теряет данные пользователя).
      expect(
        await app.db.transactionsDao.findById(tx.id),
        isNotNull,
      );
    },
  );

  testWidgets(
    'BUSY-замок: двойной тап во время записи не даёт повторную запись (D-63)',
    (WidgetTester tester) async {
      final (AppHarness app, _FakeAttachmentsService fake) =
          await _pumpAppWithFake(tester);
      final Transaction tx = await _seedTransaction(app);
      final File picked = await _tempFile(tester, 'check.png', _pngBytes);
      installFilePickerShim(path: picked.path, bytes: _pngBytes);
      addTearDown(restoreFilePickerPlatform);

      await _pumpSection(tester, app, tx.id);

      // Первый тап: пикер → подтверждение → attach замирает в фейке
      // (holdAttach + незавершённый attachGate). Фреймы прокручиваем
      // pump (не pumpAndSettle: Future от attachGate в fake_async не
      // завершится — таймера нет, ждём именно Completer).
      fake.holdAttach = true;
      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pump();
      await _confirmAttach(tester, app);
      expect(fake.attachCalls, 1);
      expect(
        await app.db.attachmentsDao.findByTransaction(tx.id),
        isNull,
        reason: 'attach ещё не завершён — записи нет',
      );

      // Кнопка секции занята: тап по ней ничего не делает (onPressed:
      // null), второй attach не вызывается.
      final OutlinedButton pickButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, app.l10n.attachmentPickAction),
      );
      expect(pickButton.onPressed, isNull, reason: 'секция занята (_busy)');
      await tester.tap(
        find.widgetWithText(OutlinedButton, app.l10n.attachmentPickAction),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(fake.attachCalls, 1);

      // Завершаем attach: ровно одна запись с данными первого тапа.
      fake.attachGate.complete();
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.attachmentSaved), findsOneWidget);
      final Attachment saved =
          await app.db.attachmentsDao.findByTransaction(tx.id)
              as Attachment;
      expect(saved.fileSize, _pngBytes.length);
      expect(
        (await app.db.customSelect(
          'SELECT COUNT(*) AS c FROM attachments',
        ).get())
            .single
            .read<int>('c'),
        1,
        reason: 'повторной записи нет — двойной тап поглощён BUSY',
      );
    },
  );
}
