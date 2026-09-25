// Виджет-тесты формы быстрого ввода операции.
//
// Регресс разбора суммы: «25000» создаёт операцию ровно на 2 500 000
// минорных единиц (25 000,00 р), сумма в валюте счёта.
//
// БД подменяется на in-memory по образцу pumpApp (test/app_test.dart).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
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

Future<_Harness> _pumpTransactionHarness(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

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
    () => Directory.systemTemp.createTemp('kopilka_tx_dialog_test'),
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
    'целая сумма «25000» сохраняется как 25 000,00 (2 500 000 minor)',
    (WidgetTester tester) async {
      final _Harness app = await _pumpTransactionHarness(tester);

      // Счёт в валюте посева: операция наследует его валюту (§3).
      final Account account = await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );

      // Переключаемся на вкладку операций, фильтр типа «Доходы» и быстрый
      // ввод: FAB открывает форму выбранного фильтром типа.
      await tester.tap(find.text(app.l10n.navTransactions).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.filterIncomes));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '25000',
      );
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      // Диалог закрылся, операция сохранена с точной суммой в минорных.
      expect(find.byType(AlertDialog), findsNothing);
      final List<Transaction> rows = await app.db.transactionsDao
          .getFiltered(TransactionFilter(accountId: account.id));
      expect(rows, hasLength(1));
      expect(TransactionType.fromDb(rows.single.type), TransactionType.income);
      expect(rows.single.amountMinor, 2500000);
      expect(rows.single.currencyCode, baseCurrencyCode);
    },
  );
}
