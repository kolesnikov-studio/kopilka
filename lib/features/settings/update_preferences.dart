import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

// Настройки проверки обновлений (§5). Хранение — файл в каталоге поддержки:
// те же соображения, что для каталога автобэкапа — новая зависимость
// (shared_preferences) не нужна, схему БД менять нельзя без миграции.

/// Имя файла настроек в [baseDirectory].
const String _fileName = 'update-preferences.json';

const String _keyEnabled = 'enabled';

const String _keyLastAutoCheck = 'lastAutoCheck';

const String _keyOfferShown = 'offerShown';

/// Хранилище настроек проверки обновлений: включённость автопроверки,
/// время последней автопроверки, показано ли предложение первого запуска.
class UpdatePreferencesStore {
  UpdatePreferencesStore({required this.baseDirectory});

  /// Каталог, в котором лежит файл настроек (в тестах — временный).
  final Directory baseDirectory;

  File get _file => File(p.join(baseDirectory.path, _fileName));

  Future<Map<String, dynamic>> _readAll() async {
    try {
      if (!await _file.exists()) {
        return <String, dynamic>{};
      }
      final Object? decoded = jsonDecode(await _file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on IOException {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> values) async {
    try {
      await _file.writeAsString(jsonEncode(values), flush: true);
    } on IOException {
      // Настройка не критична: при недоступной ФС просто не сохранится.
    }
  }

  /// Включена ли автопроверка (§5: по умолчанию выкл).
  Future<bool> readEnabled() async =>
      (await _readAll())[_keyEnabled] == true;

  Future<void> writeEnabled(bool enabled) async => _writeAll(
        <String, dynamic>{...(await _readAll()), _keyEnabled: enabled},
      );

  /// Время последней автопроверки; null — ещё не было.
  Future<DateTime?> readLastAutoCheck() async {
    final Object? value = (await _readAll())[_keyLastAutoCheck];
    if (value is! String) {
      return null;
    }
    final DateTime? parsed = DateTime.tryParse(value);
    return parsed?.toUtc();
  }

  Future<void> writeLastAutoCheck(DateTime moment) async => _writeAll(
        <String, dynamic>{
          ...(await _readAll()),
          _keyLastAutoCheck: moment.toUtc().toIso8601String(),
        },
      );

  /// Предложение первого запуска уже показано.
  Future<bool> readOfferShown() async =>
      (await _readAll())[_keyOfferShown] == true;

  Future<void> writeOfferShown() async => _writeAll(
        <String, dynamic>{...(await _readAll()), _keyOfferShown: true},
      );
}

/// Провайдер хранилища; создаётся в `main` (платформенный путь) и
/// передаётся override'ом — тот же приём, что у каталога автобэкапа.
final updatePreferencesStoreProvider = Provider<UpdatePreferencesStore>(
  (ref) {
    throw UnimplementedError(
      'создаётся в main: UpdatePreferencesStore(baseDirectory: getApplicationSupportDirectory())',
    );
  },
);

/// Настройка проверки обновлений: включена пользователем (§5: по умолчанию
/// выкл). Автопроверка раз в 7 дней выполняется только при включённой.
final autoUpdateCheckEnabledProvider =
    NotifierProvider<AutoUpdateCheckController, bool>(
  AutoUpdateCheckController.new,
);

class AutoUpdateCheckController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Устанавливает настройку и сохраняет её.
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await ref.read(updatePreferencesStoreProvider).writeEnabled(enabled);
  }

  /// Загружает настройку из хранилища (вызывается экраном при старте).
  Future<void> load() async {
    state = await ref.read(updatePreferencesStoreProvider).readEnabled();
  }
}

/// Предложение включить проверку обновлений при первом запуске (§5:
/// настройка по умолчанию выкл + предложение при первом запуске).
/// Показывается один раз — до выбора пользователя («включить» или «позже»).
final updateOfferControllerProvider =
    NotifierProvider<UpdateOfferController, bool>(UpdateOfferController.new);

class UpdateOfferController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Загружает состояние предложения; true — показать.
  Future<void> load() async {
    state = !await ref.read(updatePreferencesStoreProvider).readOfferShown();
  }

  /// Скрывает предложение и запоминает, что оно показано.
  Future<void> dismiss() async {
    state = false;
    await ref.read(updatePreferencesStoreProvider).writeOfferShown();
  }
}

/// Период автопроверки (§5): раз в 7 дней.
const Duration autoCheckInterval = Duration(days: 7);

/// Пора ли автопроверять обновления: включена настройка, с последней
/// проверки прошло не меньше [autoCheckInterval] (или проверки ещё не было).
bool isAutoCheckDue({
  required bool enabled,
  DateTime? lastCheck,
  required DateTime now,
}) =>
    enabled &&
    (lastCheck == null || now.difference(lastCheck) >= autoCheckInterval);
