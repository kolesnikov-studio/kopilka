// Виджет-тест экрана «Отчёты» (M2): карточка баланса, переключение месяцев,
// разбивка по категориям и динамика по месяцам поверх живых потоков DAO.
//
// Грабли fake_async: БД — in-memory drift (нативная SQLite даёт живой цикл
// событий и бесконечный pumpAndSettle). Ожидаемые суммы считаются тем же
// formatMoneyMinor: форматтер вставляет неразрывные пробелы, литеральные
// строки ненадёжны.
import 'package:drift/native.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/reports/reports_screen.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Фикстура: in-memory БД + контейнер, экран поверх живых потоков DAO.
class Fixture {
  Fixture() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
  }

  late final AppDatabase db;
  late final ProviderContainer container;

  /// Порядок важен: сперва контейнер (останавливает потоки drift), потом БД.
  void dispose() {
    container.dispose();
    db.close();
  }

  /// Запускает экран с этой базой и возвращает русские строки.
  Future<AppLocalizations> pump(WidgetTester tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    await seedDefaultsIfEmpty(db);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ReportsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ru'));
  }
}

/// Карточка общего баланса: её значение теперь дублируется подписью
/// точки «сейчас» карточки прогноза (спека D §1) — суммы баланса
/// ищем внутри карточки с заголовком reportsTotalBalance.
Finder _balanceCard(AppLocalizations l10n) => find
    .ancestor(
      of: find.text(l10n.reportsTotalBalance),
      matching: find.byType(Card),
    )
    .first;

void main() {
  testWidgets('пустая база: баланс 0, заглушка пустой разбивки', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    expect(find.text(l10n.reportsTotalBalance), findsOneWidget);
    expect(
      find.descendant(
        of: _balanceCard(l10n),
        matching: find.text(formatMoneyMinor(0, symbol: '₽', locale: 'ru')),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.reportsCategoryBreakdownEmpty), findsOneWidget);
  });

  testWidgets('операции месяца: баланс, донат и легенда категорий', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    // Прямой доступ к DAO: тест проверяет UI, а не контроллеры ввода.
    final Account account = await f.db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
      initialBalanceMinor: 100000,
    );
    final Category products = await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    final Category transport = await f.db.categoriesDao.create(
      name: 'Транспорт',
      kind: CategoryKind.expense,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: products.id,
      amountMinor: 30000,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: transport.id,
      amountMinor: 20000,
    );

    await tester.pumpAndSettle();

    // Баланс: 1000 − 300 − 200 = 5,00 ₽ в мажорных единицах (в карточке
    // баланса — та же сумма подписью точки «сейчас» прогноза, D-117).
    String money(int minor) =>
        formatMoneyMinor(minor, symbol: '₽', locale: 'ru');
    expect(
      find.descendant(
        of: _balanceCard(l10n),
        matching: find.text(money(50000)),
      ),
      findsOneWidget,
    );
    // Легенда: имя категории в донате и в списке, суммы — в списке.
    expect(find.text('Молочка'), findsNWidgets(2));
    expect(find.text(money(30000)), findsOneWidget);
    expect(find.text(money(20000)), findsOneWidget);
    expect(find.text(l10n.reportsCategoryBreakdownEmpty), findsNothing);
    expect(find.byType(PieChart), findsOneWidget);
  });

  testWidgets('переключение месяца: прошлый месяц открывается стрелкой', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    final Account account = await f.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: baseCurrencyCode,
    );
    final Category products = await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    // Операция в прошлом месяце относительно текущего (UTC, §3).
    final DateTime prevMonth = monthStart(DateTime.now().toUtc())
        .subtract(const Duration(days: 1));
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: products.id,
      amountMinor: 4500,
      date: prevMonth,
    );

    await tester.pumpAndSettle();

    // Текущий месяц: расходов нет.
    expect(find.text(l10n.reportsCategoryBreakdownEmpty), findsOneWidget);

    // Стрелка назад: месяц с расходом.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text(l10n.reportsCategoryBreakdownEmpty), findsNothing);
    expect(
      find.text(formatMoneyMinor(4500, symbol: '₽', locale: 'ru')),
      findsOneWidget,
    );
  });

  testWidgets('P4: месяц операции определяется датой, а не днём запуска', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    await f.pump(tester);

    final Account account = await f.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: baseCurrencyCode,
    );
    final Category currentCat = await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    final Category prevCat = await f.db.categoriesDao.create(
      name: 'Транспорт',
      kind: CategoryKind.expense,
    );
    // Обе даты привязаны к границе текущего месяца, а не к «сегодня»:
    // первая секунда текущего месяца (всегда внутри месяца, даже при
    // запуске 1-го числа) и последняя секунда предыдущего — тест
    // детерминирован относительно дня запуска (P4), полночь UTC внутри.
    final DateTime currentStart = monthStart(DateTime.now().toUtc());
    final DateTime prevEnd = currentStart.subtract(const Duration(seconds: 1));
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: currentCat.id,
      amountMinor: 30000,
      date: currentStart,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: prevCat.id,
      amountMinor: 20000,
      date: prevEnd,
    );

    await tester.pumpAndSettle();

    // Текущий месяц: расход виден независимо от числа.
    String money(int minor) =>
        formatMoneyMinor(minor, symbol: '₽', locale: 'ru');
    expect(find.text(money(30000)), findsOneWidget);
    expect(find.text('Молочка'), findsNWidgets(2));

    // Стрелка назад: предыдущий месяц со своей категорией, без смешивания.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text(money(20000)), findsOneWidget);
    expect(find.text('Транспорт'), findsNWidgets(2));
    expect(find.text(money(30000)), findsNothing);
    expect(find.text('Молочка'), findsNothing);
  });

  testWidgets('динамика по месяцам: столбцы и легенда при данных', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    final Account account = await f.db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );
    final Category expenseCat = await f.db.categoriesDao.create(
      name: 'Прочие расходы',
      kind: CategoryKind.expense,
    );
    final Category incomeCat = await f.db.categoriesDao.create(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: account.id,
      categoryId: incomeCat.id,
      amountMinor: 80000,
    );
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: expenseCat.id,
      amountMinor: 30000,
    );

    await tester.pumpAndSettle();

    expect(find.text(l10n.reportsMonthDynamicsTitle), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    // Легенда переиспользует подписи фильтров операций.
    expect(find.text(l10n.filterIncomes), findsOneWidget);
    expect(find.text(l10n.filterExpenses), findsOneWidget);
  });

  group('пометки «по текущему курсу» (B5, M3-шаг 5)', () {
    Future<Currency> seedUsd(Fixture f) async {
      await f.db.currenciesDao.create(code: 'USD', symbol: r'$', rateToBase: 2);
      return f.db.currenciesDao.findAlive('USD').then((Currency? c) => c!);
    }

    testWidgets('моновалютный пользователь: пометки нет (не шумим)', (
      WidgetTester tester,
    ) async {
      final Fixture f = Fixture();
      addTearDown(f.dispose);
      final AppLocalizations l10n = await f.pump(tester);

      await f.db.accountsDao.create(
        name: 'Рублёвый',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
        initialBalanceMinor: 100000,
      );
      await tester.pumpAndSettle();

      expect(find.text(l10n.reportsAtCurrentRate), findsNothing);
    });

    testWidgets('мультивалютность: три пометки — баланс, «Всего», футер', (
      WidgetTester tester,
    ) async {
      final Fixture f = Fixture();
      addTearDown(f.dispose);
      final AppLocalizations l10n = await f.pump(tester);

      await seedUsd(f);
      await f.db.accountsDao.create(
        name: 'Рублёвый',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
        initialBalanceMinor: 100000,
      );
      await f.db.accountsDao.create(
        name: 'Долларовый',
        kind: AccountKind.card,
        currencyCode: 'USD',
        initialBalanceMinor: 2000,
      );
      // Расход нужен, чтобы карточка разбивки показывала строку «Всего».
      final List<Account> alive = await f.db.accountsDao.getAlive();
      final Category food = await f.db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await f.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: alive
            .firstWhere((Account x) => x.currencyCode == baseCurrencyCode)
            .id,
        categoryId: food.id,
        amountMinor: 30000,
      );
      await tester.pumpAndSettle();

      // (а) карточка общего баланса; (б) рядом с «Всего» (donut-строка);
      // (в) футер динамики: итого 3.
      expect(find.text(l10n.reportsAtCurrentRate), findsNWidgets(3));
      // Общий баланс конвертирован: (1000,00 − 300,00) + 20,00 × 2 = 740,00 ₽.
      // Внутри карточки баланса — сумма там же подписью прогноза.
      expect(
        find.descendant(
          of: _balanceCard(l10n),
          matching: find.text(
            formatMoneyMinor(74000, symbol: '₽', locale: 'ru'),
          ),
        ),
        findsOneWidget,
      );
      // «Всего» доната: расход 300,00 ₽ в базовой — без изменений.
      expect(
        find.text(
          '${l10n.reportsTotalLabel}: ${formatMoneyMinor(30000, symbol: '₽', locale: 'ru')}',
        ),
        findsOneWidget,
      );
    });

    testWidgets('появление второй валюты добавляет пометку живым потоком', (
      WidgetTester tester,
    ) async {
      final Fixture f = Fixture();
      addTearDown(f.dispose);
      final AppLocalizations l10n = await f.pump(tester);

      final Account rub = await f.db.accountsDao.create(
        name: 'Рублёвый',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Category food = await f.db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await f.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: rub.id,
        categoryId: food.id,
        amountMinor: 30000,
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.reportsAtCurrentRate), findsNothing);

      await seedUsd(f);
      await f.db.accountsDao.create(
        name: 'Долларовый',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.reportsAtCurrentRate), findsNWidgets(3));
    });
  });
}
