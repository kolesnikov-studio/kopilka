// DoD-сценарий M6 «Накопления» end-to-end (ROADMAP M6, шаги C/D;
// решения D-86/D-89; образец — DoD-прогон M4 two_currencies_dod_test.dart).
//
// Полный пользовательский путь над живыми потоками (харнесс S2:
// pumpDialogApp — in-memory drift, RU-локаль, KopilkaApp целиком):
// 1. Совет «неснижаемый остаток» жив, пока нет накопительных счетов;
//    создание накопительного счёта через форму счёта (тумблер +
//    дата напоминания по умолчанию «сегодня UTC + 1 месяц», D-81)
//    скрывает совет (UI-фильтр D-92.2) и ставит бейдж «Накопительный».
// 2. Карточка-напоминание «Начисление процентов» появляется по дате
//    ≤ сегодня UTC (D-93.2); «Не сейчас» скрывает её до конца сессии
//    (D-89.2, без персиста).
// 3. Долг: создание через форму (тело + переплата), сводка секции
//    «к возврату» включает переплату, строка переплаты с суммой в
//    карточке (S2/D-101); гашение через диалог — при remaining == 0
//    чип «Погашен», после возврата платежа чип исчезает (UX §4.3/
//    D-90.3; точечный замок чип-моргания — debts_screen_test,
//    «находка 4/D-102»; здесь — пользовательский путь).
// 4. Мультивалютная сводка секции «Мне должны»: ₽ и $ — отдельные
//    корзины одной строки (§1; порядок корзин не фиксируем —
//    uuid-tie-break DAO, D-103).
//
// Продуктовый код не менялся. Ожидания сумм — только через
// formatMoneyMinor (§7: неразрывные пробелы); даты — UTC (§3).
// Тумблер — ensureVisible + tap по key (замки D-97, окно 600×1000).
// Дату напоминания для карточки переносим DAO, возврат платежа — DAO:
// форма правит дату датапикером (путь закрыт замками D-97), здесь
// проверяется показ/скрытие по живым потокам, а не пикер. «Вчера UTC»
// в БД — дата, стабильная при переходе полуночи UTC в середине теста
// (класс флейка D-100); подходящий счёт для совета сеется DAO (критерий
// дизайнера «баланс > 0», D-92 — на пустом наборе совета нет).
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import '../helpers/app_harness.dart';

/// Ожидание суммы — только через форматтер (§7, грабли).
String _money(AppHarness app, int amountMinor, {String symbol = '₽'}) =>
    formatMoneyMinor(amountMinor, symbol: symbol, locale: 'ru');

/// Полуночь текущего дня UTC (§3).
DateTime _todayUtc() {
  final DateTime now = DateTime.now().toUtc();
  return DateTime.utc(now.year, now.month, now.day);
}

/// Дрейф-потоки завершают future вне кадров (§7) — даём завершиться
/// и пересобрать провайдеров (образец _settle debts_screen_test).
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'DoD M6: совет и накопительный счёт с карточкой %, долг с гашением, '
    'переплата, чип «Погашен», мультивалютная сводка секции',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_dod_m6_savings',
      );

      // ---------- 1. Совет жив, пока нет накопительных счетов (D-84/D-92).
      //
      // Дескриптор совета требует подходящий счёт (критерий дизайнера
      // D-92: баланс > 0) — на пустом наборе совета нет. Сеем обычный
      // счёт с суммой через DAO (путь ввода закрыт замками форм U1/B2):
      // совет появляется на дашборде.
      await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        initialBalanceMinor: 500_00,
      );
      await tester.tap(find.text(app.l10n.navReports).last);
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.adviceMinBalanceTitle), findsOneWidget);

      // ---------- 2. Накопительный счёт через форму (FAB → тумблер → save).
      await tester.tap(find.text(app.l10n.navAccounts).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.nameLabel),
        'Вклад',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '100 000',
      );

      // Тумблер «Накопительный» (D-92): выключен → включение раскрывает
      // строку даты напоминания (ключи D-97).
      expect(
        find.byKey(const ValueKey<String>('accountInterestDateRow')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('accountSavingsTile')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('accountSavingsTile')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('accountInterestDateRow')),
        findsOneWidget,
      );

      // Сохранение: счёт накопительный, дата по умолчанию «сегодня UTC +
      // 1 календарный месяц» (D-81; кламп конца месяца D-102). Точную
      // арифметику не проверяем — она прикрыта DAO/фабрикой (D-99.2);
      // здесь — пользовательская видимость: дата в месячном окне от
      // сегодня UTC.
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      final Account saved = (await app.db.accountsDao.getAlive()).singleWhere(
        (Account a) => a.name == 'Вклад',
      );
      expect(saved.interestReminderDate, isNotNull);
      final DateTime reminderUtc = DateTime.parse(saved.interestReminderDate!)
          .toUtc();
      final int dayDiff = reminderUtc.difference(_todayUtc()).inDays;
      expect(dayDiff, inInclusiveRange(27, 32));

      // Плитка счёта — с бейджем «Накопительный» (§1).
      expect(find.text(app.l10n.accountSavingsBadge), findsOneWidget);

      // ---------- 3. Совет скрыт: жив накопительный счёт (D-92.2).
      await _settle(tester);
      await tester.tap(find.text(app.l10n.navReports).last);
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.adviceMinBalanceTitle), findsNothing);

      // ---------- 4. Карточка-напоминание по дате ≤ сегодня UTC (D-93.2).
      //
      // Дефолтная дата в будущем — карточки нет (показ по условию, не
      // по факту счёта). Переносим дату на «вчера UTC» DAO: «вчера»
      // показывается независимо от перехода полуночи UTC в середине
      // теста (класс флейка D-100).
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsNothing);
      await app.db.accountsDao.updateAccount(
        saved.id,
        interestReminderDate: Value<DateTime?>(
          _todayUtc().subtract(const Duration(days: 1)),
        ),
      );
      await _settle(tester);
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsOneWidget);

      // «Не сейчас» — скрытие до конца сессии (D-89.2, без персиста).
      await tester.tap(find.text(app.l10n.remindersDismissAction));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsNothing);

      // ---------- 5. Долг: раздел «Долги» → FAB → форма (тело + переплата).
      await tester.tap(find.text(app.l10n.navDebts).last);
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.debtsEmpty), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPersonLabel),
        'Аня',
      );
      // Тело 1 000,00 ₽ + переплата 50,00 ₽ (§2: переплата честно видна).
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtAmountLabel),
        '1 000',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtExtraLabel),
        '50',
      );
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await _settle(tester);

      // Секция «Мне должны»: к возврату тело + переплата одной корзиной.
      expect(
        find.text(app.l10n.debtSectionTotalTheyOweMe(_money(app, 105000))),
        findsOneWidget,
      );

      // ---------- 6. Мультивалютная сводка секции (§1/D-103).
      //
      // Второй долг в USD сеется DAO (сумма/валюта формы закрыты замками
      // форм; здесь — показ сводки по живому потоку).
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 100,
      );
      await app.db.debtsDao.create(
        person: 'Боря',
        direction: DebtDirection.theyOweMe,
        amountMinor: 5000,
        currencyCode: 'USD',
      );
      await _settle(tester);

      // Одна строка сводки секции с отдельными корзинами валют; порядок
      // корзин при равных createdAt не фиксируем (uuid-tie-break DAO,
      // D-103) — anyOf; требование §1 (одна строка, корзина на валюту)
      // не ослаблено.
      final String rub = _money(app, 105000);
      final String usd = _money(app, 5000, symbol: r'$');
      final Text totalText = tester.widget<Text>(
        find.textContaining(app.l10n.debtSectionTotalTheyOweMe('')),
      );
      expect(
        totalText.data,
        anyOf(
          app.l10n.debtSectionTotalTheyOweMe('$rub · $usd'),
          app.l10n.debtSectionTotalTheyOweMe('$usd · $rub'),
        ),
      );

      // ---------- 7. Карточка долга: переплата видна, чипа нет.
      await tester.tap(find.text('Аня'));
      await tester.pumpAndSettle();
      expect(
        find.text(app.l10n.debtExtraLine(_money(app, 5000))),
        findsOneWidget,
      );
      expect(find.text(app.l10n.debtPaidOffBadge), findsNothing);

      // ---------- 8. Гашение 1 050,00 ₽ (тело + переплата одним платежом).
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.debtPaymentAmountLabel),
        '1 050',
      );
      await tester.tap(find.text(app.l10n.debtRecordPaymentAction).last);
      await _settle(tester);

      // Остаток 0 → чип «Погашен» (§2/D-89).
      expect(find.text(app.l10n.debtPaidOffBadge), findsOneWidget);
      expect(
        find.text(app.l10n.debtRemainingLine(_money(app, 0))),
        findsOneWidget,
      );

      // ---------- 9. Возврат платежа — чип исчезает (UX §4.3/D-90.3).
      //
      // Одноразовые выборки живых строк (§7: не через watch-стрим).
      final Debt debt = (await tester.runAsync(
        () => app.db.debtsDao.watchAlive().first,
      ))!.singleWhere((Debt d) => d.person == 'Аня');
      final List<DebtPayment> payments =
          await tester.runAsync(
            () => app.db.debtsDao.watchPayments(debt.id).first,
          ) ??
          <DebtPayment>[];
      await app.db.debtsDao.softDeletePayment(payments.single.id);
      await _settle(tester);
      expect(find.text(app.l10n.debtPaidOffBadge), findsNothing);
    },
  );
}
