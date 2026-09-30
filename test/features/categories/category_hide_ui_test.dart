// Виджет-тесты скрытия категорий (M5-шаг 3, D-54 идея 3): у системной —
// долгий тап открывает подтверждение «скрыть» (не «удалить»), категория
// уходит с экрана и из живого списка БД; пользовательская пустая — удаляется,
// пользовательская с операциями — отказ DAO объясняется снеком.
//
// Запуск через pumpDialogApp (S2): in-memory БД с посевом, RU-локаль,
// весь KopilkaApp — переход на вкладку категорий, как делает пользователь.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/widgets/error_localization.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/features/categories/categories_controller.dart';

import '../../helpers/app_harness.dart';

/// Открывает вкладку категорий.
Future<void> _openCategories(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navCategories).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'системная: подтверждение «Скрыть» (кнопка не «Удалить»), скрытие через контроллер',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_hide_categories_test',
      );
      await _openCategories(tester, app);

      // Долгий тап по системной «Продукты» → подтверждение скрытия.
      await tester.longPress(find.text('Продукты'));
      await tester.pumpAndSettle();

      expect(find.text(app.l10n.categoryHideTitle), findsOneWidget);
      expect(find.text(app.l10n.categoryHideBody('Продукты')), findsOneWidget);
      // Подтверждающая кнопка — «Скрыть», текста «Удалить» в диалоге нет.
      expect(find.text(app.l10n.categoryHideAction), findsOneWidget);
      expect(find.text(app.l10n.deleteAction), findsNothing);

      await tester.tap(find.text(app.l10n.categoryHideAction));
      await tester.pumpAndSettle();

      // Снек об успехе; категория ушла с экрана.
      expect(find.text(app.l10n.categoryHiddenSnack('Продукты')),
          findsOneWidget);
      expect(find.text('Продукты'), findsNothing);

      // Скрытие прошло через контроллер и DAO: в БД строка скрыта,
      // из живого списка исчезла.
      final List<Category> alive =
          await app.db.categoriesDao.getAlive(kind: CategoryKind.expense);
      expect(alive.any((Category c) => c.name == 'Продукты'), isFalse);
      final List<Category> hidden = (await tester.runAsync(
        () => app.db.categoriesDao.watchHiddenSystem().first,
      ))!;
      expect(hidden.map((Category c) => c.name), <String>['Продукты']);
    },
  );

  testWidgets(
    'пользовательская пустая: подтверждение удаления с кнопкой «Удалить», удаляется',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_hide_categories_test',
      );
      await app.container
          .read(categoriesControllerProvider.notifier)
          .createCategory(name: 'Хобби', kind: CategoryKind.expense, iconCode: 'hobby');
      await tester.pumpAndSettle();
      await _openCategories(tester, app);

      await tester.longPress(find.text('Хобби'));
      await tester.pumpAndSettle();

      // Обычный диалог удаления: заголовок и кнопка «Удалить».
      expect(find.text(app.l10n.categoryDeleteTitle), findsOneWidget);
      expect(find.text(app.l10n.deleteAction), findsOneWidget);
      await tester.tap(find.text(app.l10n.deleteAction));
      await tester.pumpAndSettle();

      expect(find.text('Хобби'), findsNothing);
      final List<Category> alive =
          await app.db.categoriesDao.getAlive(kind: CategoryKind.expense);
      expect(alive.any((Category c) => c.name == 'Хобби'), isFalse);
    },
  );

  testWidgets(
    'пользовательская с операциями: отказ categoryHasTransactions объясняется снеком',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_hide_categories_test',
      );
      final Result<Category> created = await app.container
          .read(categoriesControllerProvider.notifier)
          .createCategory(name: 'Мойки', kind: CategoryKind.expense, iconCode: 'cleaning');
      final String categoryId = created.value.id;
      await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );
      await app.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: (await app.db.accountsDao.getAlive()).first.id,
        categoryId: categoryId,
        amountMinor: 300,
      );
      await tester.pumpAndSettle();
      await _openCategories(tester, app);

      await tester.longPress(find.text('Мойки'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.deleteAction));
      await tester.pumpAndSettle();

      // Отказ DAO объясняется локализованным текстом вида отказа.
      expect(
        find.text(
          localizedError(app.l10n, DataFailure.categoryHasTransactions),
        ),
        findsOneWidget,
      );
      // Категория осталась.
      expect(find.text('Мойки'), findsOneWidget);
    },
  );
}
