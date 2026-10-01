// Виджет-тесты раздела «Долги» (M6-шаг C, D-89): список/секции/сводки
// (§1), форма долга с валидациями D-82 (§3), гашение без перевода (§4),
// связка «перевод + платёж» с гонкой «долг удалён» (§4/D-81.в), карточка
// при гонке — errorNotFound и назад (D-87.1), вложение на долге по
// каркасу D-67.а с текстом attachmentDebtPickBody (§2/§6.2), баннер
// напоминаний (§7) с потоком включения по шву разрешения (D-88.1).
//
// Тестовая зона §7: реального I/O в fake_async нет — сервис вложений
// подменён фейком с in-memory файлами (образец attachment_section_test),
// хранилище настроек напоминаний — временный каталог (D-43), шов запроса
// разрешения — фейк (D-88.1). Проверки БД — одноразовые select().get()
// внутри tester.runAsync (§7: watch-стримы drift не завершаются в
// fake_async-зоне вне runAsync — грабли зависания теста).
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kopilka/app/router.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/attachments_service.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/dao/attachments_dao.dart' show AttachmentsDao;
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';
import 'package:kopilka/data/reminders/reminders_permission.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/features/transactions/attachments_controller.dart'
    show attachmentsIoProvider, AttachmentsIo;
import 'package:kopilka/l10n/gen/app_localizations.dart';

// Шов пикера/чтения файла вложения (M5-6в): в тесте вложения пикер должен
// вернуть файл — без шима тап «Прикрепить» даёт cancel и диалог не открывается.
import '../../file_picker_shim.dart'
    show FakeAttachmentsIo, installFilePickerShim, restoreFilePickerPlatform;

const List<int> _pngBytes = <int>[0x89, 0x50, 0x4E, 0x47, 9, 8, 7];

/// Фейковый шов запроса разрешения (D-88.1): результат задаёт тест.
class _FakeRemindersPermission implements RemindersPermission {
  _FakeRemindersPermission(this.result);

  bool result;

  int calls = 0;

  @override
  Future<bool> request() async {
    calls++;
    return result;
  }
}

/// Тестовый сервис вложений с in-memory файлами (образец
/// attachment_section_test.dart): владелец — долг (M6/D-82).
class _FakeAttachmentsService extends AttachmentsService {
  _FakeAttachmentsService()
    : super(
        AttachmentsStorage(rootDirectory: Directory.systemTemp),
        _UnusedDao(),
      );

  // Пере-цепляется к БД приложения после сборки харнесса (useDatabase).
  late AttachmentsDao dao;

  final Map<String, List<int>> files = <String, List<int>>{};

  int _seq = 0;

  /// Переводит фейк на dao живой БД приложения (после _pumpApp).
  void useDatabase(AppDatabase db) => dao = db.attachmentsDao;

  @override
  Future<Attachment> attachToOwner({
    required AttachmentOwnerKind owner,
    required String ownerId,
    required String mimeType,
    required List<int> bytes,
  }) async {
    assert(owner == AttachmentOwnerKind.debt);
    final Attachment created = await dao.createForDebt(
      debtId: ownerId,
      filePath: 'debt-fake-${_seq++}.png',
      mimeType: mimeType,
      fileSize: bytes.length,
    );
    files[created.filePath] = bytes;
    return created;
  }

  @override
  Future<Attachment?> findForDebt(String debtId) => dao.findByDebt(debtId);

  @override
  Future<void> delete(String attachmentId) async {
    final Attachment attachment = await dao.requireAliveById(attachmentId);
    await dao.softDelete(attachment.id);
    files.remove(attachment.filePath);
  }

  @override
  Directory get directory => Directory('/fake-attachments');
}

class _UnusedDao extends AttachmentsDao {
  _UnusedDao() : super(AppDatabase.forTesting(NativeDatabase.memory()));
}

/// Фейк I/O: проверки файла вложения без диска (§7).
class _FakeAttachmentsIo implements AttachmentsIo {
  const _FakeAttachmentsIo();

  @override
  Future<Uint8List> readBytes(String path) async =>
      Uint8List.fromList(_pngBytes);

  @override
  Future<bool> exists(String path) async => true;
}

/// Хост с роутером приложения (карточка долга — вложенный маршрут).
class _Host extends ConsumerWidget {
  const _Host();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(routerProvider);
    return MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('ru'),
      routerConfig: router,
    );
  }
}

/// Всё, что тесту нужно от харнесса.
class _App {
  const _App(this.db, this.l10n, this.store);

  final AppDatabase db;
  final AppLocalizations l10n;
  final RemindersPreferencesStore store;
}

/// Харнесс: in-memory БД, каталоги настроек, швы напоминаний/вложений
/// (образец pumpDialogApp). Старт — на списке долгов.
Future<_App> _pumpApp(
  WidgetTester tester, {
  _FakeRemindersPermission? permission,
  _FakeAttachmentsService? attachments,
  AttachmentsIo io = const _FakeAttachmentsIo(),
}) async {
  addTearDown(restoreFilePickerPlatform);
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  tester.platformDispatcher.localeTestValue = const Locale('ru');
  tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final AppLocalizations l10n = await AppLocalizations.delegate.load(
    const Locale('ru'),
  );

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);

  final Directory baseDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_debts_test'),
  ))!;
  addTearDown(() => tester.runAsync(() => baseDir.delete(recursive: true)));
  final RemindersPreferencesStore remindersStore = RemindersPreferencesStore(
    baseDirectory: baseDir,
  );

  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider.overrideWithValue(
        AutoBackupDirectoryStore(baseDirectory: baseDir),
      ),
      updatePreferencesStoreProvider.overrideWithValue(
        UpdatePreferencesStore(baseDirectory: baseDir),
      ),
      remindersPreferencesStoreProvider.overrideWithValue(remindersStore),
      if (permission != null)
        remindersPermissionProvider.overrideWithValue(permission),
      if (attachments != null)
        attachmentsServiceProvider.overrideWithValue(attachments),
      attachmentsIoProvider.overrideWithValue(io),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const _Host()),
  );
  // Старт на списке долгов (ветка шестая, D-89).
  container.read(routerProvider).go('/debts');
  await tester.pumpAndSettle();
  return _App(db, l10n, remindersStore);
}

/// Пересборка провайдеров после записи через контроллер: drift завершает
/// future в микротаске вне кадров (§7) — даём завершиться.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

/// Одноразовая выборка живых долгов из БД (§7: не через watch-стрим).
Future<List<Debt>> _aliveDebts(AppDatabase db) =>
    (db.select(db.debts)..where((t) => t.deletedAt.isNull())).get();

/// Одноразовая выборка живых платежей долга (§7: не через watch-стрим).
Future<List<DebtPayment>> _paymentsOf(AppDatabase db, String debtId) =>
    (db.select(
      db.debtPayments,
    )..where((t) => t.debtId.equals(debtId) & t.deletedAt.isNull())).get();

Future<Debt> _seedTheyOweMe(AppDatabase db, {String person = 'Аня'}) =>
    db.debtsDao.create(
      person: person,
      direction: DebtDirection.theyOweMe,
      amountMinor: 1050000,
      currencyCode: 'RUB',
      extraMinor: 50000,
    );

void main() {
  testWidgets(
    'список: две секции, сводки секций; тап открывает карточку с сводкой',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      await _seedTheyOweMe(app.db);
      await app.db.debtsDao.create(
        person: 'Боря',
        direction: DebtDirection.iOweThem,
        amountMinor: 200000,
        currencyCode: 'RUB',
      );
      await _settle(tester);

      // Секции и люди на местах (§1).
      expect(find.text(app.l10n.debtSectionTheyOweMe), findsOneWidget);
      expect(find.text(app.l10n.debtSectionIOweThem), findsOneWidget);
      expect(find.text('Аня'), findsOneWidget);
      expect(find.text('Боря'), findsOneWidget);
      // Сводки секций (§1) — заголовки с суммами.
      expect(
        find.textContaining(app.l10n.debtSectionTotalTheyOweMe('')),
        findsOneWidget,
      );
      expect(
        find.textContaining(app.l10n.debtSectionTotalIOweThem('')),
        findsOneWidget,
      );

      // Карточка долга (§2): сводка текстом, чипа «Погашен» нет.
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.debtRecordPaymentAction), findsOneWidget);
      expect(find.text(app.l10n.debtPaymentsEmpty), findsOneWidget);
      expect(find.text(app.l10n.debtPaidOffBadge), findsNothing);
      expect(find.textContaining(app.l10n.debtRemainingLine('')), findsWidgets);
    },
  );

  testWidgets(
    'форма: пустое имя не проходит валидацию; нулевая сумма не пишется '
    '(D-82 в UI, §3)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      // Пустой список → EmptyState с CTA формы (§1).
      expect(find.text(app.l10n.debtsEmpty), findsOneWidget);
      await tester.tap(find.text(app.l10n.debtsEmptyCta));
      await tester.pumpAndSettle();

      // Сразу «Сохранить»: валидатор имени подсвечен (debtPersonRequired).
      await tester.tap(find.text(app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.debtPersonRequired), findsOneWidget);

      // Имя ввели, сумма пуста — AmountField за валидатором (amountInvalid),
      // DAO-дубля нет: долг в БД не появился, диалог не закрылся (§3).
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPersonLabel),
        'Аня',
      );
      await tester.tap(find.text(app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => _aliveDebts(app.db)), isEmpty);
      expect(find.text(app.l10n.debtAddTitle), findsOneWidget);

      // Корректные данные: долг создаётся, список обновляется живым потоком.
      await tester.enterText(find.byType(TextFormField).at(1), '10 500');
      await tester.tap(find.text(app.l10n.saveAction));
      await _settle(tester);
      final List<Debt> alive =
          await tester.runAsync(() => _aliveDebts(app.db)) ?? <Debt>[];
      expect(alive, hasLength(1));
      expect(alive.single.person, 'Аня');
      expect(alive.single.amountMinor, 1050000);
      expect(find.text(app.l10n.debtSectionTheyOweMe), findsOneWidget);
    },
  );

  testWidgets(
    'гашение без перевода (по умолчанию): платёж записан, перевод не создаётся '
    '(§4/D-81.в)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      final Debt debt = await _seedTheyOweMe(app.db);
      await _settle(tester);
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();

      await tester.tap(find.text(app.l10n.debtRecordPaymentAction));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPaymentAmountLabel),
        '4 000',
      );
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction).last);
      await _settle(tester);

      // Диалог закрыт, платёж в БД без перевода.
      expect(find.byType(AlertDialog), findsNothing);
      final List<DebtPayment> payments =
          await tester.runAsync(() => _paymentsOf(app.db, debt.id)) ??
          <DebtPayment>[];
      expect(payments, hasLength(1));
      expect(payments.single.amountMinor, 400000);
      expect(payments.single.transactionId, isNull);
      // Список платежей ушёл из пустого состояния (§2).
      expect(find.text(app.l10n.debtPaymentsEmpty), findsNothing);
    },
  );

  testWidgets(
    'связка «перевод + платёж»: гонка «долг удалён» на записи — поток '
    'откатывается: ни перевода, ни платежа (§4)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      final Account account = await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      final Debt debt = await app.db.debtsDao.create(
        person: 'Аня',
        direction: DebtDirection.theyOweMe,
        amountMinor: 1000000,
        currencyCode: 'RUB',
      );
      await _settle(tester);
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction));
      await tester.pumpAndSettle();

      // Связываем с переводом, вводим сумму — и мягко удаляем долг
      // (гонка «из другого окна»): «Записать» откатывает поток (§4).
      await tester.tap(find.text(app.l10n.debtPaymentLinkTransfer));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPaymentAmountLabel),
        '10',
      );
      await app.db.debtsDao.softDelete(debt.id);
      await tester.tap(find.text(app.l10n.debtTransferRecordAction));
      await _settle(tester);

      // Ни платежа (долг удалён), ни перевода-операции (откат §4).
      final List<DebtPayment> payments =
          await tester.runAsync(() => _paymentsOf(app.db, debt.id)) ??
          <DebtPayment>[];
      expect(payments, isEmpty);
      final List<Transaction> rows =
          await tester.runAsync(
            () => app.db.select(app.db.transactions).get(),
          ) ??
          <Transaction>[];
      expect(rows, isEmpty);
      account;
    },
  );

  testWidgets(
    'связка с мультивалютным переводом: платёж из поля платежа в валюте '
    'долга, суммы перевода — из полей перевода (D-90/D-81.в/D-17)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      // Валюта долга USD в справочнике (курс 1 — неважно, суммы задаём
      // вручную); счёт списания RUB, зачисления USD (валюта долга).
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 1,
      );
      await app.db.accountsDao.create(
        name: 'Рублёвая карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      await app.db.accountsDao.create(
        name: 'Долларовая карта',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      final Debt debt = await app.db.debtsDao.create(
        person: 'Аня',
        direction: DebtDirection.theyOweMe,
        amountMinor: 1050,
        currencyCode: 'USD',
      );
      await _settle(tester);
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction));
      await tester.pumpAndSettle();

      // Связка: списание — рублёвая карта (первый живой), зачисление —
      // долларовая (валюта долга) — дефолты диалога.
      await tester.tap(find.text(app.l10n.debtPaymentLinkTransfer));
      await tester.pumpAndSettle();

      // Платёж «10,50» в валюте долга (USD) — ввод не блокируется; прежде
      // поле делило контроллер с полем «Списано» (D-90).
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPaymentAmountLabel),
        '10,50',
      );
      // Списание 850 ₽ (из поля списания), зачисление 10,50 $ (D-17).
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountOut),
        '850',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountIn),
        '10,50',
      );
      expect(find.text(app.l10n.amountInvalid), findsNothing);
      await tester.tap(find.text(app.l10n.debtTransferRecordAction));
      await _settle(tester);

      expect(find.byType(AlertDialog), findsNothing);
      // Платёж — 1050 минорных USD (из поля платежа), не сумма списания.
      final List<DebtPayment> payments =
          await tester.runAsync(() => _paymentsOf(app.db, debt.id)) ??
          <DebtPayment>[];
      expect(payments, hasLength(1));
      expect(payments.single.amountMinor, 1050);
      expect(payments.single.transactionId, isNotNull);
      // Перевод: списание 85000 минорных RUB, зачисление 1050 минорных USD —
      // обе суммы по D-17 (мультивалютный перевод — с targetAmountMinor).
      final List<Transaction> rows =
          await tester.runAsync(
            () => app.db.select(app.db.transactions).get(),
          ) ??
          <Transaction>[];
      expect(rows, hasLength(1));
      expect(
        TransactionType.fromDb(rows.single.type),
        TransactionType.transfer,
      );
      expect(rows.single.amountMinor, 85000);
      expect(rows.single.currencyCode, 'RUB');
      expect(rows.single.targetAmountMinor, 1050);
    },
  );

  testWidgets(
    'гонка «долг удалён»: карточка показывает errorNotFound и возвращается '
    'к списку (D-87.1)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      final Debt debt = await _seedTheyOweMe(app.db);
      await _settle(tester);
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.debtRecordPaymentAction), findsOneWidget);

      // Гонка: долг мягко удалён «из другого окна» — сводка умирает в NULL.
      await app.db.debtsDao.softDelete(debt.id);
      await _settle(tester);

      // Штатный исход (§2/§8): текст errorNotFound и возврат к списку.
      // Долг был один — после удаления список показывает EmptyState (§1).
      expect(find.text(app.l10n.errorNotFound), findsOneWidget);
      await _settle(tester);
      expect(find.text(app.l10n.debtsEmpty), findsOneWidget);
    },
  );

  testWidgets(
    'вложение на долге (каркас D-67.а): подтверждение с текстом про долг, '
    'файл в БД с владельцем d:<id> (§2/§6.2)',
    (WidgetTester tester) async {
      final _FakeAttachmentsService fake = _FakeAttachmentsService();
      installFilePickerShim(path: '/fake/check.png', bytes: _pngBytes);
      final _App app = await _pumpApp(
        tester,
        attachments: fake,
        io: const FakeAttachmentsIo(),
      );
      // Фейк пишет в БД приложения (пере-цепляем после сборки харнесса).
      fake.useDatabase(app.db);
      final Debt debt = await _seedTheyOweMe(app.db);
      await _settle(tester);
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();

      // Секция вложения: кнопка «Прикрепить» (§2).
      await tester.tap(find.text(app.l10n.attachmentPickAction));
      await tester.pumpAndSettle();
      // Подтверждение — с новым ключом про долг (§6.2), не про операцию;
      // текст диалога составной («файл · размер\n\nтекст») — textContaining
      // (образец attachment_section_test).
      expect(
        find.textContaining(app.l10n.attachmentDebtPickBody),
        findsOneWidget,
      );
      expect(find.textContaining(app.l10n.attachmentPickBody), findsNothing);
      await tester.tap(find.text(app.l10n.attachmentPickAction).last);
      await _settle(tester);

      // Снек «Вложение сохранено», запись в БД — с ключом владельца долга.
      expect(find.text(app.l10n.attachmentSaved), findsOneWidget);
      final Attachment? att = await tester.runAsync<Attachment?>(
        () => fake.dao.findByDebt(debt.id),
      );
      expect(att, isNotNull);
      expect(att!.transactionId, 'd:${debt.id}');
      expect(fake.files[att.filePath], isNotNull);
    },
  );

  testWidgets(
    'баннер: «Не сейчас» скрывает до конца сессии, настройка и запрос '
    'разрешения не задеты (§7/D-88.1)',
    (WidgetTester tester) async {
      final _FakeRemindersPermission permission = _FakeRemindersPermission(
        true,
      );
      final _App app = await _pumpApp(tester, permission: permission);
      // Баннер виден, пока opt-in выключен (D-83/D-89). Чтение настроек —
      // реальный файл в тестовой зоне: только через runAsync (§7).
      expect(find.text(app.l10n.remindersBannerTitle), findsOneWidget);
      expect(await tester.runAsync(() => app.store.readEnabled()), isFalse);

      // «Не сейчас» — скрытие без персиста отказа (D-89).
      await tester.tap(find.text(app.l10n.remindersDismissAction));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.remindersBannerTitle), findsNothing);
      expect(await tester.runAsync(() => app.store.readEnabled()), isFalse);
      expect(permission.calls, 0);
    },
  );

  testWidgets(
    'включение из баннера: отказ в разрешении — настройка не включается, '
    'баннер остаётся (D-88.1/§7)',
    (WidgetTester tester) async {
      final _FakeRemindersPermission denied = _FakeRemindersPermission(false);
      final _App app = await _pumpApp(tester, permission: denied);
      expect(find.text(app.l10n.remindersBannerTitle), findsOneWidget);

      // Тап «Включить» при отказе: снек про разрешение, настройка НЕ
      // включается, баннер остаётся (повтор — снова через баннер, §7).
      await tester.tap(find.text(app.l10n.remindersEnableAction));
      await _settle(tester);
      expect(denied.calls, 1);
      expect(find.text(app.l10n.remindersPermissionDenied), findsOneWidget);
      expect(await tester.runAsync(() => app.store.readEnabled()), isFalse);
      expect(find.text(app.l10n.remindersBannerTitle), findsOneWidget);
    },
  );

  testWidgets(
    'чип «Погашен»: при extra>0 появляется только после гашения и тела, '
    'и переплаты; исчезает после удаления платежа (находка 4/D-102, '
    'чип-моргание UX §4.3/D-90.3)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      // Тело 1000,00 ₽ (100000 minor) + переплата 50 ₽ (5000 minor): тело
      // погашено — extra остаётся, чипа ещё нет (сводка remaining = extra);
      // гашение extra — чип появляется.
      final Debt debt = await app.db.debtsDao.create(
        person: 'Аня',
        direction: DebtDirection.theyOweMe,
        amountMinor: 100000,
        currencyCode: 'RUB',
        extraMinor: 5000,
      );
      await _settle(tester);
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.debtPaidOffBadge), findsNothing);

      // Платёж ровно в тело: переплата сверх — чипа нет (замок покрытия §7).
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPaymentAmountLabel),
        '1 000',
      );
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction).last);
      await _settle(tester);
      expect(find.text(app.l10n.debtPaidOffBadge), findsNothing);

      // Платёж в переплату: остаток 0 — чип появляется (§2/D-89).
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPaymentAmountLabel),
        '50',
      );
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction).last);
      await _settle(tester);
      // Остаток после двух платежей — ноль (через тот же форматтер:
      // неразрывные пробелы литералом не набираются).
      expect(
        tester
            .widget<Text>(find.textContaining(app.l10n.debtRemainingLine('')))
            .data,
        app.l10n.debtRemainingLine(
          formatMoneyMinor(0, symbol: '₽', locale: 'ru'),
        ),
      );
      expect(find.text(app.l10n.debtPaidOffBadge), findsOneWidget);

      // Возврат последнего платежа (soft delete) — чип исчезает: переходы
      // «погашен → возврат» не ломают карточку (чип-моргание UX §4.3).
      final List<DebtPayment> payments =
          await tester.runAsync(() => _paymentsOf(app.db, debt.id)) ??
          <DebtPayment>[];
      await app.db.debtsDao.softDeletePayment(
        payments.firstWhere((DebtPayment p) => p.amountMinor == 5000).id,
      );
      await _settle(tester);
      expect(find.text(app.l10n.debtPaidOffBadge), findsNothing);
    },
  );

  testWidgets(
    'сводка секции мультивалютная: долги в разных валютах — отдельные '
    'корзины в одной строке (§1, находка 7/D-102)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 1,
      );
      // Два долга секции «Мне должны» в разных валютах: 2300 ₽ и 50 $.
      await app.db.debtsDao.create(
        person: 'Аня',
        direction: DebtDirection.theyOweMe,
        amountMinor: 230000,
        currencyCode: 'RUB',
      );
      await app.db.debtsDao.create(
        person: 'Боря',
        direction: DebtDirection.theyOweMe,
        amountMinor: 5000,
        currencyCode: 'USD',
      );
      await _settle(tester);
      final Finder totalLine = find.textContaining(
        app.l10n.debtSectionTotalTheyOweMe(''),
      );
      expect(totalLine, findsOneWidget);
      final String expected = app.l10n.debtSectionTotalTheyOweMe(
        '${formatMoneyMinor(230000, symbol: '₽', locale: 'ru')} · '
        '${formatMoneyMinor(5000, symbol: r'$', locale: 'ru')}',
      );
      expect(tester.widget<Text>(totalLine).data, expected);
    },
  );

  testWidgets(
    'просрочка календарная в UTC: срок «завтра» не просрочен, «позавчера» — '
    'бейдж (S3/D-101, находка 1/D-102)',
    (WidgetTester tester) async {
      final _App app = await _pumpApp(tester);
      // Даты — полуночь UTC (§3), сравнение — календарными датами в UTC,
      // независимо от локальной зоны машины (уточнение D-102). Край
      // «сегодня/вчера» на фикс-датах закрыт core-замком debt_due_test;
      // здесь — даты, стабильные при переходе полуночи UTC в середине
      // теста (класс флейка D-100).
      final DateTime now = DateTime.now().toUtc();
      final DateTime todayUtc = DateTime.utc(now.year, now.month, now.day);
      await app.db.debtsDao.create(
        person: 'Аня',
        direction: DebtDirection.theyOweMe,
        amountMinor: 100000,
        currencyCode: 'RUB',
        dueDate: todayUtc.add(const Duration(days: 1)),
      );
      await app.db.debtsDao.create(
        person: 'Боря',
        direction: DebtDirection.theyOweMe,
        amountMinor: 200000,
        currencyCode: 'RUB',
        dueDate: todayUtc.subtract(const Duration(days: 2)),
      );
      await _settle(tester);

      // Завтрашний срок не просрочен: бейджа нет в плитке Ани (срок
      // «завтра» даже не красный).
      final Finder anyaTile = find.ancestor(
        of: find.text('Аня'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(
          of: anyaTile,
          matching: find.text(app.l10n.debtOverdueBadge),
        ),
        findsNothing,
      );

      // Позавчерашний срок — просрочен: бейдж в плитке долга (цвет ошибки
      // идёт с ним).
      final Finder boryaTile = find.ancestor(
        of: find.text('Боря'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(
          of: boryaTile,
          matching: find.text(app.l10n.debtOverdueBadge),
        ),
        findsOneWidget,
      );
    },
  );
}
