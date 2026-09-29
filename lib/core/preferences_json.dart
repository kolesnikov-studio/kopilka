import 'dart:convert';
import 'dart:io';

/// Общий хелпер preferences-файлов (D-43, D-62, §8 D-66.в): чтение и запись
/// JSON-словаря настроек в каталоге поддержки с единым глушением отказов.
///
/// Контракт поведения (замки T-2, D-48):
/// - файла нет, недоступна ФС ([IOException]) или битый JSON
///   ([FormatException]) — «молча значения по умолчанию»: возвращается
///   пустой словарь, запись при недоступной ФС просто не сохраняется;
///   настройка не критична, падать из-за неё нельзя нигде, не только в main;
/// - JSON не словарь (например, список) — тоже пустой словарь;
/// - запись — [File.writeAsString] с `flush: true`, формат файла —
///   `jsonEncode` словаря.
///
/// Потребители: update_preferences.dart, rate_sync_preferences.dart,
/// theme_preferences.dart (каждый — своё имя файла и свои ключи; формат
/// чужих настроек не зависит от нашего, D-43).
Future<Map<String, dynamic>> readPreferencesJson(File file) async {
  try {
    if (!await file.exists()) {
      return <String, dynamic>{};
    }
    final Object? decoded = jsonDecode(await file.readAsString());
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  } on IOException {
    return <String, dynamic>{};
  } on FormatException {
    return <String, dynamic>{};
  }
}

/// Записывает словарь настроек в [file]; отказ ФС глушится — см. контракт
/// [readPreferencesJson].
Future<void> writePreferencesJson(File file, Map<String, dynamic> values) async {
  try {
    await file.writeAsString(jsonEncode(values), flush: true);
  } on IOException {
    // Настройка не критична: при недоступной ФС просто не сохранится.
  }
}
