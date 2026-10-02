// Черновые тексты оповещений механики (M7-шаг B, D-118).
//
// Формулировки — предварительные: финальные утверждает спека шагов C/D
// (ключи l10n `reminderOverBudgetBody` / `reminderOverBudgetExceededBody`,
// EN с @description, RU без). Живой binding берёт локаль устройства —
// собственной настройки локали у приложения нет (app.dart следует
// системной) — и форматирует сумму по правилам локали; механика-сервис
// текстов не знает (шов `OverBudgetBodyBuilder`).

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:intl/intl.dart';
import 'package:kopilka/core/money.dart' show defaultCurrencyExponent;
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
/// и [daysLeft] — K и D из кандидата механики.
String overBudgetBodyFor(
  AppLocalizations l10n, {
  required String categoryName,
  required int remainingMinor,
  required int daysLeft,
}) {
  final String amount = _formatMinor(remainingMinor.abs(), l10n.localeName);
  return remainingMinor < 0
      ? l10n.reminderOverBudgetExceededBody(categoryName, amount, daysLeft)
      : l10n.reminderOverBudgetBody(categoryName, amount, daysLeft);
}

/// Сумма в минорных единицах базовой — строкой по правилам локали
/// (группировка, экспонент 2 — конвенция базовой валюты, D-27).
/// Символа валюты нет: подпись требует чтения справочника, которого
/// у механики нет, а K и так в базовой.
String _formatMinor(int amountMinor, String locale) {
  final NumberFormat format = NumberFormat.decimalPatternDigits(
    locale: locale,
    decimalDigits: defaultCurrencyExponent,
  );
  // Минорные единицы базовой → мажорные: экспонент базовой — 2 (§3/D-27).
  return format.format(amountMinor / 100);
}
