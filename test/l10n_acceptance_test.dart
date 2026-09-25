// Тест локализаций: обе локали грузятся, тексты навигации
// и заглушки непустые и отличаются между RU и EN. Эталон — сами загруженные
// локализации; литеральных строк в ожиданиях нет.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

Future<AppLocalizations> load(Locale locale) =>
    AppLocalizations.delegate.load(locale);

void main() {
  test('обе локали RU и EN загружаются', () async {
    final AppLocalizations ru = await load(const Locale('ru'));
    final AppLocalizations en = await load(const Locale('en'));

    // Объекты локализаций реально созданы для обеих локалей.
    expect(ru, isA<AppLocalizations>());
    expect(en, isA<AppLocalizations>());
    // Локали объявлены в supportedLocales.
    expect(
      AppLocalizations.supportedLocales.map((Locale l) => l.languageCode),
      containsAll(<String>['ru', 'en']),
    );
  });

  test('тексты навигации непустые и различаются между RU и EN', () async {
    final AppLocalizations ru = await load(const Locale('ru'));
    final AppLocalizations en = await load(const Locale('en'));

    expect(ru.navAccounts, isNotEmpty);
    expect(en.navAccounts, isNotEmpty);
    expect(ru.navAccounts, isNot(en.navAccounts));

    for (final ({String ru, String en}) pair in <({String ru, String en})>[
      (ru: ru.navTransactions, en: en.navTransactions),
      (ru: ru.navReports, en: en.navReports),
      (ru: ru.navSettings, en: en.navSettings),
      (ru: ru.categoriesTitle, en: en.categoriesTitle),
      (ru: ru.accountsEmpty, en: en.accountsEmpty),
      (ru: ru.transactionsEmpty, en: en.transactionsEmpty),
      (ru: ru.errorCategoryIsSystem, en: en.errorCategoryIsSystem),
      (ru: ru.errorAccountHasTransactions, en: en.errorAccountHasTransactions),
      (ru: ru.newTransferTitle, en: en.newTransferTitle),
    ]) {
      expect(pair.ru, isNotEmpty);
      expect(pair.en, isNotEmpty);
      expect(pair.ru, isNot(pair.en), reason: 'RU и EN тексты должны отличаться');
    }
  });

  test('четыре подписи навигации попарно различны в каждой локали', () async {
    final AppLocalizations ru = await load(const Locale('ru'));
    final AppLocalizations en = await load(const Locale('en'));

    final List<String> ruNav = <String>[
      ru.navAccounts,
      ru.navTransactions,
      ru.navReports,
      ru.navSettings,
    ];
    final List<String> enNav = <String>[
      en.navAccounts,
      en.navTransactions,
      en.navReports,
      en.navSettings,
    ];
    expect(ruNav.toSet().length, 4, reason: 'RU: подписи попарно различны');
    expect(enNav.toSet().length, 4, reason: 'EN: подписи попарно различны');
  });
}
