// Тест каркаса приложения: приложение запускается, пять вкладок
// переключаются, на широком окне навигация уходит в боковой rail,
// тексты берутся из локализаций. Литеральных строк в ожиданиях нет:
// эталон — сами загруженные локализации.
//
// БД подменяется на in-memory: настоящая нативная SQLite в виджет-тестах
// даёт живой цикл событий и бесконечный pumpAndSettle.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Размер окна телефона по умолчанию для тестов.
const Size phoneSize = Size(400, 800);

/// Размер окна десктопа (rail-навигация).
const Size desktopSize = Size(1200, 800);

/// Локаль, на которой работают тесты, и загруженные для неё строки.
Future<AppLocalizations> localizationsFor(Locale locale) =>
    AppLocalizations.delegate.load(locale);

/// Запускает приложение в заданном размере окна и локали и возвращает
/// строки этой локали.
Future<AppLocalizations> pumpApp(
  WidgetTester tester, {
  Size size = phoneSize,
  Locale locale = const Locale('ru'),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  tester.platformDispatcher.localeTestValue = locale;
  tester.platformDispatcher.localesTestValue = <Locale>[locale];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);

  // Контейнер создаётся явно и закрывается в tearDown: демонтаж дерева
  // виджетов запускает закрытие drift-потоков внутри fake_async теста,
  // и их служебные таймеры роняют проверку pending timers.
  // Каталог автобэкапа — во временном каталоге: экран настроек читает
  // сохранённый путь при старте. Создание каталога — реальный файловый
  // I/O, поэтому через runAsync (в fake_async он не завершается).
  final Directory backupBaseDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_app_test'),
  ))!;
  addTearDown(
    () => tester.runAsync(() => backupBaseDir.delete(recursive: true)),
  );

  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider
          .overrideWithValue(AutoBackupDirectoryStore(baseDirectory: backupBaseDir)),
      updatePreferencesStoreProvider.overrideWithValue(
        UpdatePreferencesStore(baseDirectory: backupBaseDir),
      ),
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

  return localizationsFor(locale);
}

/// Пункт навигации по подписи внутри конкретного навигационного виджета.
Finder navItem(Type navigationWidgetType, String label) => find.descendant(
  of: find.byType(navigationWidgetType),
  matching: find.text(label),
);

void main() {
  testWidgets('приложение запускается на экране «Счета»', (
    WidgetTester tester,
  ) async {
    final AppLocalizations l10n = await pumpApp(tester);

    expect(find.text(l10n.accountsEmpty), findsOneWidget);
    // Подпись вкладки видна и в заголовке, и в навигации.
    expect(find.text(l10n.navAccounts), findsNWidgets(2));
  });

  testWidgets('нижняя навигация переключает пять вкладок', (
    WidgetTester tester,
  ) async {
    final AppLocalizations l10n = await pumpApp(tester);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(navItem(NavigationBar, l10n.navTransactions));
    await tester.pumpAndSettle();
    expect(find.text(l10n.transactionsEmpty), findsOneWidget);

    await tester.tap(navItem(NavigationBar, l10n.navCategories));
    await tester.pumpAndSettle();
    // База сеется предустановками: на экране видна первая системная категория.
    expect(find.text(presetExpenseCategories.first), findsOneWidget);

    await tester.tap(navItem(NavigationBar, l10n.navReports));
    await tester.pumpAndSettle();
    // Экран отчётов реальный: карточка общего баланса.
    expect(find.text(l10n.reportsTotalBalance), findsOneWidget);

    await tester.tap(navItem(NavigationBar, l10n.navSettings));
    await tester.pumpAndSettle();
    // Экран настроек реальный: секция бэкапов.
    expect(find.text(l10n.backupSectionTitle), findsOneWidget);

    await tester.tap(navItem(NavigationBar, l10n.navAccounts));
    await tester.pumpAndSettle();
    expect(find.text(l10n.accountsEmpty), findsOneWidget);
  });

  testWidgets('на широком окне навигация показывается как rail', (
    WidgetTester tester,
  ) async {
    final AppLocalizations l10n = await pumpApp(tester, size: desktopSize);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(navItem(NavigationRail, l10n.navReports));
    await tester.pumpAndSettle();
    expect(find.text(l10n.reportsTotalBalance), findsOneWidget);
  });

  testWidgets('обе локали подключены: EN показывает английские тексты', (
    WidgetTester tester,
  ) async {
    final AppLocalizations ru = await localizationsFor(const Locale('ru'));
    final AppLocalizations en = await pumpApp(
      tester,
      locale: const Locale('en'),
    );

    expect(find.text(en.accountsEmpty), findsOneWidget);
    expect(find.text(ru.accountsEmpty), findsNothing);
    expect(find.text(en.navTransactions), findsWidgets);
  });
}
