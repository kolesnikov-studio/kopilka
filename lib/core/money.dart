import 'package:intl/intl.dart';

// Деньги в минорных единицах (копейки/центы), §3: хранение и вычисления —
// только INTEGER, float для денег запрещён. double ниже используется
// исключительно при форматировании готовой суммы для показа на экране —
// на хранение и арифметику он не попадает.

/// Сколько минорных единиц в одной мажорной (M1: все валюты — 2 знака).
const int minorUnitsPerMajor = 100;

final RegExp _whitespace = RegExp(r'[\s\u00A0\u202F]');
final RegExp _amountPattern = RegExp(r'^\d+(\.\d{1,2})?$');

/// Разбирает ввод пользователя («1 234,56», «1234.5», «250») в минорные
/// единицы. Пробелы и неразрывные пробелы игнорируются, запятая считается
/// десятичным разделителем.
///
/// Возвращает `null`, если ввод не является корректной положительной суммой
/// не более чем с двумя знаками после разделителя. С `allowZero` ноль тоже
/// считается корректным (поле «новый начальный баланс» при редактировании
/// счёта: начальный баланс может быть нулевым).
int? parseAmountToMinor(String input, {bool allowZero = false}) {
  final String normalized =
      input.replaceAll(_whitespace, '').replaceAll(',', '.');
  if (!_amountPattern.hasMatch(normalized)) {
    return null;
  }
  final List<String> parts = normalized.split('.');
  final int major = int.parse(parts.first);
  final String fraction =
      parts.length > 1 ? parts[1].padRight(2, '0') : '00';
  final int minor = major * minorUnitsPerMajor + int.parse(fraction);
  return allowZero || minor > 0 ? minor : null;
}

/// Форматирует сумму в минорных единицах для показа: группировка разрядов,
/// два знака после разделителя, символ валюты по правилам локали.
String formatMoneyMinor(
  int amountMinor, {
  required String symbol,
  required String locale,
}) {
  final NumberFormat formatter = NumberFormat.currency(
    locale: locale,
    symbol: symbol,
    decimalDigits: 2,
  );
  // double только здесь: готовая сумма округляется до 2 знаков при выводе.
  return formatter.format(amountMinor / minorUnitsPerMajor);
}
