import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/preferences_json.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';
import 'package:path/path.dart' as p;

// Персист opt-in настройки напоминаний (M6, D-83). Хранение — файл в
// каталоге поддержки по единому паттерну настроек офиса (D-43:
// update-preferences.json, rate-sync-preferences.json, theme-preferences.json):
// новая зависимость (shared_preferences) не нужна, схему БД менять нельзя.
// Один ключ в отдельном файле: формат чужих настроек не зависит от нашего,
// а механика напоминаний (D-83) не должна тянуть контроллеры чужих фич.

/// Имя файла настроек в [RemindersPreferencesStore.baseDirectory].
const String _fileName = 'reminders-preferences.json';

const String _keyEnabled = 'enabled';

/// Ключ состояния дедупа оповещений о перерасходе (D-118): карта
/// «ключ показа → дата последнего показа UTC»; отдельное поле расширения
/// (старый файл без поля = пусто).
const String _keyAlertLastShown = 'alert_last_shown';

/// Хранилище opt-in настройки напоминаний (D-83: по умолчанию выкл;
/// файл — истина между запусками, load() в main до runApp). Реализует
/// шов [RemindersPreferencesFake] (имя историческое — шов fake persistence
/// тест-замка Б2/D-80), чтобы сервис не зависел от файла в тестах.
class RemindersPreferencesStore implements RemindersPreferencesFake {
  RemindersPreferencesStore({required this.baseDirectory});

  /// Каталог, в котором лежит файл настроек (в тестах — временный).
  final Directory baseDirectory;

  File get _file => File(p.join(baseDirectory.path, _fileName));

  Future<Map<String, dynamic>> _readAll() => readPreferencesJson(_file);

  Future<void> _writeAll(Map<String, dynamic> values) =>
      writePreferencesJson(_file, values);

  /// Включены ли напоминания (D-83: по умолчанию выкл; битый/чужой JSON —
  /// «молча выкл» по §8.в — readPreferencesJson).
  @override
  Future<bool> readEnabled() async => (await _readAll())[_keyEnabled] == true;

  @override
  Future<void> writeEnabled(bool enabled) async =>
      _writeAll(<String, dynamic>{...(await _readAll()), _keyEnabled: enabled});

  /// Карта «ключ показа → дата последнего показа (UTC, `YYYY-MM-DD`)».
  /// Старый файл без поля, поле не карта или значения не строки — пусто
  /// (терпимость необязательных полей, образец v4/v5).
  @override
  Future<Map<String, String>> readAlertLastShown() async {
    final Object? raw = (await _readAll())[_keyAlertLastShown];
    if (raw is! Map) {
      return <String, String>{};
    }
    final Map<String, String> lastShown = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in raw.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is String && value is String) {
        lastShown[key] = value;
      }
    }
    return lastShown;
  }

  @override
  Future<void> writeAlertLastShown(Map<String, String> lastShown) async =>
      _writeAll(<String, dynamic>{
        ...(await _readAll()),
        _keyAlertLastShown: lastShown,
      });
}

/// Провайдер хранилища; создаётся в `main` (платформенный путь) и
/// передаётся override'ом — тот же приём, что у остальных настроек (D-43).
final remindersPreferencesStoreProvider = Provider<RemindersPreferencesStore>((
  ref,
) {
  throw UnimplementedError(
    'создаётся в main: RemindersPreferencesStore(baseDirectory: getApplicationSupportDirectory())',
  );
});
