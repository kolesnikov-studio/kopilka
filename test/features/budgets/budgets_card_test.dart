// Виджет-тесты бюджетов на дашборде «Отчёты» (M2, шаг 4): создание через
// диалог, прогресс-бар с превышением, правка лимита, удаление. Данные —
// живые потоки DAO; in-memory drift (грабли fake_async).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  testWidgets('пустая база: пустое состояние и кнопка добавления', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    expect(find.text(l10n.budgetsTitle), findsOneWidget);
    expect(find.text(l10n.budgetsEmpty), findsOneWidget);
    expect(find.byTooltip(l10n.budgetAdd), findsOneWidget);
  });

  testWidgets('создание бюджета: диалог, лимит, строка с прогрессом', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    await tester.pumpAndSettle();

    // Диалог создания: категории без бюджета доступны для выбора.
    // Карточка ниже видимой области — прокручиваем к кнопке.
    await tester.ensureVisible(find.byTooltip(l10n.budgetAdd));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.budgetAdd));
    await tester.pumpAndSettle();
    expect(find.text(l10n.budgetAdd), findsOneWidget);

    // Выбираем «Молочка» в списке категорий: по умолчанию выбрана первая
    // свободная из посева («Продукты»), а тест создаёт бюджет на свою.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    // Первый матч — выбранное значение в поле, второй — пункт меню.
    await tester.ensureVisible(find.text('Молочка').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Молочка').last);
    await tester.pumpAndSettle();

    // В поле вводится мажорная сумма: parseAmountToMinor умножает на 100.
    await tester.enterText(find.byType(TextFormField).first, '500');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    // Диалог закрылся, строка бюджета появилась с суммами «0 / 500».
    expect(find.text(l10n.budgetAdd), findsNothing);
    expect(find.text('Молочка'), findsOneWidget);
    expect(
      find.text(
        '${formatMoneyMinor(0, symbol: '₽', locale: 'ru')} / '
        '${formatMoneyMinor(50000, symbol: '₽', locale: 'ru')}',
      ),
      findsOneWidget,
    );
    // Прогресс-бар категории отрисован.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('превышение лимита: сумма расхода видна в строке', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    await f.pump(tester);

    final Account account = await f.db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );
    final Category groceries = await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    await f.db.budgetsDao.create(
      categoryId: groceries.id,
      limitMinor: 1000,
    );
    // Расход больше лимита: превышение (isOver, красный цвет — логика DAO).
    await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: groceries.id,
      amountMinor: 1500,
    );

    await tester.pumpAndSettle();

    // Строка показывает «потрачено / лимит»: 15,00 / 10,00.
    expect(
      find.text(
        '${formatMoneyMinor(1500, symbol: '₽', locale: 'ru')} / '
        '${formatMoneyMinor(1000, symbol: '₽', locale: 'ru')}',
      ),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('правка лимита: тап по строке, новая сумма сохраняется', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    final Category groceries = await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    await f.db.budgetsDao.create(
      categoryId: groceries.id,
      limitMinor: 1000,
    );
    await tester.pumpAndSettle();

    // Тап по строке открывает диалог правки с заголовком «Изменить бюджет».
    await tester.ensureVisible(find.text('Молочка'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Молочка'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.budgetEdit), findsOneWidget);

    // Поле предзаполнено текущим лимитом (10,00); меняем на 20,00.
    final TextFormField field = tester.widget<TextFormField>(
      find.byType(TextFormField).first,
    );
    expect(field.controller!.text, '10.00');
    await tester.enterText(find.byType(TextFormField).first, '20');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    expect(
      find.text(
        '${formatMoneyMinor(0, symbol: '₽', locale: 'ru')} / '
        '${formatMoneyMinor(2000, symbol: '₽', locale: 'ru')}',
      ),
      findsOneWidget,
    );
  });

  testWidgets('удаление: долгий тап, подтверждение, строка исчезает', (
    WidgetTester tester,
  ) async {
    final Fixture f = Fixture();
    addTearDown(f.dispose);
    final AppLocalizations l10n = await f.pump(tester);

    final Category groceries = await f.db.categoriesDao.create(
      name: 'Молочка',
      kind: CategoryKind.expense,
    );
    await f.db.budgetsDao.create(
      categoryId: groceries.id,
      limitMinor: 1000,
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Молочка'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Молочка'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.budgetDeleteTitle), findsOneWidget);

    await tester.tap(find.text(l10n.deleteAction));
    await tester.pumpAndSettle();

    // Поток DAO обновился: строка исчезла, пустое состояние вернулось.
    expect(find.text('Молочка'), findsNothing);
    expect(find.text(l10n.budgetsEmpty), findsOneWidget);
  });

  group('бюджеты в базовой валюте (M3-шаг 6, B6)', () {
    testWidgets('диалог: суффикс символа базы и подсказка с кодом', (
      WidgetTester tester,
    ) async {
      final Fixture f = Fixture();
      addTearDown(f.dispose);
      final AppLocalizations l10n = await f.pump(tester);

      await tester.ensureVisible(find.byTooltip(l10n.budgetAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.budgetAdd));
      await tester.pumpAndSettle();

      // Суффикс поля лимита — символ базовой (₽ из посева), подсказка —
      // с её кодом (B6). InputDecoration живёт на внутреннем TextField.
      final TextField field = tester.widget<TextField>(
        find.descendant(
          of: find.byType(TextFormField),
          matching: find.byType(TextField),
        ),
      );
      expect(field.decoration?.suffixText, '₽');
      expect(find.text(l10n.budgetBaseCurrencyHint('RUB')), findsOneWidget);
    });

    testWidgets('строка прогресса: формат по экспоненту базы, пометки нет', (
      WidgetTester tester,
    ) async {
      final Fixture f = Fixture();
      addTearDown(f.dispose);
      final AppLocalizations l10n = await f.pump(tester);

      // Мультивалютные счета: пометка «по текущему курсу» у отчётов
      // появляется, но у карточки бюджетов её быть не должно (B6):
      // лимит и есть базовая (D-19).
      await f.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 2,
      );
      await f.db.accountsDao.create(
        name: 'Долларовый',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      final Account rub = await f.db.accountsDao.create(
        name: 'Наличные',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Account usd = await f.db.accountsDao.create(
        name: 'Долларовый2',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      final Category groceries = await f.db.categoriesDao.create(
        name: 'Молочка',
        kind: CategoryKind.expense,
      );
      await f.db.budgetsDao.create(
        categoryId: groceries.id,
        limitMinor: 200000,
      );
      // Смешанные расходы: RUB 1000,00 + USD 25,00 × курс 2 = 1000 + 50
      // → 1050,00 ₽ (построчная конвертация — DAO, шаг 6).
      await f.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: rub.id,
        categoryId: groceries.id,
        amountMinor: 100000,
      );
      await f.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: usd.id,
        categoryId: groceries.id,
        amountMinor: 2500,
      );

      await tester.pumpAndSettle();

      String money(int minor) => formatMoneyMinor(minor, symbol: '₽', locale: 'ru');
      expect(
        find.text('${money(105000)} / ${money(200000)}'),
        findsOneWidget,
      );
      // Пометка «по текущему курсу» (B5) на карточках отчётов есть —
      // мультивалютность счетов её включает, — но на карточке бюджетов её
      // быть не должно (B6): лимит и есть базовая (D-19).
      expect(find.text(l10n.reportsAtCurrentRate), findsAtLeastNWidgets(1));
      final Finder budgetsCard = find.ancestor(
        of: find.text(l10n.budgetsTitle),
        matching: find.byType(Card),
      ).first;
      expect(
        find.descendant(
          of: budgetsCard,
          matching: find.text(l10n.reportsAtCurrentRate),
        ),
        findsNothing,
      );
    });

    testWidgets('диалог: категории с бюджетом по-прежнему отключены', (
      WidgetTester tester,
    ) async {
      final Fixture f = Fixture();
      addTearDown(f.dispose);
      final AppLocalizations l10n = await f.pump(tester);      final Category groceries = await f.db.categoriesDao.create(
        name: 'Молочка',
        kind: CategoryKind.expense,
      );
      await f.db.budgetsDao.create(
        categoryId: groceries.id,
        limitMinor: 100000,
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byTooltip(l10n.budgetAdd));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(l10n.budgetAdd));
      await tester.pumpAndSettle();

      // Занятая категория видна в списке, но её пункт недоступен (D-14):
      // регресс-проверка после правок B6.
      final DropdownButton<String> dropdown =
          tester.widget<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      final DropdownMenuItem<String> busyItem = dropdown.items!
          .singleWhere(
            (DropdownMenuItem<String> item) => item.value == groceries.id,
          );
      expect(busyItem.enabled, isFalse);
    });
  });
}
