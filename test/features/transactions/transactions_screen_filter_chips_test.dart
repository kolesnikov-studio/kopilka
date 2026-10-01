// Виджет-тесты чипов фильтров истории (M5-шаг 7б, спека D-68).
//
// D-68.а: чип «Все» — первый в ленте, выбран при type == null, тап
// снимает фильтр типа (всегда видимый способ сброса, не повторный тап
// по активному чипу).
//
// D-68.б: CTA пустого отфильтрованного результата «Показать все
// операции» снимает ВСЕ фильтры — тип, счёт и поиск: кнопка,
// оставляющая активным фильтр, из-за которого список пуст, ничего бы
// не меняла. После снятия пустым остаётся только список без операций —
// штатное U1-разветвление (признак filtered) не трогается.
//
// Харнесс общий (S2, test/helpers/app_harness.dart): in-memory БД,
// RU-локаль; окно 600×1000 — как в тестах строк перевода.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';

import '../../helpers/app_harness.dart';

/// Ожидание суммы — только через форматтер (§7, грабли): группировка
/// неразрывными пробелами, литералы с обычным пробелом не равны.
String _amount(int amountMinor) =>
    formatMoneyMinor(amountMinor, symbol: '₽', locale: 'ru');

Future<void> _openTransactionsTab(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navTransactions).last);
  await tester.pumpAndSettle();
}

/// Состояние выделения чипа типа по его тексту (D-68.а: «Все» выбран
/// при type == null, пресет — при своём типе).
FilterChip _chipByText(WidgetTester tester, AppHarness app, String text) =>
    tester.widget<FilterChip>(
      find.ancestor(of: find.text(text), matching: find.byType(FilterChip)),
    );

void main() {
  testWidgets('D-68.б: CTA пустого результата снимает тип, счёт и поиск', (
    WidgetTester tester,
  ) async {
    // Окно 600×1000 (H1, D-70.б: чип счёта прижат Spacer'ом к правому
    // краю ленты и виден на узком окне; раньше ради этого ленты нужен
    // был тест-стенд 800px).
    final AppHarness app = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
      tempDirPrefix: 'kopilka_tx_chips_test',
    );
    final Account rub = await app.db.accountsDao.create(
      name: 'Рубли',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );
    final Account card = await app.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: baseCurrencyCode,
    );
    // Доход на «Рубли», расход на «Карта»: комбинация
    // «Расходы + счёт Рубли» заведомо пуста, поиск добавляет третье.
    await app.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: rub.id,
      amountMinor: 70000,
    );
    await app.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: card.id,
      amountMinor: 5000,
    );
    await _openTransactionsTab(tester, app);
    expect(find.textContaining(_amount(5000)), findsOneWidget);

    // Фильтр типа: «Расходы».
    await tester.tap(find.text(app.l10n.filterExpenses));
    await tester.pumpAndSettle();

    // Фильтр счёта: меню чипа «Все счета» → «Рубли».
    await tester.tap(find.text(app.l10n.filterAllAccounts));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Рубли'));
    await tester.pumpAndSettle();

    // Фильтр поиска: заведомо непопадающая строка.
    await tester.enterText(find.byType(TextField), 'неттакойзаметки');
    await tester.pumpAndSettle();

    // Пусто по фильтру: текст и новый CTA (D-68.б).
    expect(find.text(app.l10n.transactionsEmptyFiltered), findsOneWidget);
    expect(find.byIcon(Icons.filter_alt_off), findsOneWidget);
    expect(find.text(app.l10n.transactionsEmptyFilteredAction), findsOneWidget);

    // CTA снимает все три фильтра одним жестом.
    await tester.tap(find.text(app.l10n.transactionsEmptyFilteredAction));
    await tester.pumpAndSettle();

    // Список снова полный: обе операции видны.
    expect(find.textContaining(_amount(5000)), findsOneWidget);
    expect(find.textContaining(_amount(70000)), findsOneWidget);
    // Поиск очищен (setSearch(''), а не только тип/счёт): состояние
    // фильтра пусто целиком.
    final TransactionsFilterState state = app.container.read(
      transactionsFilterProvider,
    );
    expect(state.search, isEmpty);
    expect(state.type, isNull);
    expect(state.accountId, isNull);
    // Чип счёта вернулся к «Все счета», чип «Все» снова выбран.
    expect(find.text(app.l10n.filterAllAccounts), findsOneWidget);
    expect(_chipByText(tester, app, app.l10n.filterAll).selected, isTrue);
    // Текст пустого отфильтрованного состояния ушёл.
    expect(find.text(app.l10n.transactionsEmptyFiltered), findsNothing);
  });

  testWidgets('H1 (D-70.б): чип счёта видим на 600×1000 без прокрутки ленты', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
      tempDirPrefix: 'kopilka_tx_chips_test',
    );
    final Account rub = await app.db.accountsDao.create(
      name: 'Рубли',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );
    await app.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: rub.id,
      amountMinor: 70000,
    );
    await _openTransactionsTab(tester, app);

    // Чип счёта в видимой зоне ленты: прижат к правому краю (вне
    // зоны прокрутки чипов типа) и доступен тапу без прокрутки —
    // до H1 на 600px он уходил за край за чипами типа.
    final Finder accountChip = find.text(app.l10n.filterAllAccounts);
    expect(accountChip, findsOneWidget);
    final Rect chipRect = tester.getRect(accountChip);
    expect(chipRect.right, lessThanOrEqualTo(600 - 16));
    expect(chipRect.left, greaterThanOrEqualTo(16));

    // И меню фильтра счёта действительно открывается тапом (пункт
    // меню ищем в PopupMenuItem: текст «Рубли» есть и в плитке
    // операции под меню).
    await tester.tap(accountChip);
    await tester.pumpAndSettle();
    final Finder menuRub = find.widgetWithText(PopupMenuItem<String>, 'Рубли');
    expect(menuRub, findsOneWidget);
    await tester.tap(menuRub);
    await tester.pumpAndSettle();

    // Фильтр применился: чип показывает имя счёта и подсвечен
    // (текст «Рубли» и в заголовке плитки — ищем внутри Chip).
    final Finder chipRub = find.descendant(
      of: find.byType(Chip),
      matching: find.text('Рубли'),
    );
    expect(chipRub, findsOneWidget);
    final Chip chip = tester.widget<Chip>(
      find.ancestor(of: chipRub, matching: find.byType(Chip)),
    );
    expect(chip.backgroundColor, isNotNull);
  });

  testWidgets('D-68.а: чип «Все» — видимый сброс фильтра типа', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
      tempDirPrefix: 'kopilka_tx_chips_test',
    );
    final Account rub = await app.db.accountsDao.create(
      name: 'Рубли',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );
    await app.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: rub.id,
      amountMinor: 70000,
    );
    await app.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: rub.id,
      amountMinor: 5000,
    );
    await _openTransactionsTab(tester, app);

    // Без фильтра типа выбран чип «Все».
    expect(_chipByText(tester, app, app.l10n.filterAll).selected, isTrue);

    // Пресет «Расходы» фильтрует список и снимает выделение с «Все».
    await tester.tap(find.text(app.l10n.filterExpenses));
    await tester.pumpAndSettle();
    expect(_chipByText(tester, app, app.l10n.filterExpenses).selected, isTrue);
    expect(_chipByText(tester, app, app.l10n.filterAll).selected, isFalse);
    expect(find.textContaining(_amount(5000)), findsOneWidget);
    expect(find.textContaining(_amount(70000)), findsNothing);

    // Тап по «Все» возвращает обе операции (setType(null)).
    await tester.tap(find.text(app.l10n.filterAll));
    await tester.pumpAndSettle();
    expect(_chipByText(tester, app, app.l10n.filterAll).selected, isTrue);
    expect(find.textContaining(_amount(5000)), findsOneWidget);
    expect(find.textContaining(_amount(70000)), findsOneWidget);
  });

  testWidgets('D-68.б: контроллер clearAll сбрасывает тип, счёт и поиск', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_tx_chips_test',
    );
    final TransactionsFilterController notifier = app.container.read(
      transactionsFilterProvider.notifier,
    );
    notifier.setType(TransactionType.expense);
    notifier.setAccount('acc-1');
    notifier.setSearch('заметка');
    expect(notifier.state.type, TransactionType.expense);
    expect(notifier.state.accountId, 'acc-1');
    expect(notifier.state.search, 'заметка');

    notifier.clearAll();
    expect(notifier.state.type, isNull);
    expect(notifier.state.accountId, isNull);
    expect(notifier.state.search, isEmpty);
  });
}
