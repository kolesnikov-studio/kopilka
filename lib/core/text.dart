/// Нормализует необязательное текстовое поле: пустая строка и пробелы
/// превращаются в `NULL`, чтобы в БД не было «пустых» значений вместо
/// отсутствующих (§3: колонки nullable там, где значение необязательно).
String? optionalText(String? value) {
  if (value == null) {
    return null;
  }
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
