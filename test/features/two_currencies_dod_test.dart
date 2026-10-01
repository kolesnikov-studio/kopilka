// DoD-сценарий M3 «учёт в двух валютах end-to-end» (ROADMAP M3, шаг 7).
//
// Полный пользовательский путь над живыми потоками (харнесс S2: in-memory
// drift, RU-локаль): к базовому RUB добавляется USD с курсом, счёт в USD
// пополняется, RUB→USD переводится с конвертацией (D-17, две суммы),
// расходы — в обеих валютах, на категорию с USD-расходами — бюджет.
// Проверки DoD: список операций показывает суммы в валюте операции,
// отчёты — в базовой с пометкой «по текущему курсу» (B5), прогресс
// бюджета — в базовой (D-18/D-19), смена курса USD пересчитывает
// агрегаты и бюджет живым потоком (D-18: readsFrom currencies).
//
// Данные сеются DAO (пути ввода покрыты тестами форм шагов 3–4): тест
// проверяет показ и живой пересчёт, а не контроллеры ввода. Ожидания
// сумм — только через formatMoneyMinor (§7: неразрывные пробелы).
import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import '../helpers/app_harness.dart';

/// Ожидание суммы — только через форматтер (§7, грабли).
String _money(AppHarness app, int amountMinor, {String symbol = '₽'}) =>
    formatMoneyMinor(amountMinor, symbol: symbol, locale: 'ru');

/// Сценарий DoD одной жизнью в двух валютах (курс USD задаёт вызывающий
/// тест — последний шаг проверяет пересчёт при его смене):
/// - пополнение USD-счёта: +50,00 $;
/// - перевод RUB→USD с конвертацией: 5 000,00 ₽ → 50,00 $ (D-17);
/// - расходы «Еда» в обеих валютах: 1 000,00 ₽ и 10,00 $;
/// - бюджет «Еда»: 3 000,00 ₽ базовой (лимит не конвертируется, D-19).
Future<void> _seedTwoCurrencyLife(AppHarness app) async {
  await app.db.currenciesDao.create(code: 'USD', symbol: r'$', rateToBase: 100);
  final Account rub = await app.db.accountsDao.create(
    name: 'Рубли',
    kind: AccountKind.cash,
    currencyCode: baseCurrencyCode,
    initialBalanceMinor: 1000000, // 10 000,00 ₽
  );
  final Account usd = await app.db.accountsDao.create(
    name: 'Доллары',
    kind: AccountKind.bank,
    currencyCode: 'USD',
  );
  final Category income = await app.db.categoriesDao.create(
    name: 'Подработка',
    kind: CategoryKind.income,
  );
  final Category food = await app.db.categoriesDao.create(
    name: 'Еда',
    kind: CategoryKind.expense,
  );
  await app.db.transactionsDao.create(
    type: TransactionType.income,
    accountId: usd.id,
    categoryId: income.id,
    amountMinor: 5000, // +50,00 $
  );
  await app.db.transactionsDao.create(
    type: TransactionType.transfer,
    accountId: rub.id,
    targetAccountId: usd.id,
    amountMinor: 500000, // 5 000,00 ₽
    targetAmountMinor: 5000, // → 50,00 $
  );
  await app.db.transactionsDao.create(
    type: TransactionType.expense,
    accountId: rub.id,
    categoryId: food.id,
    amountMinor: 100000, // 1 000,00 ₽
  );
  await app.db.transactionsDao.create(
    type: TransactionType.expense,
    accountId: usd.id,
    categoryId: food.id,
    amountMinor: 1000, // 10,00 $
  );
  await app.db.budgetsDao.create(
    categoryId: food.id,
    limitMinor: 300000, // 3 000,00 ₽ базовой
  );
}

Future<void> _openReports(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navReports).last);
  await tester.pumpAndSettle();
}

Future<void> _openTransactions(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navTransactions).last);
  await tester.pumpAndSettle();
}

/// Прокручивает дашборд до карточки бюджетов и возвращает finds-контекст
/// строки прогресса «потрачено / лимит».
Finder _budgetRow(AppHarness app, int spentMinor, int limitMinor) =>
    find.text('${_money(app, spentMinor)} / ${_money(app, limitMinor)}');

void main() {
  testWidgets('DoD: операции и балансы счетов — в валюте операции/счёта', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
      tempDirPrefix: 'kopilka_dod_two_currencies',
    );
    await _seedTwoCurrencyLife(app);
    await tester.pumpAndSettle();

    // Вкладка счетов (стартовая): каждый баланс — по экспоненту и символу
    // своей валюты (B3): 10 000 − 5 000 − 1 000 = 4 000,00 ₽;
    // 50 + 50 − 10 = 90,00 $.
    expect(find.text(_money(app, 400000)), findsOneWidget);
    expect(find.text(_money(app, 9000, symbol: r'$')), findsOneWidget);

    // Список операций: суммы в валюте операции (B4.3), перевод — парой.
    await _openTransactions(tester, app);
    expect(find.text('+ ${_money(app, 5000, symbol: r'$')}'), findsOneWidget);
    expect(find.text(_money(app, 500000)), findsOneWidget);
    expect(find.text(_money(app, 5000, symbol: r'$')), findsOneWidget);
    expect(find.text('− ${_money(app, 100000)}'), findsOneWidget);
    expect(find.text('− ${_money(app, 1000, symbol: r'$')}'), findsOneWidget);
  });

  testWidgets(
    'DoD: отчёты и бюджет — в базовой, у отчётов пометка «по текущему курсу»',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_dod_two_currencies',
      );
      await _seedTwoCurrencyLife(app);
      await tester.pumpAndSettle();
      await _openReports(tester, app);

      // Общий баланс: 4 000,00 ₽ + 90,00 $ × 100 = 13 000,00 ₽ (D-18).
      expect(find.text(_money(app, 1300000)), findsOneWidget);
      // Пометка «по текущему курсу» (B5) на карточках отчётов есть…
      expect(find.text(app.l10n.reportsAtCurrentRate), findsAtLeastNWidgets(1));
      // …«Всего» доната: 1 000,00 ₽ + 10,00 $ × 100 = 2 000,00 ₽.
      expect(
        find.text('${app.l10n.reportsTotalLabel}: ${_money(app, 200000)}'),
        findsOneWidget,
      );

      // Прогресс бюджета — в базовой против лимита базовой (D-19):
      // 2 000,00 ₽ / 3 000,00 ₽; пометки на карточке бюджетов нет (B6).
      await tester.ensureVisible(find.text(app.l10n.budgetsTitle));
      await tester.pumpAndSettle();
      expect(_budgetRow(app, 200000, 300000), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final Finder budgetsCard = find
          .ancestor(
            of: find.text(app.l10n.budgetsTitle),
            matching: find.byType(Card),
          )
          .first;
      expect(
        find.descendant(
          of: budgetsCard,
          matching: find.text(app.l10n.reportsAtCurrentRate),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'DoD: смена курса USD пересчитывает отчёты и бюджет живым потоком',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_dod_two_currencies',
      );
      await _seedTwoCurrencyLife(app);
      await tester.pumpAndSettle();
      await _openReports(tester, app);

      // До смены курса: 13 000,00 ₽ и бюджет 2 000,00 / 3 000,00 ₽.
      expect(find.text(_money(app, 1300000)), findsOneWidget);
      await tester.ensureVisible(find.text(app.l10n.budgetsTitle));
      await tester.pumpAndSettle();
      expect(_budgetRow(app, 200000, 300000), findsOneWidget);

      // Курс USD 100 → 200 правкой справочника: потоки читают currencies
      // (D-18), пересчёт — без перезапуска экрана.
      await app.db.currenciesDao.updateCurrency(
        'USD',
        rateToBase: const Value<double>(200),
      );
      await tester.pumpAndSettle();

      // Баланс: 4 000,00 ₽ + 90,00 $ × 200 = 22 000,00 ₽.
      expect(find.text(_money(app, 2200000)), findsOneWidget);
      // «Всего» доната: 1 000,00 ₽ + 10,00 $ × 200 = 3 000,00 ₽.
      expect(
        find.text('${app.l10n.reportsTotalLabel}: ${_money(app, 300000)}'),
        findsOneWidget,
      );
      // Бюджет: 1 000,00 ₽ + 10,00 $ × 200 = 3 000,00 ₽ — ровно лимит
      // (порог превышения, isOver ещё false).
      expect(_budgetRow(app, 300000, 300000), findsOneWidget);

      // Суммы операций заморожены (D-16/D-17): в списке по-прежнему
      // 10,00 $ и пара перевода 5 000,00 ₽ → 50,00 $.
      await _openTransactions(tester, app);
      expect(find.text('− ${_money(app, 1000, symbol: r'$')}'), findsOneWidget);
      expect(find.text(_money(app, 500000)), findsOneWidget);
      expect(find.text(_money(app, 5000, symbol: r'$')), findsOneWidget);
    },
  );
}
