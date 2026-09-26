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

void main() {
  testWidgets('пустая база: баланс 0, заглушка пустой разбивки', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    expect(find.text(l10n.reportsTotalBalance), findsOneWidget);
    expect(
      find.text(formatMoneyMinor(0, symbol: '₽', locale: 'ru')),
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

    // Баланс: 1000 − 300 − 200 = 5,00 ₽ в мажорных единицах.
    String money(int minor) => formatMoneyMinor(minor, symbol: '₽', locale: 'ru');
    expect(find.text(money(50000)), findsOneWidget);
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
    final DateTime prevMonth =
        monthStart(DateTime.now().toUtc()).subtract(const Duration(days: 1));
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
}
