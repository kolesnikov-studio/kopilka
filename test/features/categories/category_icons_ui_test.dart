// Виджет-тесты иконок категорий (M5-шаг 2, D-54/D-55).
//
// Диалог формы: сетка выбора иконки, обязательный выбор при создании
// (предвыбран «other» — форма сохраняется сразу), смена при редактировании;
// сохранение идёт через контроллер и DAO — проверяем именно запись в БД.
// Отображение: глиф рядом с названием на экране категорий и в выборе
// категории формы операции; NULL живой базы — нейтральная заглушка «other».
//
// Харнесс общий с формами счетов/операций (S2, test/helpers/app_harness.dart):
// БД подменяется на in-memory, каталоги настроек — во временном каталоге.
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/category_icons.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import '../../helpers/app_harness.dart';

/// Открывает вкладку категорий и форму создания.
Future<void> _openCreateDialog(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navCategories).last);
  await tester.pumpAndSettle();
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'создание: иконка предвыбрана («other»), форма сохраняется сразу через DAO',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_category_icons_test',
      );

      await _openCreateDialog(tester, app);
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.nameLabel),
        'Хобби',
      );
      // Иконку не трогаем: предвыбор «other» делает форму валидной сразу.
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      final List<Category> categories = await app.db.categoriesDao.getAlive(
        kind: CategoryKind.expense,
      );
      final Category created = categories.singleWhere(
        (Category c) => c.name == 'Хобби',
      );
      expect(created.iconCode, 'other');
    },
  );

  testWidgets('создание: выбор иконки в сетке сохраняется через DAO', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_category_icons_test',
    );

    await _openCreateDialog(tester, app);
    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.nameLabel),
      'Бензин',
    );
    // Сетка: тап по глифу «fuel» (tooltip — код справочника).
    await tester.tap(find.byTooltip('fuel'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final List<Category> categories = await app.db.categoriesDao.getAlive(
      kind: CategoryKind.expense,
    );
    final Category created = categories.singleWhere(
      (Category c) => c.name == 'Бензин',
    );
    expect(created.iconCode, 'fuel');
  });

  testWidgets('редактирование: смена иконки записывается в DAO', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_category_icons_test',
    );

    await tester.tap(find.text(app.l10n.navCategories).last);
    await tester.pumpAndSettle();
    // Системная «Продукты» сеется с groceries — открываем правку тапом.
    await tester.tap(find.text('Продукты'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('food'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final List<Category> categories = await app.db.categoriesDao.getAlive(
      kind: CategoryKind.expense,
    );
    final Category renamed = categories.singleWhere(
      (Category c) => c.name == 'Продукты',
    );
    expect(renamed.iconCode, 'food');
  });

  testWidgets(
    'экран категорий: глиф рядом с названием, NULL живой базы — заглушка «other»',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_category_icons_test',
      );

      // Живая база v0.4: категория без иконки (NULL) — заглушка.
      final Category seeded = (await app.db.categoriesDao.getAlive(
        kind: CategoryKind.expense,
      )).firstWhere((Category c) => c.name == 'Продукты');
      await app.db.categoriesDao.updateCategory(
        seeded.id,
        iconCode: const Value<String?>(null),
      );
      // Пользовательская — с иконкой из справочника.
      await app.db.categoriesDao.create(
        name: 'Авто',
        kind: CategoryKind.expense,
        iconCode: 'car',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(app.l10n.navCategories).last);
      await tester.pumpAndSettle();

      // Глиф «car» у категории с иконкой.
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Авто'),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(categoryIconByCode('car')!.icon),
        ),
        findsOneWidget,
      );
      // NULL — заглушка «other» (нейтральная иконка Icons.category).
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Продукты'),
            matching: find.byType(ListTile),
          ),
          matching: find.byIcon(categoryIconByCode('other')!.icon),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'форма операции: глиф в пунктах выбора категории (вписывается без ломки вёрстки)',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_category_icons_test',
      );

      await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );

      await tester.tap(find.text(app.l10n.navTransactions).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.expenseAction));
      await tester.pumpAndSettle();

      // Раскрываем dropdown категории: пункты содержат глифы предустановок.
      await tester.tap(find.byType(DropdownButtonFormField<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Продукты').last);
      await tester.pumpAndSettle();

      final CategoryIcon groceries = categoryIconByCode('groceries')!;
      expect(
        find.byIcon(groceries.icon),
        findsWidgets,
        reason: 'глиф предустановленной категории виден в пунктах dropdown',
      );
    },
  );
}
