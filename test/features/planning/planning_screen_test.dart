// Виджет-тесты раздела «Планирование» (M7-шаг C, D-127): пустое состояние,
// создание плана через форму с конверсией включительного периода в
// полуинтервал хранения (§3), перерасход/цель (§2), удаление долгим тапом,
// диалог автобюджета: нет данных и создание по среднему доходу (§4/D-121).
// Данные — живые потоки DAO; in-memory drift, RU-локаль (app_harness).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/core/money_format.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/transactions/transactions_screen.dart'
    show transferLine;
import 'package:kopilka/l10n/gen/app_localizations.dart';

import '../../helpers/app_harness.dart';

/// Строка суммы в базовой (посев даёт RUB с экспонентом 2) — как на экране.
String money(int minor) => formatMoneyMinor(minor, symbol: '₽', locale: 'ru');

/// Пункт нижней навигации по подписи (заголовок AppBar содержит тот же
/// текст — матчится только навигация).
Finder navItem(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

/// Открывает вкладку «Планирование» в живом приложении (app_harness).
Future<void> openPlanning(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(navItem(l10n.navPlanning));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('пустая база: пустое состояние, CTA, FAB и кнопка автобюджета', (
    WidgetTester tester,
  ) async {
    final AppHarness f = await pumpDialogApp(tester);
    final AppLocalizations l10n = f.l10n;

    await openPlanning(tester, l10n);

    expect(find.text(l10n.planningEmpty), findsOneWidget);
    expect(find.text(l10n.planningEmptyCta), findsOneWidget);
    expect(find.byTooltip(l10n.planningAddTooltip), findsOneWidget);
    // Автобюджет виден всегда, в том числе в пустом разделе (§1, D-54.17).
    expect(find.byTooltip(l10n.planningAutoTooltip), findsOneWidget);
  });

  testWidgets('создание плана: строка с периодом и конверсия периода (§3)', (
    WidgetTester tester,
  ) async {
    // Окно 600×1000 — прецедент U9: в узких 400px dropdown категории давал
    // RenderFlex-overflow, не связанный с сутью теста.
    final AppHarness f = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
    );
    final AppLocalizations l10n = f.l10n;
    await f.db.categoriesDao.create(
      name: 'Продукты',
      kind: CategoryKind.expense,
    );
    await openPlanning(tester, l10n);

    await tester.tap(find.byTooltip(l10n.planningAddTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.planningAddTitle), findsOneWidget);
    expect(find.text(l10n.planningKindHint), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Продукты').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '500');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    // Строка плана: план/факт/остаток в базовой, бейдж «Идёт» (текущий
    // месяц), включительный период локальными датами.
    expect(find.text(l10n.planningPlanLine(money(50000))), findsOneWidget);
    expect(find.text(l10n.planningFactLine(money(0))), findsOneWidget);
    expect(find.text(l10n.planningRemainingLine(money(50000))), findsOneWidget);
    expect(find.text(l10n.planningActiveBadge), findsOneWidget);
    final DateTime now = DateTime.now();
    final String startStr = DateFormat.yMd('ru')
        .format(DateTime(now.year, now.month));
    final String endStr = DateFormat.yMd('ru')
        .format(DateTime(now.year, now.month + 1, 0));
    expect(
      find.text(l10n.planningPeriodRange(startStr, endStr)),
      findsOneWidget,
    );

    // В хранении — полуинтервал UTC: конец включительной даты формы стал
    // первым днём следующего месяца (§3, calendarDayUtc).
    final List<Plan> rows = await f.db.select(f.db.plans).get();
    expect(rows, hasLength(1));
    expect(
      rows.single.periodStart,
      DateTime.utc(now.year, now.month, 1).toIso8601String(),
    );
    expect(
      rows.single.periodEnd,
      DateTime.utc(now.year, now.month + 1, 1).toIso8601String(),
    );
  });

  testWidgets('перерасход расходного плана: факт за период, красная строка', (
    WidgetTester tester,
  ) async {
    final AppHarness f = await pumpDialogApp(tester);
    final AppLocalizations l10n = f.l10n;
    final DateTime now = DateTime.now();
    final Category category = await f.db.categoriesDao.create(
      name: 'Кафе',
      kind: CategoryKind.expense,
    );
    final Account account = await f.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: 'RUB',
    );
    await f.db.plansDao.create(
      categoryId: category.id,
      periodStart: DateTime.utc(now.year, now.month),
      periodEnd: DateTime.utc(now.year, now.month + 1),
      amountMinor: 100000,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
      amountMinor: 150000,
      date: DateTime.utc(now.year, now.month, 15),
    );
    await openPlanning(tester, l10n);

    expect(find.text(l10n.planningSectionExpense), findsOneWidget);
    expect(find.text(l10n.planningFactLine(money(150000))), findsOneWidget);
    // Вместо остатка — перерасход (fact − plan), красным (§2).
    expect(find.text(l10n.planningOverByLine(money(50000))), findsOneWidget);
    expect(find.text(l10n.planningRemainingLine(money(50000))), findsNothing);
  });

  testWidgets('доходный план: секция доходов, цель достигнута', (
    WidgetTester tester,
  ) async {
    final AppHarness f = await pumpDialogApp(tester);
    final AppLocalizations l10n = f.l10n;
    final DateTime now = DateTime.now();
    final Category category = await f.db.categoriesDao.create(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );
    final Account account = await f.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: 'RUB',
    );
    await f.db.plansDao.create(
      categoryId: category.id,
      periodStart: DateTime.utc(now.year, now.month),
      periodEnd: DateTime.utc(now.year, now.month + 1),
      amountMinor: 100000,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: account.id,
      categoryId: category.id,
      amountMinor: 120000,
      date: DateTime.utc(now.year, now.month, 10),
    );
    await openPlanning(tester, l10n);

    // Две секции по направлению вида категории; пустая секция не рисуется.
    expect(find.text(l10n.planningSectionIncome), findsOneWidget);
    expect(find.text(l10n.planningSectionExpense), findsNothing);
    expect(
      find.text(l10n.planningGoalReachedLine(money(20000))),
      findsOneWidget,
    );
    // Цель достигнута — бар 100%.
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 1.0);
  });

  testWidgets('удаление: долгий тап, подтверждение, строка исчезает', (
    WidgetTester tester,
  ) async {
    final AppHarness f = await pumpDialogApp(tester);
    final AppLocalizations l10n = f.l10n;
    final DateTime now = DateTime.now();
    final Category category = await f.db.categoriesDao.create(
      name: 'Продукты',
      kind: CategoryKind.expense,
    );
    await f.db.plansDao.create(
      categoryId: category.id,
      periodStart: DateTime.utc(now.year, now.month),
      periodEnd: DateTime.utc(now.year, now.month + 1),
      amountMinor: 100000,
    );
    await openPlanning(tester, l10n);

    await tester.longPress(find.text('Продукты'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.planningDeleteTitle), findsOneWidget);
    expect(find.text(l10n.planningDeleteBody('Продукты')), findsOneWidget);
    await tester.tap(find.text(l10n.deleteAction));
    await tester.pumpAndSettle();

    // Строка исчезла из потока, раздел снова пуст.
    expect(find.text('Продукты'), findsNothing);
    expect(find.text(l10n.planningEmpty), findsOneWidget);
    final List<Plan> rows = await f.db.select(f.db.plans).get();
    expect(rows.single.deletedAt, isNotNull);
  });

  testWidgets('автобюджет: нет данных — состояние и кнопка неактивна', (
    WidgetTester tester,
  ) async {
    final AppHarness f = await pumpDialogApp(tester);
    final AppLocalizations l10n = f.l10n;
    await openPlanning(tester, l10n);

    await tester.tap(find.byTooltip(l10n.planningAutoTooltip));
    await tester.pumpAndSettle();

    expect(find.text(l10n.planningAutoTitle), findsOneWidget);
    expect(find.text(l10n.planningAutoIntro), findsOneWidget);
    expect(find.text(l10n.planningAutoNoData), findsOneWidget);
    final FilledButton create = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l10n.planningAutoCreateAction),
    );
    expect(create.onPressed, isNull);
  });

  testWidgets('автобюджет: средний доход, предзаполнение, создание плана', (
    WidgetTester tester,
  ) async {
    // Окно 600×1000 — прецедент U9: dropdown с длинными пунктами вида.
    final AppHarness f = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
    );
    final AppLocalizations l10n = f.l10n;
    final DateTime now = DateTime.now();
    final Category category = await f.db.categoriesDao.create(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );
    final Account account = await f.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: 'RUB',
    );
    // Закрытый месяц перед текущим с доходом: единственная база среднего.
    await f.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: account.id,
      categoryId: category.id,
      amountMinor: 300000,
      date: DateTime.utc(now.year, now.month - 1, 15),
    );
    await openPlanning(tester, l10n);

    await tester.tap(find.byTooltip(l10n.planningAutoTooltip));
    await tester.pumpAndSettle();

    // Строка расчёта честно показывает базу: один месяц с доходом.
    expect(
      find.text(l10n.planningAutoAverage(money(300000), 1)),
      findsOneWidget,
    );
    // Сумма предзаполнена «средний доход × срок» (6 мес. по умолчанию):
    // 3000,00 × 6 = 18000,00.
    expect(find.text('18000.00'), findsOneWidget);
    expect(
      find.text(l10n.planningAutoAmountHelper(money(300000), 6)),
      findsOneWidget,
    );

    // Категория — намерение пользователя, авто-угадывания нет (§4).
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${l10n.kindIncome} · Зарплата').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.planningAutoCreateAction));
    await tester.pumpAndSettle();

    // Успех: диалог закрыт, снек, строка в секции доходов.
    expect(find.text(l10n.planningAutoTitle), findsNothing);
    expect(find.text(l10n.planningAutoCreatedSnack), findsOneWidget);
    expect(find.text(l10n.planningSectionIncome), findsOneWidget);
    expect(find.text(l10n.planningPlanLine(money(1800000))), findsOneWidget);

    // План на срок с начала текущего месяца: [месяц, месяц + 6).
    final List<Plan> rows = await f.db.select(f.db.plans).get();
    expect(rows.single.amountMinor, 1800000);
    expect(
      rows.single.periodStart,
      DateTime.utc(now.year, now.month).toIso8601String(),
    );
    expect(
      rows.single.periodEnd,
      DateTime.utc(now.year, now.month + 6).toIso8601String(),
    );
  });

  testWidgets('D-133: нет переводов — секция отложенных не рисуется', (
    WidgetTester tester,
  ) async {
    final AppHarness f = await pumpDialogApp(tester);
    final AppLocalizations l10n = f.l10n;

    await openPlanning(tester, l10n);

    // Секция «Отложенные переводы» появляется только при строках.
    expect(find.text(l10n.planningTransfersSection), findsNothing);
  });

  testWidgets(
    'D-133: split по executedAt — ожидающие и исполненные в своих подсекциях, пустая не рисуется',
    (WidgetTester tester) async {
      final AppHarness f = await pumpDialogApp(tester);
      final AppLocalizations l10n = f.l10n;
      final Account from = await f.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      final Account to = await f.db.accountsDao.create(
        name: 'Копилка',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
      );

      await openPlanning(tester, l10n);

      // Ожидающий перевод (дата в будущем) — только подсекция «Ожидают».
      await f.db.scheduledTransfersDao.create(
        accountId: from.id,
        targetAccountId: to.id,
        amountMinor: 50000,
        executeAt: DateTime.utc(2100, 1, 1),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.planningTransfersSection), findsOneWidget);
      expect(find.text(l10n.planningTransfersPendingSection), findsOneWidget);
      expect(find.text(l10n.planningTransfersExecutedSection), findsNothing);

      // Исполненный (прошедшая дата + markExecuted) — появляется вторая
      // подсекция; комиссия — только в исполненной строке.
      final Transaction transfer = await f.db.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: from.id,
        targetAccountId: to.id,
        amountMinor: 30000,
        date: DateTime.utc(2026, 1, 1),
      );
      final Category commissionCategory = await f.db.categoriesDao.create(
        name: 'Комиссии',
        kind: CategoryKind.expense,
      );
      final ScheduledTransfer executed = await f.db.scheduledTransfersDao
          .create(
            accountId: from.id,
            targetAccountId: to.id,
            amountMinor: 30000,
            executeAt: DateTime.utc(2026, 1, 1),
            commissionMinor: 5000,
            commissionCategoryId: commissionCategory.id,
          );
      await f.db.scheduledTransfersDao.markExecuted(
        executed.id,
        transactionId: transfer.id,
        executedAt: DateTime.utc(2026, 1, 2),
      );
      await tester.pumpAndSettle();

      // Split по executedAt: обе подсекции, две строки счетов; комиссия —
      // только в исполненной.
      expect(find.text(l10n.planningTransfersPendingSection), findsOneWidget);
      expect(find.text(l10n.planningTransfersExecutedSection), findsOneWidget);
      expect(find.text(transferLine('Рубли', 'Копилка')), findsNWidgets(2));
      expect(
        find.text(l10n.transferCommissionLine(money(5000))),
        findsOneWidget,
      );

      // Действия только у ожидающих (спека D §4): в списке ранняя дата
      // сверху — исполненная (2026) выше ожидающей (2100), но в виджетах
      // подсекция «Ожидают» рисуется раньше «Исполнены». Тап по исполненной
      // не открывает форму, тап по ожидающей открывает правку.
      await tester.tap(find.text(transferLine('Рубли', 'Копилка')).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.transferEditTitle), findsNothing);

      await tester.tap(find.text(transferLine('Рубли', 'Копилка')).first);
      await tester.pumpAndSettle();
      expect(find.text(l10n.transferEditTitle), findsOneWidget);
    },
  );
}
