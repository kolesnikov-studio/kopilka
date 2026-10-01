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
import 'package:kopilka/data/reminders/reminders_preferences.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/settings_screen.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

void main() {
  testWidgets('экран настроек показывает секции бэкапов и обновлений', (
    WidgetTester tester,
  ) async {
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
        // Напоминания (M6/D-89): секция настроек читает opt-in состояние —
        // хранилище подменяется как остальные (D-43).
        remindersPreferencesStoreProvider.overrideWithValue(
          RemindersPreferencesStore(baseDirectory: tempDir),
        ),
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

    final AppLocalizations l10n = await AppLocalizations.delegate.load(
      const Locale('ru'),
    );
    // Секция синхронизации курсов (D-36, M4-шаг 2) — сразу после «Валюты».
    expect(find.text(l10n.rateSyncSectionTitle), findsOneWidget);
    expect(find.text(l10n.rateSyncEnabled), findsOneWidget);
    expect(find.text(l10n.rateSyncNow), findsOneWidget);
    // Список вырос ещё раз (секция «Тема» первой, M5/D-58): секция
    // бэкапов ниже сгиба — сначала прокрутка до её пунктов; заголовок
    // по ключу появляется вместе с ними (finder.text нашёл бы и на
    // экране, и вне её).
    await tester.scrollUntilVisible(
      find.text(l10n.exportJsonAction),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('backupSection')), findsOneWidget);
    expect(find.text(l10n.exportJsonAction), findsOneWidget);
    expect(find.text(l10n.importJsonAction), findsOneWidget);
    expect(find.text(l10n.exportCsvAction), findsOneWidget);
    expect(find.text(l10n.importCsvAction), findsOneWidget);
    expect(find.text(l10n.autoBackupTitle), findsOneWidget);
    // Каталог не выбран (реальное чтение файла в fake_async не выполняется):
    // показывается состояние «не выбран».
    expect(find.text(l10n.autoBackupDisabled), findsOneWidget);
    // Секция обновлений ниже сгиба (список вырос с пунктом импорта CSV
    // и секцией синхронизации курсов): прокручиваем до кнопки ручной
    // проверки.
    await tester.scrollUntilVisible(
      find.text(l10n.updateCheckNow),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    // Секция обновлений: переключатель автопроверки
    // (по умолчанию выкл) и ручная проверка. Сеть в тест не ходит:
    // updateServiceProvider не вызывается без нажатия кнопки.
    expect(find.text(l10n.updateAutoCheck), findsOneWidget);
    expect(find.text(l10n.updateCheckNow), findsOneWidget);
  });
}
