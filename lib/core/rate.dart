import 'package:intl/intl.dart';

// Курс к базовой валюте (D-16): число, а не деньги — int-правило §3 на него
// не распространяется. Отдельный парсер/форматтер (B1.1): decimal 1–6 знаков
// после разделителя, запятая и точка равнозначны, пробелы игнорируются.

final RegExp _whitespace = RegExp(r'[\s\u00A0\u202F]');

/// Паттерн курса: целая часть до 12 разрядов, дробная — 1–6 знаков.
final RegExp _ratePattern = RegExp(r'^\d{1,12}(\.\d{1,6})?$');

/// Разбирает ввод курса («97,5», «0.012345», «1») в double.
///
/// Возвращает `null`, если ввод не является положительным числом
/// с 1–6 знаками после разделителя (B1.1) либо не помещается в double.
double? parseRate(String input) {
  final String normalized = input
      .replaceAll(_whitespace, '')
      .replaceAll(',', '.');
  if (!_ratePattern.hasMatch(normalized)) {
    return null;
  }
  final double value = double.tryParse(normalized) ?? 0;
  return value > 0 ? value : null;
}

/// Форматирует курс для показа на экране «Валюты» (B1: подзаголовок строки
/// «1 = 97,50 RUB»): до 6 значащих знаков после разделителя, хвостовые нули
/// отбрасываются — «97,5» не превращается в «97,500000», а «1» остаётся «1».
/// Точность 6 знаков — максимум, принимаемый парсером ввода.
String formatRate(double rate) {
  final NumberFormat formatter = NumberFormat('0.######', 'en');
  return formatter.format(rate);
}
