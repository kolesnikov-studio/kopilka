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
}
