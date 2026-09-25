// Виджет-тест экрана «Настройки»: секции рендерятся, подписи из .arb.
//
// Грабли fake_async: реальный файловый I/O внутри testWidgets не
// завершается (тест виснет), поэтому создание временного каталога
// выполняется через tester.runAsync, а выбранного каталога в состоянии
// контроллера нет (его чтение из файла покрыто контроллерными тестами).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/settings_screen.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('экран настроек показывает секции бэкапов и обновлений',
      (WidgetTester tester) async {
    // Локаль задаётся до pumpWidget: MaterialApp.resolvedLocale для RU.
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final Directory tempDir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('kopilka_settings_widget'),
    ))!;
    addTearDown(() async {
      await tester.runAsync(() => tempDir.delete(recursive: true));
    });

    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDefaultsIfEmpty(db);

    final AutoBackupDirectoryStore store = AutoBackupDirectoryStore(
      baseDirectory: tempDir,
    );
    final UpdatePreferencesStore updatePreferences = UpdatePreferencesStore(
      baseDirectory: tempDir,
    );

    final ProviderContainer container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        autoBackupDirectoryStoreProvider.overrideWithValue(store),
        updatePreferencesStoreProvider.overrideWithValue(updatePreferences),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    expect(find.text(l10n.backupSectionTitle), findsOneWidget);
    expect(find.text(l10n.exportJsonAction), findsOneWidget);
    expect(find.text(l10n.importJsonAction), findsOneWidget);
    expect(find.text(l10n.exportCsvAction), findsOneWidget);
    expect(find.text(l10n.autoBackupTitle), findsOneWidget);
    // Каталог не выбран (реальное чтение файла в fake_async не выполняется):
    // показывается состояние «не выбран».
    expect(find.text(l10n.autoBackupDisabled), findsOneWidget);
    // Секция обновлений: переключатель автопроверки
    // (по умолчанию выкл) и ручная проверка. Сеть в тест не ходит:
    // updateServiceProvider не вызывается без нажатия кнопки.
    expect(find.text(l10n.updateAutoCheck), findsOneWidget);
    expect(find.text(l10n.updateCheckNow), findsOneWidget);
  });
}
