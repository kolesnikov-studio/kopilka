// Виджет-тесты секции «Тема» в настройках (M5, D-58): сегменты основы
// и сетка карточек-пресетов, мгновенное применение без снека.
//
// Грабли fake_async (как в rate_sync_ui_test.dart): реальный файловый
// I/O внутри testWidgets не завершается — тап меняет состояние
// синхронно, запись файла не нужна сценарию (персист покрыт
// theme_controller_test.dart); временный каталог — через runAsync.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/theme.dart';
import 'package:kopilka/app/theme_presets.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/rate_sync_preferences.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/settings_screen.dart';
import 'package:kopilka/features/settings/theme_preferences.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

const ValueKey<String> _segmentsKey = ValueKey<String>('themeModeSegments');

Future<(ProviderContainer, AppLocalizations)> _pump(WidgetTester tester) async {
  tester.platformDispatcher.localeTestValue = const Locale('ru');
  tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final Directory tempDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_theme_widget'),
  ))!;
  addTearDown(
    () => tester.runAsync(() => tempDir.delete(recursive: true)),
  );

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);

  // Экран в initState грузит хранилища настроек — каждое нужно подменить
  // (иначе провайдер бросает UnimplementedError в тесте).
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider.overrideWithValue(
        AutoBackupDirectoryStore(baseDirectory: tempDir),
      ),
      updatePreferencesStoreProvider.overrideWithValue(
        UpdatePreferencesStore(baseDirectory: tempDir),
      ),
      rateSyncPreferencesStoreProvider.overrideWithValue(
        RateSyncPreferencesStore(baseDirectory: tempDir),
      ),
      themePreferencesStoreProvider.overrideWithValue(
        ThemePreferencesStore(baseDirectory: tempDir),
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
  return (
    container,
    await AppLocalizations.delegate.load(const Locale('ru')),
  );
}

void main() {
  testWidgets('секция «Тема» первая: основа, пресеты, выбран default (D-58)',
      (WidgetTester tester) async {
    final (ProviderContainer container, AppLocalizations l10n) =
        await _pump(tester);

    // Первая секция списка: заголовок «Тема» у верхней кромки, сегменты
    // под ним, пункт «Валюты» — ниже всей секции темы.
    expect(find.text(l10n.themeSectionTitle), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(l10n.themeSectionTitle)).dy,
      lessThan(100),
      reason: 'секция «Тема» — первая секция списка (D-58 §1)',
    );
    expect(
      tester.getTopLeft(find.byKey(_segmentsKey)).dy,
      greaterThan(tester.getTopLeft(find.text(l10n.themeSectionTitle)).dy),
    );
    expect(
      tester.getTopLeft(find.text(l10n.currenciesScreenTitle)).dy,
      greaterThan(tester.getTopLeft(find.byKey(_segmentsKey)).dy),
      reason: '«Валюты» — после секции «Тема» (D-58 §1)',
    );

    // Сегменты основы: три подписи, выбрана системная.
    expect(find.text(l10n.themeModeSystem), findsOneWidget);
    expect(find.text(l10n.themeModeLight), findsOneWidget);
    expect(find.text(l10n.themeModeDark), findsOneWidget);
    expect(
      tester
          .widget<SegmentedButton<ThemeMode>>(find.byKey(_segmentsKey))
          .selected,
      <ThemeMode>{ThemeMode.system},
    );

    // Метка пресетов и все шесть карточек с именами из l10n.
    expect(find.text(l10n.themePresetsLabel), findsOneWidget);
    expect(find.text(l10n.themePresetDefault), findsOneWidget);
    expect(find.text(l10n.themePresetOcean), findsOneWidget);
    expect(find.text(l10n.themePresetSunset), findsOneWidget);
    expect(find.text(l10n.themePresetAmethyst), findsOneWidget);
    expect(find.text(l10n.themePresetGraphite), findsOneWidget);
    expect(find.text(l10n.themePresetRose), findsOneWidget);

    // Выбран default: у него галочка, у остальных карточек — нет.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('themePreset-default')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(container.read(themeProvider).preset, same(defaultPreset));
  });

  testWidgets('тап по карточке применяет пресет немедленно, без снека (D-58)',
      (WidgetTester tester) async {
    final (ProviderContainer container, AppLocalizations l10n) =
        await _pump(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('themePreset-ocean')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    final ThemeState state = container.read(themeProvider);
    expect(state.preset, same(oceanPreset));
    // Галочка переехала на выбранную карточку; снека нет.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('themePreset-ocean')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text(l10n.rateSyncUpdated(1)), findsNothing);
  });

  testWidgets('сегмент «Тёмная» меняет основу немедленно (D-58)',
      (WidgetTester tester) async {
    final (ProviderContainer container, AppLocalizations l10n) =
        await _pump(tester);

    await tester.tap(find.text(l10n.themeModeDark));
    await tester.pumpAndSettle();

    expect(container.read(themeProvider).mode, ThemeMode.dark);
    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(
      tester
          .widget<SegmentedButton<ThemeMode>>(find.byKey(_segmentsKey))
          .selected,
      <ThemeMode>{ThemeMode.dark},
    );
    expect(find.byType(SnackBar), findsNothing);
  });
}
