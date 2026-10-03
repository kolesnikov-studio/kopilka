// UI-замок превентивной проверки пересечения (спека C §6.3, D-115.в,
// D-138 §6 п.2): пересекающийся период → снек `errorPlanOverlap`, форма
// плана открыта, новый план не создан. Логика hasOverlap (обе ветки:
// загруженный/не загруженный поток) замкнута в
// planning_controller_test.dart, отказ DAO — в plans_dao_test.dart.
//
// Данные — живые потоки DAO; in-memory drift, RU-локаль (app_harness).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

import '../../helpers/app_harness.dart';

/// Пункт нижней навигации по подписи (образец planning_screen_test).
Finder navItem(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

/// Открывает вкладку «Планирование» в живом приложении (app_harness).
Future<void> openPlanning(WidgetTester tester, AppLocalizations l10n) async {
  await tester.tap(navItem(l10n.navPlanning));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('замок пересечения: снек errorPlanOverlap, диалог открыт', (
    WidgetTester tester,
  ) async {
    // Окно 600×1000 — прецедент U9 (dropdown категории в 400px).
    final AppHarness f = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
    );
    final AppLocalizations l10n = f.l10n;
    final DateTime now = DateTime.now();
    final Category category = await f.db.categoriesDao.create(
      name: 'Продукты',
      kind: CategoryKind.expense,
    );
    // Живой план на текущий месяц — период формы по умолчанию совпадает
    // с ним (§3), пересечение неизбежно без правки дат.
    await f.db.plansDao.create(
      categoryId: category.id,
      periodStart: DateTime.utc(now.year, now.month),
      periodEnd: DateTime.utc(now.year, now.month + 1),
      amountMinor: 100000,
    );
    await openPlanning(tester, l10n);

    await tester.tap(find.byTooltip(l10n.planningAddTooltip));
    await tester.pumpAndSettle();
    // Меню материала — фиксированные pump (D-136), без settle.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Продукты').last);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.enterText(find.byType(TextFormField).first, '500');
    await tester.tap(find.text(l10n.saveAction));
    await tester.pumpAndSettle();

    // Пересечение → снек errorPlanOverlap, форма открыта, новый план не
    // создан (превентивная проверка либо страховка DAO — исход для UI
    // одинаков).
    expect(find.text(l10n.errorPlanOverlap), findsOneWidget);
    expect(find.text(l10n.planningAddTitle), findsOneWidget);
    final List<Plan> rows = await f.db.select(f.db.plans).get();
    expect(rows, hasLength(1));
  });
}
