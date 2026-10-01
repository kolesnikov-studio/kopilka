// Разбор денежного ввода пользователя в минорные единицы (P2-2 аудита
// D-75: money.dart разделён на парсинг и форматирование; §3 — деньги
// в минорных int, float на хранение и в арифметику не попадает).

/// Экспонент валюты по умолчанию (M1/M2: все валюты — 2 знака).
const int defaultCurrencyExponent = 2;

final RegExp _whitespace = RegExp(r'[\s\u00A0\u202F]');

/// Паттерн суммы для экспонента [exponent]: целая часть до 15 разрядов,
/// дробная — до [exponent] знаков. Экспонент 0 запрещает дробную часть
/// целиком (D-15: валюты без копеек).
///
/// Лимит целой части — 15 разрядов: максимум ~10^15 мажорных единиц
/// с любым ISO-экспонентом (0–3) укладывается в int64 и исключает
/// переполнение `int.parse` (фикс P1: гигантский ввод `'999…9'`
/// в 30 знаков бросал FormatException вместо возврата null).
RegExp _amountPatternFor(int exponent) => exponent <= 0
    ? RegExp(r'^\d{1,15}$')
    : RegExp(r'^\d{1,15}(\.\d{1,' + exponent.toString() + r'})?$');

/// Разбирает ввод пользователя («1 234,56», «1234.5», «250») в минорные
/// единицы. Пробелы и неразрывные пробелы игнорируются, запятая считается
/// десятичным разделителем.
///
/// [exponent] — число знаков после разделителя у валюты (D-15): 2 — копейки,
/// 0 — валюты без дробной части (йены), 3 — динары. По умолчанию 2 —
/// текущее поведение всех вызовов.
///
/// Возвращает `null`, если ввод не является корректной положительной суммой
/// не более чем с [exponent] знаками после разделителя или целая часть
/// длиннее 15 разрядов. С `allowZero` ноль тоже считается
/// корректным (поле «новый начальный баланс» при редактировании счёта:
/// начальный баланс может быть нулевым).
int? parseAmountToMinor(
  String input, {
  bool allowZero = false,
  int exponent = defaultCurrencyExponent,
}) {
  final String normalized = input
      .replaceAll(_whitespace, '')
      .replaceAll(',', '.');
  if (!_amountPatternFor(exponent).hasMatch(normalized)) {
    return null;
  }
  final List<String> parts = normalized.split('.');
  final int major = int.parse(parts.first);
  final String fraction = parts.length > 1
      ? parts[1].padRight(exponent, '0')
      : '0' * exponent;
  final int minor =
      major * pow10(exponent) + (exponent > 0 ? int.parse(fraction) : 0);
  return allowZero || minor > 0 ? minor : null;
}

/// 10 в степени [exponent] (экспоненты ISO 4217 — 0..3, int-возведение).
int pow10(int exponent) {
  int result = 1;
  for (int i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}
