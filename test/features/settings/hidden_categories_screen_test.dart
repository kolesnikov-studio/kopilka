// Виджет-тесты экрана «Скрытые категории» (M5-шаг 3, D-54 идея 3):
// пункт в настройках появляется только при наличии скрытых, список по видам
// с действием «вернуть», возврат реально возвращает категорию в живые
// списки (проверяем БД), пустое состояние.
//
// Запуск через pumpDialogApp (S2): in-memory БД, RU-локаль, весь KopilkaApp —
// переход из настроек, как делает пользователь.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/router.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

import '../../helpers/app_harness.dart';

/// Открывает настройки (вкладка снизу).
Future<void> _openSettings(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(find.text(l10n.navSettings));
  await tester.pumpAndSettle();
}

/// Открывает экран «Скрытые категории» переходом по маршруту (без пункта в
/// настройках — для пустого состояния).
Future<void> _openHiddenScreenDirect(WidgetTester tester, AppHarness app) async {
  app.container.read(routerProvider).push('/settings/hidden-categories');
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'пункт настроек скрыт, пока скрывать нечего; после скрытия виден и ведёт на экран',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_hidden_categories_test',
      );
      await _openSettings(tester, app.l10n);

      // Ничего не скрыто — пункта нет.
      expect(find.text(app.l10n.hiddenCategoriesTitle), findsNothing);

      // Скрываем системную категорию через DAO (как делает экран категорий).
      final List<Category> seeded = await app.db.categoriesDao
          .getAlive(kind: CategoryKind.expense);
      await app.db.categoriesDao.hide(
        seeded.firstWhere((Category c) => c.name == 'Транспорт').id,
      );
      await tester.pumpAndSettle();

      // Пункт появился со счётчиком скрытых.
      expect(find.text(app.l10n.hiddenCategoriesTitle), findsOneWidget);
      expect(
        find.text(app.l10n.hiddenCategoriesTileSubtitle(1)),
        findsOneWidget,
      );

      // Переход на экран по пункту.
      await tester.tap(find.text(app.l10n.hiddenCategoriesTitle));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.hiddenCategoriesTitle), findsWidgets);
      expect(find.text('Транспорт'), findsOneWidget);
    },
  );

  testWidgets(
    'экран возврата: только скрытые по видам, возврат возвращает в живые списки',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_hidden_categories_test',
      );
      final List<Category> expense =
          await app.db.categoriesDao.getAlive(kind: CategoryKind.expense);
      final List<Category> income =
          await app.db.categoriesDao.getAlive(kind: CategoryKind.income);
      await app.db.categoriesDao.hide(
        expense.firstWhere((Category c) => c.name == 'Транспорт').id,
      );
      await app.db.categoriesDao.hide(
        income.firstWhere((Category c) => c.name == 'Зарплата').id,
      );
      await tester.pumpAndSettle();

      await _openSettings(tester, app.l10n);
      await tester.tap(find.text(app.l10n.hiddenCategoriesTitle));
      await tester.pumpAndSettle();

      // Скрытые видны (обе секции), не скрытая «Продукты» — нет.
      expect(find.text('Транспорт'), findsOneWidget);
      expect(find.text('Зарплата'), findsOneWidget);
      expect(find.text('Продукты'), findsNothing);

      // Возврат «Транспорт»: тап по строке.
      await tester.tap(find.text('Транспорт'));
      await tester.pumpAndSettle();

      // Снек и строка ушла с экрана.
      expect(find.text(app.l10n.categoryRestoredSnack('Транспорт')),
          findsOneWidget);
      expect(find.text('Транспорт'), findsNothing);

      // В БД категория снова живая, скрытых расходов с ней нет.
      final List<Category> alive =
          await app.db.categoriesDao.getAlive(kind: CategoryKind.expense);
      expect(alive.any((Category c) => c.name == 'Транспорт'), isTrue);
      final List<Category> hidden = (await tester.runAsync(
        () => app.db.categoriesDao.watchHiddenSystem().first,
      ))!;
      expect(hidden.map((Category c) => c.name), <String>['Зарплата']);
    },
  );

  testWidgets(
    'пустое состояние: заголовок и текст «Скрытых категорий нет»',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_hidden_categories_test',
      );
      await _openSettings(tester, app.l10n);
      // Пункта нет — переход по маршруту напрямую.
      await _openHiddenScreenDirect(tester, app);

      expect(find.text(app.l10n.hiddenCategoriesTitle), findsOneWidget);
      expect(find.text(app.l10n.hiddenCategoriesEmpty), findsOneWidget);
    },
  );
}
