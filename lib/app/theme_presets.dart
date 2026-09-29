import 'package:flutter/material.dart';

// Пресеты тем приложения (M5, D-54 идея 1, спека дизайнера D-58 §2).
// Пресет — id-константа (как коды иконок D-56; после выпуска не
// переименовывать) + seed + фон/текст светлой и тёмной основ. Основа
// строится как ColorScheme.fromSeed(seed) с подменой surface/onSurface
// (см. theme.dart); «default» ничего не подменяет — вид v0.4 не меняется.
// Пары фон/текст — контраст ≥ 4.5:1 (WCAG, посчитан в спеке).

/// Цвет-основа фирменной палитры (накопления, деньги) — пресет «default».
const Color seedColor = Color(0xFF2E7D32);

/// Пресет темы: палитра по seed и фон/текст обеих основ (D-58 §2).
///
/// Поля фон/текст (surface/onSurface) — null только у пресета «default»:
/// подмены нет, схема равна чистому fromSeed.
class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.seed,
    this.lightSurface,
    this.lightOnSurface,
    this.darkSurface,
    this.darkOnSurface,
  });

  /// Константа-имя пресета; хранится в theme-preferences.json.
  final String id;

  /// Цвет-основа палитры пресета (кружок в карточке-превью).
  final Color seed;

  /// Фон светлой основы.
  final Color? lightSurface;

  /// Текст светлой основы.
  final Color? lightOnSurface;

  /// Фон тёмной основы.
  final Color? darkSurface;

  /// Текст тёмной основы.
  final Color? darkOnSurface;
}

/// «По умолчанию» — фирменный зелёный, вид v0.4 (fromSeed без подмен).
const ThemePreset defaultPreset = ThemePreset(id: 'default', seed: seedColor);

/// Ocean / Океан — синий.
const ThemePreset oceanPreset = ThemePreset(
  id: 'ocean',
  seed: Color(0xFF1565C0),
  lightSurface: Color(0xFFF4F8FC),
  lightOnSurface: Color(0xFF10202E),
  darkSurface: Color(0xFF0D1620),
  darkOnSurface: Color(0xFFDEE9F2),
);

/// Sunset / Закат — тёплый оранжевый.
const ThemePreset sunsetPreset = ThemePreset(
  id: 'sunset',
  seed: Color(0xFFE64A19),
  lightSurface: Color(0xFFFFF8F3),
  lightOnSurface: Color(0xFF2B1A12),
  darkSurface: Color(0xFF201511),
  darkOnSurface: Color(0xFFF3E4DC),
);

/// Amethyst / Аметист — фиолетовый.
const ThemePreset amethystPreset = ThemePreset(
  id: 'amethyst',
  seed: Color(0xFF5E35B1),
  lightSurface: Color(0xFFF7F5FC),
  lightOnSurface: Color(0xFF1D1830),
  darkSurface: Color(0xFF151223),
  darkOnSurface: Color(0xFFE4DFF2),
);

/// Graphite / Графит — нейтральный серый.
const ThemePreset graphitePreset = ThemePreset(
  id: 'graphite',
  seed: Color(0xFF455A64),
  lightSurface: Color(0xFFF6F7F8),
  lightOnSurface: Color(0xFF191C1F),
  darkSurface: Color(0xFF14171A),
  darkOnSurface: Color(0xFFE2E5E8),
);

/// Rose / Роза — розовый.
const ThemePreset rosePreset = ThemePreset(
  id: 'rose',
  seed: Color(0xFFC2185B),
  lightSurface: Color(0xFFFFF6F9),
  lightOnSurface: Color(0xFF2B1420),
  darkSurface: Color(0xFF1F1218),
  darkOnSurface: Color(0xFFF2DEE7),
);

/// Пресеты в порядке карточек сетки настроек («По умолчанию» первым).
const List<ThemePreset> themePresets = <ThemePreset>[
  defaultPreset,
  oceanPreset,
  sunsetPreset,
  amethystPreset,
  graphitePreset,
  rosePreset,
];

/// Пресет по id из файла настроек; чужой id — null (контроллер молча
/// возьмёт [defaultPreset], §4 спеки).
ThemePreset? themePresetById(String id) {
  for (final ThemePreset preset in themePresets) {
    if (preset.id == id) {
      return preset;
    }
  }
  return null;
}
