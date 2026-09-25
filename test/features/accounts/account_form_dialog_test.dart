// Виджет-тесты диалога формы счёта.
//
// Регресс сохранения без выбранной валюты: валидатор поля валюты виден,
// счёт не создаётся, диалог остаётся живым («Отмена» активна и закрывает).
//
// Редактирование счёта: поле «Сумма» означает НОВЫЙ начальный баланс —
// предзаполняется initial_balance_minor и пишется напрямую; операции
// задним числом не трогаются (баланс считается из истории по §3).
//
// БД подменяется на in-memory по образцу pumpApp (test/app_test.dart):
// ProviderContainer создаётся явно и закрывается в addTearDown до демонтажа
// дерева; каталоги настроек — во временном каталоге, их создание — реальный
// файловый I/O, поэтому через runAsync.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

class _Harness {
  _Harness(this.container, this.db, this.l10n);

  final ProviderContainer container;
  final AppDatabase db;
  final AppLocalizations l10n;
}

Future<_Harness> _pumpDialogHarness(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  // Локаль задаётся явно: платформенная по умолчанию в тестах — en, а строки
  // ниже берутся из загруженного экземпляра (эталон — сама локализация).
  tester.platformDispatcher.localeTestValue = const Locale('ru');
  tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final AppLocalizations l10n =
      await AppLocalizations.delegate.load(const Locale('ru'));

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);

  final Directory baseDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_account_dialog_test'),
  ))!;
  addTearDown(() => tester.runAsync(() => baseDir.delete(recursive: true)));

  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider
          .overrideWithValue(AutoBackupDirectoryStore(baseDirectory: baseDir)),
      updatePreferencesStoreProvider
          .overrideWithValue(UpdatePreferencesStore(baseDirectory: baseDir)),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const KopilkaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, db, l10n);
}

void main() {
  testWidgets(
    'сохранение счёта без валюты: валидация под полем, счёт не создан, диалог живой',
    (WidgetTester tester) async {
      final _Harness app = await _pumpDialogHarness(tester);

      // Диалог добавления счёта: название и сумма заполнены, валюту не трогаем.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.nameLabel),
        'Наличные',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '500',
      );

      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      // Валидация валюты показана, счёт в БД не попал.
      expect(find.text(app.l10n.selectCurrencyValidator), findsOneWidget);
      expect(await app.db.accountsDao.getAlive(), isEmpty);

      // Регрессия заморозки: кнопки активны, «Отмена» закрывает диалог.
      await tester.tap(find.widgetWithText(TextButton, app.l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'сохранение счёта с операциями без правок не меняет начальный баланс',
    (WidgetTester tester) async {
      final _Harness app = await _pumpDialogHarness(tester);

      // Счёт с начальным балансом 10 000,00 и живой операцией 500,00 —
      // вычисленный баланс 10 500,00 отличается от начального.
      final Account account = await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
        initialBalanceMinor: 1000000,
      );
      await app.db.transactionsDao.create(
        type: TransactionType.income,
        accountId: account.id,
        amountMinor: 50000,
      );

      // Открыть редактирование и сохранить без единой правки.
      await tester.tap(find.text(app.l10n.navAccounts).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Карта'));
      await tester.pumpAndSettle();

      // Поле «Сумма» предзаполнено начальным балансом, не вычисленным.
      expect(find.text('10000.00'), findsOneWidget);
      expect(find.text('10500.00'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      // Начальный баланс не изменился; баланс счёта по-прежнему складывается
      // из истории операций (§3) — 10 500,00.
      final Account? after = await app.db.accountsDao.findById(account.id);
      expect(after, isNotNull);
      expect(after!.initialBalanceMinor, 1000000);
      expect(await app.db.accountsDao.balanceMinor(account.id), 1050000);
    },
  );

  testWidgets(
    'редактирование счёта с нулевым начальным балансом сохраняется',
    (WidgetTester tester) async {
      final _Harness app = await _pumpDialogHarness(tester);

      final Account account = await app.db.accountsDao.create(
        name: 'Копилка',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );

      await tester.tap(find.text(app.l10n.navAccounts).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Копилка'));
      await tester.pumpAndSettle();

      // Ноль в поле «новый начальный баланс» корректен: валидация не
      // блокирует сохранение, значение не меняется.
      expect(find.text('0.00'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      final Account? after = await app.db.accountsDao.findById(account.id);
      expect(after, isNotNull);
      expect(after!.initialBalanceMinor, 0);
    },
  );
}
