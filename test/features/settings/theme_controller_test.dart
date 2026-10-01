// Тесты темы-пресетов (M5, D-58): построение ThemeData по паре
// (пресет, mode), контроллер ThemeController (два поля состояния) и
// персист theme-preferences.json по образцу D-43. Реальный файловый
// I/O — только в обычных тестах (не testWidgets), как в
// rate_sync_controller_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/theme.dart';
import 'package:kopilka/app/theme_presets.dart';
import 'package:kopilka/features/settings/theme_preferences.dart';

ProviderContainer _container(Directory directory) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      themePreferencesStoreProvider.overrideWithValue(
        ThemePreferencesStore(baseDirectory: directory),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Directory _tempDir() {
  final Directory directory = Directory.systemTemp.createTempSync(
    'kopilka_theme_test',
  );
  addTearDown(() => directory.deleteSync(recursive: true));
  return directory;
}

void main() {
  group('построение ThemeData по паре (пресет, mode), D-58 §2', () {
    test('default — чистый fromSeed фирменного зелёного, вид v0.4', () {
      final ThemeData light = lightThemeOf(defaultPreset);
      final ThemeData dark = darkThemeOf(defaultPreset);

      expect(light.colorScheme, ColorScheme.fromSeed(seedColor: seedColor));
      expect(
        dark.colorScheme,
        ColorScheme.fromSeed(seedColor: seedColor, brightness: Brightness.dark),
      );
    });

    test('цветной пресет: seed задаёт палитру, фон/текст подменены', () {
      final ThemeData light = lightThemeOf(oceanPreset);
      final ThemeData dark = darkThemeOf(oceanPreset);

      expect(
        light.colorScheme,
        ColorScheme.fromSeed(seedColor: oceanPreset.seed).copyWith(
          surface: oceanPreset.lightSurface,
          onSurface: oceanPreset.lightOnSurface,
        ),
      );
      expect(
        dark.colorScheme,
        ColorScheme.fromSeed(
          seedColor: oceanPreset.seed,
          brightness: Brightness.dark,
        ).copyWith(
          surface: oceanPreset.darkSurface,
          onSurface: oceanPreset.darkOnSurface,
        ),
      );
    });

    test('справочник: 6 пресетов, «default» первый, чужой id — null', () {
      expect(themePresets.length, 6);
      expect(themePresets.first.id, 'default');
      expect(themePresetById('rose'), same(rosePreset));
      expect(themePresetById('no-such-preset'), isNull);
    });
  });

  group('контроллер темы (два поля состояния, §5 спеки)', () {
    test(
      'до load — системная основа и пресет default (первый запуск)',
      () async {
        final ProviderContainer container = _container(_tempDir());

        final ThemeState initial = container.read(themeProvider);
        expect(initial.preset, same(defaultPreset));
        expect(initial.mode, ThemeMode.system);
        expect(container.read(themeModeProvider), ThemeMode.system);
      },
    );

    test('setPreset и setMode применяются немедленно и пишут файл', () async {
      final Directory directory = _tempDir();
      final ProviderContainer container = _container(directory);

      await container.read(themeProvider.notifier).setPreset(oceanPreset);
      await container.read(themeProvider.notifier).setMode(ThemeMode.dark);

      final ThemeState state = container.read(themeProvider);
      expect(state.preset, same(oceanPreset));
      expect(state.mode, ThemeMode.dark);
      expect(container.read(themeModeProvider), ThemeMode.dark);

      final ThemePreferencesStore store = ThemePreferencesStore(
        baseDirectory: directory,
      );
      expect(await store.readPresetId(), 'ocean');
      expect(await store.readMode(), ThemeMode.dark);
    });

    test('load восстанавливает пресет и основу после «перезапуска»', () async {
      final Directory directory = _tempDir();
      final ProviderContainer first = _container(directory);
      await first.read(themeProvider.notifier).setPreset(graphitePreset);
      await first.read(themeProvider.notifier).setMode(ThemeMode.light);

      // «Перезапуск»: свежий контейнер с тем же каталогом настроек.
      final ProviderContainer second = _container(directory);
      final ThemeState beforeLoad = second.read(themeProvider);
      expect(beforeLoad.preset, same(defaultPreset));
      expect(
        beforeLoad.mode,
        ThemeMode.system,
        reason: 'до load состояние — значения по умолчанию',
      );
      await second.read(themeProvider.notifier).load();

      final ThemeState state = second.read(themeProvider);
      expect(state.preset, same(graphitePreset));
      expect(state.mode, ThemeMode.light);
    });

    test(
      'load при пустом каталоге (файла нет) — дефолты без исключений',
      () async {
        final ProviderContainer container = _container(_tempDir());

        await container.read(themeProvider.notifier).load();

        final ThemeState state = container.read(themeProvider);
        expect(state.preset, same(defaultPreset));
        expect(state.mode, ThemeMode.system);
      },
    );

    test('load с чужим id в файле — молча default (§4 спеки)', () async {
      final Directory directory = _tempDir();
      File('${directory.path}/theme-preferences.json').writeAsStringSync(
        jsonEncode(<String, dynamic>{'preset': 'neon-rainbow', 'mode': 'dark'}),
      );
      final ProviderContainer container = _container(directory);

      await container.read(themeProvider.notifier).load();

      final ThemeState state = container.read(themeProvider);
      expect(state.preset, same(defaultPreset));
      expect(state.mode, ThemeMode.dark, reason: 'основа валидна и читается');
    });
  });

  group('персист theme-preferences.json (образец D-43)', () {
    test('файл не создаётся до первого изменения (первый запуск)', () async {
      final Directory directory = _tempDir();
      final ThemePreferencesStore store = ThemePreferencesStore(
        baseDirectory: directory,
      );

      expect(await store.readPresetId(), isNull);
      expect(await store.readMode(), isNull);
      expect(
        File('${directory.path}/theme-preferences.json').existsSync(),
        isFalse,
      );
    });

    test('happy path: записанное читается тем же хранилищем', () async {
      final Directory directory = _tempDir();
      final ThemePreferencesStore store = ThemePreferencesStore(
        baseDirectory: directory,
      );

      await store.writePresetId('sunset');
      await store.writeMode(ThemeMode.dark);

      expect(await store.readPresetId(), 'sunset');
      expect(await store.readMode(), ThemeMode.dark);
      expect(
        jsonDecode(
          File('${directory.path}/theme-preferences.json').readAsStringSync(),
        ),
        <String, dynamic>{'preset': 'sunset', 'mode': 'dark'},
      );
    });

    test('битый JSON — чтение молча даёт null (T-2, D-43.г)', () async {
      final Directory directory = _tempDir();
      final File file = File('${directory.path}/theme-preferences.json');
      // Полусформированный/повреждённый файл: запись оборвалась.
      await file.writeAsString('{oops');
      final ThemePreferencesStore store = ThemePreferencesStore(
        baseDirectory: directory,
      );

      expect(await store.readPresetId(), isNull);
      expect(await store.readMode(), isNull);
    });

    test('чужой id и чужая строка mode не распознаются (§4 спеки)', () async {
      final Directory directory = _tempDir();
      final ThemePreferencesStore store = ThemePreferencesStore(
        baseDirectory: directory,
      );

      await store.writePresetId('no-such-preset');
      await store.writeMode(ThemeMode.dark); // поверх — перезапись целиком
      await store.writePresetId('sunset');
      await File('${directory.path}/theme-preferences.json').writeAsString(
        jsonEncode(<String, dynamic>{'preset': 'sunset', 'mode': 'sepia'}),
      );

      expect(await store.readPresetId(), 'sunset');
      expect(await store.readMode(), isNull);
    });
  });
}
