// Тест шва текстов оповещений о перерасходе (M7-шаг D, D-118/D-130):
// финальные l10n-ключи reminderOverBudgetBody / reminderOverBudgetExceededBody
// собираются с категорией, суммой со символом базовой валюты (шов symbol,
// P3 D-124) и ICU-plural по дням; RU и EN отличаются; перерасход —
// отдельная ветка с абсолютной величиной суммы.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/reminders/reminders_texts.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

Future<AppLocalizations> load(Locale locale) =>
    AppLocalizations.delegate.load(locale);

void main() {
  test('текст «осталось K на D дней»: категория, сумма с символом, дни — в обеих локалях', () async {
    final AppLocalizations ru = await load(const Locale('ru'));
    final AppLocalizations en = await load(const Locale('en'));

    final String ruBody = overBudgetBodyFor(
      ru,
      categoryName: 'Еда',
      remainingMinor: 123456, // 1 234,56 в базовой
      daysLeft: 5,
      symbol: '₽',
    );
    final String enBody = overBudgetBodyFor(
      en,
      categoryName: 'Food',
      remainingMinor: 123456,
      daysLeft: 5,
      symbol: '₽',
    );

    expect(ruBody, contains('Еда'));
    expect(ruBody, contains('234,56'));
    expect(ruBody, contains('5'));
    // Символ базовой валюты в сумме — решение D-130 §2.
    expect(ruBody, contains('₽'));
    // ICU-plural RU: для 5 дней — форма many.
    expect(ruBody, contains('дней'));
    expect(enBody, contains('Food'));
    expect(enBody, contains('234.56'));
    expect(enBody, contains('5'));
    expect(ruBody, isNot(enBody));
  });

  test(
    'один день: форма one в RU и EN (ICU-plural финальных текстов)',
    () async {
      final AppLocalizations ru = await load(const Locale('ru'));
      final AppLocalizations en = await load(const Locale('en'));

      expect(
        overBudgetBodyFor(
          ru,
          categoryName: 'Еда',
          remainingMinor: 100,
          daysLeft: 1,
          symbol: '₽',
        ),
        contains('день'),
      );
      expect(
        overBudgetBodyFor(
          en,
          categoryName: 'Food',
          remainingMinor: 100,
          daysLeft: 1,
          symbol: r'$',
        ),
        contains('1 day'),
      );
    },
  );

  test('перерасход: отдельный текст с абсолютной величиной суммы', () async {
    final AppLocalizations ru = await load(const Locale('ru'));

    final String near = overBudgetBodyFor(
      ru,
      categoryName: 'Еда',
      remainingMinor: 100,
      daysLeft: 3,
      symbol: '₽',
    );
    final String over = overBudgetBodyFor(
      ru,
      categoryName: 'Еда',
      remainingMinor: -500,
      daysLeft: 3,
      symbol: '₽',
    );

    expect(over, contains('5,00'));
    expect(over, isNot(near));
    // Минуса в тексте нет — формулировка берёт абсолютную величину.
    expect(over.contains('-5'), isFalse);
  });

  test('локаль устройства разрешается в поддерживаемую', () {
    final AppLocalizations device = deviceLocalizations();

    expect(
      AppLocalizations.supportedLocales.map(
        (Locale locale) => locale.languageCode,
      ),
      contains(device.localeName),
    );
  });
}
