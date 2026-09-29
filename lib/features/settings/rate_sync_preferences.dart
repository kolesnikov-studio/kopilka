import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/preferences_json.dart';
import 'package:path/path.dart' as p;

// Персист настройки синхронизации курсов (D-36, M4-шаг 2 — UI).
// Хранение — файл в каталоге поддержки: те же соображения, что для
// настройки проверки обновлений — новая зависимость (shared_preferences)
// не нужна, схему БД менять нельзя без миграции. Один ключ в отдельном
// файле: не смешиваем с update-preferences.json, чтобы шаг 1 (контроллер)
// и будущая автосинхронизация не зависели от формата чужих настроек.

/// Имя файла настроек в [RateSyncPreferencesStore.baseDirectory].
const String _fileName = 'rate-sync-preferences.json';

const String _keyEnabled = 'enabled';

/// Хранилище opt-in настройки синхронизации курсов (D-36: по умолчанию
/// выкл; состояние держит [rateSyncEnabledProvider], файл — истина между
/// запусками).
class RateSyncPreferencesStore {
  RateSyncPreferencesStore({required this.baseDirectory});

  /// Каталог, в котором лежит файл настроек (в тестах — временный).
  final Directory baseDirectory;

  File get _file => File(p.join(baseDirectory.path, _fileName));

  Future<Map<String, dynamic>> _readAll() => readPreferencesJson(_file);

  Future<void> _writeAll(Map<String, dynamic> values) =>
      writePreferencesJson(_file, values);

  /// Включена ли синхронизация курсов (D-36: по умолчанию выкл).
  Future<bool> readEnabled() async => (await _readAll())[_keyEnabled] == true;

  Future<void> writeEnabled(bool enabled) async => _writeAll(
        <String, dynamic>{...(await _readAll()), _keyEnabled: enabled},
      );
}

/// Провайдер хранилища; создаётся в `main` (платформенный путь) и
/// передаётся override'ом — тот же приём, что у каталога автобэкапа.
/// Загрузку значения в состояние выполняет [RateSyncEnabledController.load]
/// из контроллерного файла — экран вызывает её при старте, как у
/// автопроверки обновлений.
final rateSyncPreferencesStoreProvider = Provider<RateSyncPreferencesStore>(
  (ref) {
    throw UnimplementedError(
      'создаётся в main: RateSyncPreferencesStore(baseDirectory: getApplicationSupportDirectory())',
    );
  },
);
