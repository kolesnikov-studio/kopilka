import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Цвет-основа фирменной палитры (накопления, деньги).
const Color seedColor = Color(0xFF2E7D32);

/// Светлая тема приложения.
final ThemeData lightTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: seedColor),
);

/// Тёмная тема приложения.
final ThemeData darkTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
  ),
);

/// Текущий режим темы: по умолчанию следует системной настройке.
class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;

  void setMode(ThemeMode mode) => state = mode;
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);
