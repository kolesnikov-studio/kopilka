import 'package:kopilka/core/money.dart';

export 'package:kopilka/core/iso_currencies.dart'
    show isoCurrencies, currencyNamesRu;

import 'package:kopilka/core/iso_currencies.dart';

// Справочник валют в core (D-15/D-23): код, символ, экспонент, названия.
// Это справочные данные, не интерфейсные тексты (D-23): .arb остаётся для
// интерфейса, словарь валют живёт здесь константой.
//
// Полный ISO-список (~157 записей, решение мейнтейнера 2026-09-26) живёт
// в `iso_currencies.dart` (данные) — здесь только тип записи и хелперы.

/// Справочная запись о валюте: свойства кода ISO 4217 (D-15).
///
/// Экспонент задаёт масштаб ввода/вывода: 0 — валюты без дробной части
/// (JPY), 2 — копейки/центы, 3 — динары (KWD). В БД не хранится —
/// это свойство кода валюты, а не записи справочника.
class CurrencyInfo {
  const CurrencyInfo({
    required this.code,
    required this.symbol,
    required this.exponent,
    required this.nameEn,
  });

  /// Код ISO 4217 (совпадает с PK таблицы `currencies`).
  final String code;

  /// Знак валюты для показа рядом с суммой.
  final String symbol;

  /// Число знаков после разделителя (ISO-экспонент).
  final int exponent;

  /// Официальное короткое английское название.
  final String nameEn;
}

/// Справка по коду; `null` — кода нет во встроенном списке.
CurrencyInfo? currencyInfoByCode(String code) {
  for (final CurrencyInfo info in isoCurrencies) {
    if (info.code == code) {
      return info;
    }
  }
  return null;
}

/// Экспонент валюты по коду; для кода вне справочника — экспонент по
/// умолчанию 2 (текущее поведение всех сумм, см. `money.dart`).
int currencyExponentByCode(String code) =>
    currencyInfoByCode(code)?.exponent ?? defaultCurrencyExponent;

/// Минорная сумма строкой в мажорных единицах — для предзаполнения полей
/// ввода и CSV-экспорта (A14). Знак сохраняется, дробная часть — ровно
/// [exponent] знаков (для экспонента 0 — целое число без разделителя).
String minorToMajorString(
  int amountMinor, {
  int exponent = defaultCurrencyExponent,
}) {
  final bool negative = amountMinor < 0;
  final int magnitude = negative ? -amountMinor : amountMinor;
  final int scale = _pow10(exponent);
  final String fraction = exponent > 0
      ? '.${(magnitude % scale).toString().padLeft(exponent, '0')}'
      : '';
  return '${negative ? '-' : ''}${magnitude ~/ scale}$fraction';
}

/// Конвертирует минорную сумму валюты-источника в минорные единицы базовой
/// валюты (D-18): |amount_minor| × rateToBase, округление half-up по модулю,
/// знак сохраняется отдельно (D-22). Базовая валюта текущих данных имеет
/// экспонент 2; [exponent] — экспонент валюты-источника (разница экспонентов
/// входит в масштаб: 1234 минорных динара = 1.234 мажорного).
///
/// double используется только в точке конвертации: курс — не деньги (§3),
/// результат всегда целый int.
int convertMinor(
  int amountMinor,
  double rateToBase, {
  int exponent = defaultCurrencyExponent,
}) {
  if (amountMinor == 0) {
    return 0;
  }
  final bool negative = amountMinor < 0;
  final int magnitude = negative ? -amountMinor : amountMinor;
  // Разница экспонентов источников: 10^2 / 10^exponent (экспонент 3 даёт
  // масштаб 0.1 — минорные динары в 10 раз крупнее минорных копеек).
  final double scale =
      _pow10(defaultCurrencyExponent) / _pow10(exponent);
  // round() округляет половину от положительного числа вверх — половину
  // вверх по модулю (D-22); знак вернём отдельно.
  final int converted = (magnitude * rateToBase * scale).round();
  return negative ? -converted : converted;
}

/// Прямая конвертация минорных сумм между валютами A и B по их курсам
/// к базовой (M3-шаг 4, предзаполнение второй суммы перевода, B4.1):
/// `amount × rateA ÷ rateB` — сперва в базовую (D-18, half-up по модулю
/// D-22), затем из базовой в валюту B (деление — обратная конвертация,
/// тоже half-up по модулю). [fromExponent]/[toExponent] — экспоненты
/// валют A и B: разница входит в масштаб по образцу [convertMinor].
///
/// double — только в точке конвертации: результат всегда целый int.
int convertMinorCross(
  int amountMinor,
  double fromRateToBase,
  double toRateToBase, {
  int fromExponent = defaultCurrencyExponent,
  int toExponent = defaultCurrencyExponent,
}) {
  if (amountMinor == 0) {
    return 0;
  }
  final bool negative = amountMinor < 0;
  final int magnitude = negative ? -amountMinor : amountMinor;
  // Шаг 1 — в базовую валюту: как [convertMinor] (half-up по модулю).
  final int inBase = convertMinor(
    magnitude,
    fromRateToBase,
    exponent: fromExponent,
  );
  // Шаг 2 — из базовой в валюту B: деление на курс, half-up по модулю;
  // знак вернём отдельно. Масштаб — как у конвертации в базу, но
  // с обратным отношением экспонентов (минорные единицы валюты B).
  final double scale = _pow10(toExponent) / _pow10(defaultCurrencyExponent);
  final int converted = (inBase / toRateToBase * scale).round();
  return negative ? -converted : converted;
}

/// Производный курс перевода A → B по двум введённым суммам (D-17):
/// «сколько мажорных B дают за один мажорный A» — для расчётной строки
/// формы перевода (B4.1, `transferRateLine`). Курс — не деньги (§3),
/// отношение считается в double; оба аргумента — положительные минорные
/// суммы, [fromExponent]/[toExponent] приводят их к мажорным единицам.
double derivedRate(
  int amountFromMinor,
  int amountToMinor, {
  int fromExponent = defaultCurrencyExponent,
  int toExponent = defaultCurrencyExponent,
}) {
  final double fromMajor =
      amountFromMinor / _pow10(fromExponent);
  final double toMajor = amountToMinor / _pow10(toExponent);
  return toMajor / fromMajor;
}

/// 10 в степени [exponent] (экспоненты ISO 4217 — 0..3, неотрицательные).
int _pow10(int exponent) {
  int result = 1;
  for (int i = 0; i < exponent; i++) {
    result *= 10;
  }
  return result;
}
