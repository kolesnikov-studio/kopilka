// Замки превентивной проверки пересечения hasOverlap (спека C §6.3,
// planning_controller.dart:104–124, D-115.в): с загруженным живым
// потоком — пересечение true (снек errorPlanOverlap ещё до DAO), касание
// границами полуинтервалов и правка своего плана — false; поток не
// загружен — false, страховку берёт DAO (отказ DAO покрыт
// plans_dao_test.dart). UI-исход замкнут в planning_screen_test.dart.
//
// Потоки drift читаются real async (конвенция D-136 — вне fake_async).
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/planning/planning_controller.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seedDefaultsIfEmpty(db);
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
  });

  test('поток живых планов не загружен → false (страховку берёт DAO)', () {
    final PlanningController controller = container.read(
      planningControllerProvider.notifier,
    );

    final bool overlap = controller.hasOverlap(
      categoryId: 'нет-в-потоке',
      periodStartUtc: DateTime.utc(2026, 10, 1),
      periodEndUtc: DateTime.utc(2026, 11, 1),
    );

    expect(overlap, isFalse);
  });

  test(
    'загруженный поток: пересечение true; касание и свой план — false',
    () async {
      final Category food = await db.categoriesDao.create(
        name: 'Продукты',
        kind: CategoryKind.expense,
      );
      final Plan plan = await db.plansDao.create(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 10, 1),
        periodEnd: DateTime.utc(2026, 11, 1),
        amountMinor: 100000,
      );

      // Держим поток живым и дожидаемся значения — иначе autoDispose-поток
      // не инициализирован и проверка честно уходит в ветку «не загружен».
      final ProviderSubscription<AsyncValue<List<Plan>>> live = container
          .listen(alivePlansProvider, (_, _) {});
      addTearDown(live.close);
      await container.read(alivePlansProvider.future);
      expect(container.read(alivePlansProvider).value, hasLength(1));

      final PlanningController controller = container.read(
        planningControllerProvider.notifier,
      );

      // Пересекающийся период той же категории → true (диалог покажет
      // errorPlanOverlap ещё до обращения к DAO).
      expect(
        controller.hasOverlap(
          categoryId: food.id,
          periodStartUtc: DateTime.utc(2026, 10, 15),
          periodEndUtc: DateTime.utc(2026, 11, 15),
        ),
        isTrue,
      );
      // Полуинтервалы: касание концом одного и началом другого — не
      // пересечение (спека C §6.3).
      expect(
        controller.hasOverlap(
          categoryId: food.id,
          periodStartUtc: DateTime.utc(2026, 11, 1),
          periodEndUtc: DateTime.utc(2026, 12, 1),
        ),
        isFalse,
      );
      // Правка самого плана: excludePlanId исключает его из проверки.
      expect(
        controller.hasOverlap(
          categoryId: food.id,
          periodStartUtc: DateTime.utc(2026, 10, 15),
          periodEndUtc: DateTime.utc(2026, 11, 15),
          excludePlanId: plan.id,
        ),
        isFalse,
      );
      // Чужая категория не пересекается с планом «Продуктов».
      expect(
        controller.hasOverlap(
          categoryId: 'другая-категория',
          periodStartUtc: DateTime.utc(2026, 10, 15),
          periodEndUtc: DateTime.utc(2026, 11, 15),
        ),
        isFalse,
      );
    },
  );
}
