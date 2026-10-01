// Виджет-замки карточек дашборда M6-шага D (P2-2, D-97).
//
// InterestReminderCard: показ по «дата ≤ сегодня UTC» (D-93.2) и скрытие
// «Не сейчас» до конца сессии (D-89.2).
//
// AdviceCard: скрыт при живом накопительном счёте (UI-фильтр D-92.2),
// CTA открывает форму счёта с преселектом «Накопительный» (D-92.3).
//
// Харнесс общий (test/helpers/app_harness.dart): in-memory БД, RU-локаль;
// даты в БД — строки UTC (§3), просрочка напоминания штатна (D-81).
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/reports/insights_cards.dart';

import '../../helpers/app_harness.dart';

void main() {
  testWidgets(
    'D-97: карточка-напоминание показывается на просроченную дату UTC',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_insights_cards_test',
      );

      // Стабилизация (находка 5/D-102, класс флейка D-100): дата
      // «сегодня − 1 день» вместо «сегодня UTC» — по D-93.2 напоминание
      // живо весь сегодняшний день UTC (просрочка штатна, D-81), такая
      // дата показывается в любой момент прогона: в отличие от «сегодня»
      // она не может смениться при переходе полуночи UTC в середине теста.
      final DateTime now = DateTime.now().toUtc();
      final DateTime yesterdayUtc = DateTime.utc(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 1));
      await app.db.accountsDao.create(
        name: 'Вклад',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
        initialBalanceMinor: 100_00,
        interestReminderDate: yesterdayUtc,
      );

      // Карточки живут на вкладке «Отчёты» (стартовый маршрут — счета).
      await tester.tap(find.text(app.l10n.navReports).last);
      await tester.pumpAndSettle();

      expect(find.byType(InterestReminderCard), findsOneWidget);
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsOneWidget);
      // Тело содержит имя счёта (самый ранний срок — единственный счёт).
      expect(find.textContaining('Вклад'), findsOneWidget);
      // Скрытие пока не было — «Не сейчас» доступна.
      expect(
        find.widgetWithText(TextButton, app.l10n.remindersDismissAction),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'D-97: напоминание с будущей датой не рисуется, «Не сейчас» возвращает его',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_insights_cards_test',
      );

      await app.db.accountsDao.create(
        name: 'Вклад',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2100, 1, 2),
      );

      await tester.tap(find.text(app.l10n.navReports).last);
      await tester.pumpAndSettle();

      // Дата в будущем — карточки нет (заголовка нет; SizedBox.shrink
      // ничего не рисует, дашборд не роняет).
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsNothing);

      // Перенос даты в прошлое — карточка появляется по живому потоку
      // (дата фиксированная: стабильно в прошлом, полночь UTC не застаивает,
      // находка 5/D-102 её не касается).
      await app.db.accountsDao.updateAccount(
        (await app.db.accountsDao.getAlive()).single.id,
        interestReminderDate: Value<DateTime?>(DateTime.utc(2026, 9, 1)),
      );
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsOneWidget);

      // «Не сейчас» — скрытие до конца сессии (D-89.2): карточка исчезает
      // немедленно, без записи в БД.
      await tester.tap(
        find.widgetWithText(TextButton, app.l10n.remindersDismissAction),
      );
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.dashboardInterestCardTitle), findsNothing);
      expect(
        (await app.db.accountsDao.getAlive()).single.interestReminderDate,
        isNotNull,
        reason: 'скрытие — только в памяти (D-89.2), дата в БД не тронута',
      );
    },
  );

  testWidgets(
    'D-97: карточка совета скрыта, пока жив накопительный счёт (D-92.2)',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_insights_cards_test',
      );

      // Обычный счёт с суммой — дескриптор истинен, но жив и накопительный:
      // UI-фильтр прячет совет, иначе текст и CTA лгут его владельцу.
      await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        initialBalanceMinor: 500_00,
      );
      await app.db.accountsDao.create(
        name: 'Вклад',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2100, 1, 2),
      );

      await tester.tap(find.text(app.l10n.navReports).last);
      await tester.pumpAndSettle();

      expect(find.text(app.l10n.adviceMinBalanceTitle), findsNothing);
      expect(find.byType(AdviceCard), findsOneWidget);

      // Мягкое удаление накопительного — фильтр открыт, совет появляется.
      await app.db.accountsDao.softDelete(
        (await app.db.accountsDao.getAlive())
            .firstWhere((Account a) => a.interestReminderDate != null)
            .id,
      );
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.adviceMinBalanceTitle), findsOneWidget);
    },
  );

  testWidgets(
    'D-97: CTA совета открывает форму с преселектом «Накопительный» (D-92.3)',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_insights_cards_test',
      );

      await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        initialBalanceMinor: 500_00,
      );

      await tester.tap(find.text(app.l10n.navReports).last);
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.adviceMinBalanceTitle), findsOneWidget);

      // CTA — форма создания счёта (не правка существующего).
      await tester.tap(find.text(app.l10n.adviceMinBalanceAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(app.l10n.accountAdd),
        ),
        findsOneWidget,
      );

      // Преселект CTA (D-92.3): тумблер «Накопительный» включён,
      // строка даты напоминания раскрыта.
      final SwitchListTile savingsTile = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey<String>('accountSavingsTile')),
      );
      expect(savingsTile.value, isTrue);
      expect(
        find.byKey(const ValueKey<String>('accountInterestDateRow')),
        findsOneWidget,
      );
    },
  );
}
