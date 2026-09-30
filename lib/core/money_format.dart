import 'package:intl/intl.dart';

import 'money_parse.dart' show defaultCurrencyExponent, pow10;

// Форматирование денежных сумм для показа на экране (P2-2 аудита D-75:
// money.dart разделён на парсинг и форматирование). double используется
// исключительно при форматировании готовой суммы — на хранение и
// арифметику он не попадает (§3).

/// Форматирует сумму в минорных единицах для показа: группировка разрядов,
/// [exponent] знаков после разделителя (D-15), символ валюты по правилам
/// локали.
String formatMoneyMinor(
  int amountMinor, {
  required String symbol,
  required String locale,
  int exponent = defaultCurrencyExponent,
}) {
  final NumberFormat formatter = NumberFormat.currency(
    locale: locale,
    symbol: symbol,
    decimalDigits: exponent,
  );
  // double только здесь: готовая сумма округляется до знаков экспонента
  // при выводе.
  return formatter.format(amountMinor / pow10(exponent));
}
