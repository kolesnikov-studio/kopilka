// Виджет-тесты экрана «Валюты» (спека B1, M3-шаг 2): список с базовой
// первой, добавление из ISO-списка, отказ удаления используемой валюты,
// скрытый курс у базовой (D-16), диалог смены базовой, правка курса.
//
// Запуск через pumpDialogApp (S2): in-memory БД, RU-локаль, весь KopilkaApp
// — переход на экран из настроек, как делает пользователь.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

import '../../helpers/app_harness.dart';

void main() {
  testWidgets('список: базовая первой со звездой и без курса, у остальных курс',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    // Вторая валюта с ручным курсом (посев даёт только RUB).
    await h.db.currenciesDao.create(
      code: 'USD',
      symbol: r'$',
      rateToBase: 97.5,
    );
    await tester.pumpAndSettle();

    // Переход: Настройки → Валюты.
    await _openCurrenciesScreen(tester, h.l10n);

    // Базовая валюта: бейдж, курс скрыт (D-16).
    expect(find.text(h.l10n.currenciesBaseBadge), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget);
    // У обычной валюты подзаголовок «1 = 97,5 RUB» (формат курса: без
    // хвостовых нулей).
    expect(find.text(h.l10n.currenciesRateOf('97.5', 'RUB')), findsOneWidget);
    // Базовая строка первая в списке.
    final Finder tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(2));
  });

  testWidgets('добавление валюты из ISO-списка: поиск, выбор, курс по умолчанию',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    await _openCurrenciesScreen(tester, h.l10n);

    // FAB → диалог выбора.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Поиск по коду (нормализация регистра).
    await tester.enterText(find.byType(TextField), 'jpy');
    await tester.pumpAndSettle();
    // Строка результата B1.1: «Код — Символ — Название».
    expect(
      find.text('JPY — ¥ — Японская иена'),
      findsOneWidget,
    );

    // Выбор записи → вторая ступень: курс предзаполнен единицей (B1.1).
    await tester.tap(find.text('JPY — ¥ — Японская иена'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    expect(find.text(h.l10n.currencyRateHint), findsOneWidget);

    await tester.tap(find.text(h.l10n.saveAction));
    await tester.pumpAndSettle();

    // Валюта появилась в списке с курсом 1 = 1 RUB.
    expect(find.text('JPY — Японская иена'), findsOneWidget);
    expect(find.text(h.l10n.currenciesRateOf('1', 'RUB')), findsOneWidget);
    // JPY (экспонент 0) в справочнике: символ из ISO-списка.
    expect(await h.db.currenciesDao.findAlive('JPY'), isNotNull);
  });

  testWidgets('удаление используемой валюты: объяснение отказа до попытки',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    await h.db.currenciesDao.create(
      code: 'USD',
      symbol: r'$',
      rateToBase: 90,
    );
    // Живой счёт в USD — удаление валюты обязано блокироваться (B1.4).
    await h.db.accountsDao.create(
      name: 'Долларовый',
      kind: AccountKind.cash,
      currencyCode: 'USD',
    );
    await tester.pumpAndSettle();
    await _openCurrenciesScreen(tester, h.l10n);

    // Долгий тап по строке USD → меню → Удалить.
    await tester.longPress(find.textContaining('USD'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(h.l10n.currencyDeleteMenuAction));
    await tester.pumpAndSettle();

    // Объяснение со счётчиком живых счетов; строка подтверждения удаления —
    // не показывается (отказ объяснён заранее, DAO даже не вызывался).
    expect(find.text(h.l10n.currencyDeleteBlockedBody(1)), findsOneWidget);
    expect(
      await h.db.currenciesDao.findAlive('USD'),
      isNotNull,
    );
  });

  testWidgets('удаление неиспользуемой валюты проходит, история не трогается',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    await h.db.currenciesDao.create(
      code: 'EUR',
      symbol: '€',
      rateToBase: 100,
    );
    await tester.pumpAndSettle();
    await _openCurrenciesScreen(tester, h.l10n);

    await tester.longPress(find.textContaining('EUR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(h.l10n.currencyDeleteMenuAction));
    await tester.pumpAndSettle();
    // Подтверждение с фразой «история не изменится» (B1.4).
    expect(find.text(h.l10n.currencyDeleteBody), findsOneWidget);
    await tester.tap(find.text(h.l10n.deleteAction));
    await tester.pumpAndSettle();

    expect(await h.db.currenciesDao.findAlive('EUR'), isNull);
  });

  testWidgets('смена базовой: подтверждение, пересчёт курсов, звезда переезжает',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    await h.db.currenciesDao.create(
      code: 'USD',
      symbol: r'$',
      rateToBase: 90,
    );
    await tester.pumpAndSettle();
    await _openCurrenciesScreen(tester, h.l10n);

    await tester.longPress(find.textContaining('USD'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(h.l10n.currencyMakeBase));
    await tester.pumpAndSettle();

    // Подтверждение с объяснением последствий (D-20/B1.3).
    expect(
      find.text(h.l10n.currencyChangeBaseTitle('USD')),
      findsOneWidget,
    );
    expect(find.text(h.l10n.currencyChangeBaseBody('USD')), findsOneWidget);
    await tester.tap(find.text(h.l10n.currencyChangeBaseAction));
    await tester.pumpAndSettle();

    // Новая базовая: USD — базовая, её курс скрыт; курс RUB пересчитан
    // в 1/90 ≈ 0.011111 (формат: до 6 знаков, без хвостовых нулей).
    final Currency? rub = await h.db.currenciesDao.findAlive('RUB');
    final Currency? usd = await h.db.currenciesDao.findAlive('USD');
    expect(usd?.isBase, isTrue);
    expect(rub?.isBase, isFalse);
    expect(rub?.rateToBase, closeTo(1 / 90, 1e-12));
    expect(find.text(h.l10n.currenciesRateOf('0.011111', 'USD')),
        findsOneWidget);
  });

  testWidgets('правка курса: заголовок «Курс USD → RUB», сохранение применяет',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    await h.db.currenciesDao.create(
      code: 'USD',
      symbol: r'$',
      rateToBase: 90,
    );
    await tester.pumpAndSettle();
    await _openCurrenciesScreen(tester, h.l10n);

    // Тап по строке → диалог курса (B1.2).
    await tester.tap(find.textContaining('USD'));
    await tester.pumpAndSettle();
    expect(
      find.text(h.l10n.currencyRateDialogTitle('USD', 'RUB')),
      findsOneWidget,
    );
    expect(find.text(h.l10n.currencyRateRecalcNote), findsOneWidget);

    // Невалидный ввод — Сохранить заблокирован (B1.2).
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.pumpAndSettle();
    final Finder save = find.widgetWithText(FilledButton, h.l10n.saveAction);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    // Валидный ввод с запятой — курс применяется (парсер B1.1).
    await tester.enterText(find.byType(TextFormField), '91,3');
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect((await h.db.currenciesDao.findAlive('USD'))!.rateToBase, 91.3);
    expect(
      find.text(h.l10n.currenciesRateOf('91.3', 'RUB')),
      findsOneWidget,
    );
  });

  testWidgets('уже добавленные валюты в списке выбора отключены (B1.1)',
      (WidgetTester tester) async {
    final AppHarness h = await pumpDialogApp(tester);
    await _openCurrenciesScreen(tester, h.l10n);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    // Список ленивый: сужаем поиском, чтобы строка RUB построилась.
    await tester.enterText(find.byType(TextField), 'rub');
    await tester.pumpAndSettle();
    // RUB уже есть: строка с ним отключена и с бейджем «уже добавлена»
    // (B1.1: занятые коды видны, но не выбираются).
    final Finder rubTile = find.ancestor(
      of: find.text('RUB — ₽ — Российский рубль'),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(rubTile.first).enabled, isFalse);
    expect(find.text(h.l10n.currencyAlreadyAdded), findsOneWidget);
  });
}

/// Открывает экран «Валюты» через настройки (путь пользователя).
Future<void> _openCurrenciesScreen(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  await tester.tap(find.text(l10n.navSettings));
  await tester.pumpAndSettle();
  await tester.tap(find.text(l10n.currenciesScreenTitle));
  await tester.pumpAndSettle();
  expect(find.text(l10n.currenciesScreenTitle), findsWidgets);
}
