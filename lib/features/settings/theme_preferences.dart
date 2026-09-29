import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/preferences_json.dart';
import 'package:path/path.dart' as p;

// Персист пресета и основы темы (M5, D-54 идея 1, спека D-58 §4).
// Хранение — файл в каталоге поддержки, единый паттерн настроек офиса
// (D-43: update-preferences.json, rate-sync-preferences.json): формат
// чужих настроек не зависит от нашей, схему БД менять не нужно; в бэкап
// тема не входит — настройка приложения, а не данные.

/// Имя файла настроек в [ThemePreferencesStore.baseDirectory].
const String _fileName = 'theme-preferences.json';

const String _keyPreset = 'preset';

const String _keyMode = 'mode';

/// Хранилище темы: пресет (id из theme_presets.dart) и основа
/// ([ThemeMode]; в файле — имя значения: system|light|dark). Файл —
/// истина между запусками; состояние держит [ThemeController]
/// (theme.dart), load — из main до runApp.
class ThemePreferencesStore {
  ThemePreferencesStore({required this.baseDirectory});

  /// Каталог, в котором лежит файл настроек (в тестах — временный).
  final Directory baseDirectory;

  File get _file => File(p.join(baseDirectory.path, _fileName));

  Future<Map<String, dynamic>> _readAll() => readPreferencesJson(_file);

  Future<void> _writeAll(Map<String, dynamic> values) =>
      writePreferencesJson(_file, values);

  /// Id пресета из файла; null — файла нет / ключа нет / не строка.
  /// Чужой id (не из справочника пресетов) отфильтровывает контроллер.
  Future<String?> readPresetId() async {
    final Object? value = (await _readAll())[_keyPreset];
    return value is String ? value : null;
  }

  Future<void> writePresetId(String id) async => _writeAll(
        <String, dynamic>{...(await _readAll()), _keyPreset: id},
      );

  /// Основа из файла; null — файла нет / ключа нет / чужая строка
  /// (молча значения по умолчанию, §4 спеки).
  Future<ThemeMode?> readMode() async {
    final Object? value = (await _readAll())[_keyMode];
    if (value is! String) {
      return null;
    }
    for (final ThemeMode mode in ThemeMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return null;
  }

  Future<void> writeMode(ThemeMode mode) async => _writeAll(
        <String, dynamic>{...(await _readAll()), _keyMode: mode.name},
      );
}

/// Провайдер хранилища; создаётся в `main` (платформенный путь) и
/// передаётся override'ом — тот же приём, что у остальных настроек.
final themePreferencesStoreProvider = Provider<ThemePreferencesStore>(
  (ref) {
    throw UnimplementedError(
      'создаётся в main: ThemePreferencesStore(baseDirectory: getApplicationSupportDirectory())',
    );
  },
);
