// Финальные тексты оповещений о перерасходе (M7-шаг D, D-118/D-130).
//
// Формулировки утверждены спекой шага D (ICU-plural, символ базовой
// валюты в {amount} — P3 D-124: общий форматтер `formatMoneyMinor`
// вместо чернового). Живой binding берёт локаль устройства — собственной
// настройки локали у приложения нет (app.dart следует системной) — и
// читает символ базовой валюты; механика-сервис текстов не знает
// (шов `OverBudgetBodyBuilder`).

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:kopilka/core/money.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Локаль устройства для текстов уведомлений (настройки локали нет —
/// MaterialApp использует системную): ближайшая поддерживаемая по языку,
/// иначе — первая поддерживаемая (шаблонная).
AppLocalizations deviceLocalizations() {
  final Locale device = PlatformDispatcher.instance.locale;
  for (final Locale supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == device.languageCode) {
      return lookupAppLocalizations(supported);
    }
  }
  return lookupAppLocalizations(AppLocalizations.supportedLocales.first);
}

/// Текст тела оповещения «близко к перерасходу» (D-118): при перерасходе
/// (K < 0) — отдельный ключ и абсолютная величина суммы. [remainingMinor]
/// и [daysLeft] — K и D из кандидата механики; [symbol] — символ базовой
/// валюты, его читает binding из `baseCurrencyStreamProvider` (D-130 §2).
String overBudgetBodyFor(
  AppLocalizations l10n, {
  required String categoryName,
  required int remainingMinor,
  required int daysLeft,
  required String symbol,
}) {
  // Форматтер общий с UI (P3 D-124 закрыт): группировка, символ базовой
  // и экспонент 2 — конвенция базовой валюты (§3/D-27); K и так в базовой.
  final String amount = formatMoneyMinor(
    remainingMinor.abs(),
    symbol: symbol,
    locale: l10n.localeName,
    exponent: defaultCurrencyExponent,
  );
  return remainingMinor < 0
      ? l10n.reminderOverBudgetExceededBody(categoryName, amount, daysLeft)
      : l10n.reminderOverBudgetBody(categoryName, amount, daysLeft);
}
