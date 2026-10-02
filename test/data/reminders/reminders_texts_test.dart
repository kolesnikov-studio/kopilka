// Тест шва текстов оповещений о перерасходе (M7-шаг B, D-118): черновые
// l10n-ключи reminderOverBudgetBody / reminderOverBudgetExceededBody
// собираются с категорией, суммой по правилам локали и днями; RU и EN
// отличаются; перерасход — отдельная ветка с абсолютной суммой.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/reminders/reminders_texts.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

Future<AppLocalizations> load(Locale locale) =>
    AppLocalizations.delegate.load(locale);

void main() {
  test('текст «осталось K на D дней»: категория, сумма, дни — в обеих локалях',
      () async {
    final AppLocalizations ru = await load(const Locale('ru'));
    final AppLocalizations en = await load(const Locale('en'));

    final String ruBody = overBudgetBodyFor(
      ru,
      categoryName: 'Еда',
      remainingMinor: 123456, // 1 234,56 в базовой
      daysLeft: 5,
    );
    final String enBody = overBudgetBodyFor(
      en,
      categoryName: 'Food',
      remainingMinor: 123456,
      daysLeft: 5,
    );

    expect(ruBody, contains('Еда'));
    expect(ruBody, contains('234,56'));
    expect(ruBody, contains('5'));
    expect(enBody, contains('Food'));
    expect(enBody, contains('234.56'));
    expect(enBody, contains('5'));
    expect(ruBody, isNot(enBody));
  });

  test('перерасход: отдельный текст с абсолютной величиной суммы', () async {
    final AppLocalizations ru = await load(const Locale('ru'));

    final String near = overBudgetBodyFor(
      ru,
      categoryName: 'Еда',
      remainingMinor: 100,
      daysLeft: 3,
    );
    final String over = overBudgetBodyFor(
      ru,
      categoryName: 'Еда',
      remainingMinor: -500,
      daysLeft: 3,
    );

    expect(over, contains('5,00'));
    expect(over, isNot(near));
    // Минуса в тексте нет — формулировка берёт абсолютную величину.
    expect(over.contains('-5'), isFalse);
  });

  test('локаль устройства разрешается в поддерживаемую', () {
    final AppLocalizations device = deviceLocalizations();

    expect(
      AppLocalizations.supportedLocales
          .map((Locale locale) => locale.languageCode),
      contains(device.localeName),
    );
  });
}
