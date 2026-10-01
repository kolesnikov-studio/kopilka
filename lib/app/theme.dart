import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/theme_presets.dart';
import 'package:kopilka/features/settings/theme_preferences.dart';

// Темы приложения (M5, D-54 идея 1; спека дизайнера D-58 §2/§5).
// ThemeData строится по паре (пресет, основа): ColorScheme.fromSeed(seed)
// + copyWith(surface, onSurface); пресет «default» ничего не подменяет —
// вид v0.4 (чистый fromSeed) не меняется. Персист — отдельный файл
// theme-preferences.json (theme_preferences.dart, образец D-43).

/// Светлая тема для пары (пресет, светлая основа).
///
/// «default» подмен не делает: схема равна прежней
/// `ColorScheme.fromSeed(seedColor)` — ноль отличий от v0.4.
ThemeData lightThemeOf(ThemePreset preset) => _themeFor(
  scheme: ColorScheme.fromSeed(seedColor: preset.seed),
  surface: preset.lightSurface,
  onSurface: preset.lightOnSurface,
);

/// Тёмная тема для пары (пресет, тёмная основа).
ThemeData darkThemeOf(ThemePreset preset) => _themeFor(
  scheme: ColorScheme.fromSeed(
    seedColor: preset.seed,
    brightness: Brightness.dark,
  ),
  surface: preset.darkSurface,
  onSurface: preset.darkOnSurface,
);

ThemeData _themeFor({
  required ColorScheme scheme,
  required Color? surface,
  required Color? onSurface,
}) {
  if (surface == null || onSurface == null) {
    return ThemeData(colorScheme: scheme);
  }
  return ThemeData(
    colorScheme: scheme.copyWith(surface: surface, onSurface: onSurface),
  );
}

/// Пара тем выбранного пресета для MaterialApp (theme/darkTheme);
/// пересобирается при смене пресета.
final themePairProvider = Provider<ThemePair>((ref) {
  final ThemeState theme = ref.watch(themeProvider);
  return ThemePair(
    light: lightThemeOf(theme.preset),
    dark: darkThemeOf(theme.preset),
  );
});

/// Пара тем одного пресета.
class ThemePair {
  const ThemePair({required this.light, required this.dark});

  final ThemeData light;

  final ThemeData dark;
}

/// Текущая тема: пресет + основа — два поля состояния (§5 спеки).
/// По умолчанию — системная основа и пресет «default» (первый запуск /
/// файла нет — ноль отличий от v0.4).
class ThemeState {
  const ThemeState({this.preset = defaultPreset, this.mode = ThemeMode.system});

  final ThemePreset preset;

  final ThemeMode mode;

  ThemeState copyWith({ThemePreset? preset, ThemeMode? mode}) =>
      ThemeState(preset: preset ?? this.preset, mode: mode ?? this.mode);
}

/// Контроллер темы: любое изменение применяется ко всему приложению
/// немедленно и персистится сразу (§4 спеки).
class ThemeController extends Notifier<ThemeState> {
  @override
  ThemeState build() => const ThemeState();

  /// Читает файл настроек — один раз при старте приложения из `main`
  /// (стейт нужен до первого кадра). Битый JSON / чужой id / IOException
  /// молча дают значения по умолчанию (§4 спеки, паттерн T-2/D-43.г).
  Future<void> load() async {
    final ThemePreferencesStore store = ref.read(themePreferencesStoreProvider);
    final String? presetId = await store.readPresetId();
    final ThemeMode? mode = await store.readMode();
    state = ThemeState(
      preset: themePresetById(presetId ?? '') ?? const ThemeState().preset,
      mode: mode ?? ThemeMode.system,
    );
  }

  /// Сменить пресет: применяется немедленно, персист — сразу (§4 спеки).
  Future<void> setPreset(ThemePreset preset) async {
    state = state.copyWith(preset: preset);
    await ref.read(themePreferencesStoreProvider).writePresetId(preset.id);
  }

  /// Сменить основу (Системная/Светлая/Тёмная): немедленно и с персистом.
  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    await ref.read(themePreferencesStoreProvider).writeMode(mode);
  }
}

/// Провайдер темы (пресет + основа).
final themeProvider = NotifierProvider<ThemeController, ThemeState>(
  ThemeController.new,
);

/// Основа темы — для MaterialApp и SegmentedButton настроек.
final themeModeProvider = Provider<ThemeMode>(
  (ref) => ref.watch(themeProvider.select((ThemeState state) => state.mode)),
);
