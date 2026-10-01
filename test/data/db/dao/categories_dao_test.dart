// Тесты категорий: вложенность, защита от циклов и запреты soft delete
// (системные, с живыми вложенными, с живыми операциями).
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;

  setUp(() {
    f = DataLayerFixture();
  });

  tearDown(() async {
    await f.dispose();
  });

  test(
    'create: корневая и вложенная категории, пустые иконка и цвет — NULL',
    () async {
      final Category root = await f.seedCategory(name: 'Продукты');
      final Category child = await f.categories.create(
        name: ' Молочное ',
        kind: CategoryKind.expense,
        parentId: root.id,
        icon: '  ',
        color: ' ',
      );

      expect(root.id, 'cat-1');
      expect(root.parentId, isNull);
      expect(root.isSystem, isFalse);
      expect(root.deletedAt, isNull);
      expect(root.createdAt.toUtc(), f.clock.read());
      expect(child.name, 'Молочное');
      expect(child.parentId, root.id);
      expect(child.icon, isNull);
      expect(child.color, isNull);
    },
  );

  test('create отклоняет пустое имя и некорректного родителя', () async {
    final Category expense = await f.seedCategory(name: 'Продукты');
    final Category income = await f.seedCategory(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );

    await expectLater(
      f.categories.create(name: '  ', kind: CategoryKind.expense),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.categories.create(
        name: 'Молочное',
        kind: CategoryKind.expense,
        parentId: 'нет-такого',
      ),
      throwsA(isA<DataValidationException>()),
    );
    // Доходы не вкладываются в расходы.
    await expectLater(
      f.categories.create(
        name: 'Аванс',
        kind: CategoryKind.income,
        parentId: expense.id,
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.categories.create(
        name: 'Аванс',
        kind: CategoryKind.income,
        parentId: income.id,
      ),
      completes,
    );

    await f.categories.softDelete(expense.id);
    // Удалённый родитель не годится.
    await expectLater(
      f.categories.create(
        name: 'Сладости',
        kind: CategoryKind.expense,
        parentId: expense.id,
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('getAlive фильтрует по виду и сортирует по виду и имени', () async {
    await f.seedCategory(name: 'Транспорт');
    await f.seedCategory(name: 'Аренда');
    await f.seedCategory(name: 'Зарплата', kind: CategoryKind.income);
    final Category deleted = await f.seedCategory(name: 'Старое');
    await f.categories.softDelete(deleted.id);

    final List<Category> expenses = await f.categories.getAlive(
      kind: CategoryKind.expense,
    );
    expect(expenses.map((Category c) => c.name), <String>[
      'Аренда',
      'Транспорт',
    ]);

    final List<Category> all = await f.categories.getAlive();
    expect(all, hasLength(3));
    expect(all.last.name, 'Зарплата');
  });

  test(
    'updateCategory: переименование, переоформление и очистка полей',
    () async {
      final Category created = await f.seedCategory();
      f.clock.advance(const Duration(hours: 2));

      final Category decorated = await f.categories.updateCategory(
        created.id,
        name: const Value<String>(' Еда '),
        icon: const Value<String?>(null),
        color: const Value<String?>(' #FF0000 '),
      );

      expect(decorated.name, 'Еда');
      expect(decorated.icon, isNull);
      expect(decorated.color, '#FF0000');
      expect(decorated.createdAt.toUtc(), created.createdAt.toUtc());
      expect(decorated.updatedAt.toUtc(), f.clock.read());
    },
  );

  test('updateCategory переносит по дереву и отклоняет циклы', () async {
    final Category root = await f.seedCategory(name: 'Еда');
    final Category child = await f.seedCategory(
      name: 'Сладости',
      parentId: root.id,
    );
    final Category grandChild = await f.seedCategory(
      name: 'Шоколад',
      parentId: child.id,
    );

    // Себя родителем сделать нельзя.
    await expectLater(
      f.categories.updateCategory(root.id, parentId: Value<String?>(root.id)),
      throwsA(isA<DataValidationException>()),
    );
    // Потомка родителем — цикл.
    await expectLater(
      f.categories.updateCategory(
        root.id,
        parentId: Value<String?>(grandChild.id),
      ),
      throwsA(isA<DataValidationException>()),
    );
    // Открепление от родителя — допустимо.
    final Category detached = await f.categories.updateCategory(
      child.id,
      parentId: const Value<String?>(null),
    );
    expect(detached.parentId, isNull);
    expect((await f.categories.findById(grandChild.id))?.parentId, child.id);
  });

  test(
    'updateCategory отклоняет пустое имя, чужой вид и неизвестный id',
    () async {
      final Category expense = await f.seedCategory(name: 'Продукты');
      final Category income = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );

      await expectLater(
        f.categories.updateCategory(
          expense.id,
          name: const Value<String>('   '),
        ),
        throwsA(isA<DataValidationException>()),
      );
      await expectLater(
        f.categories.updateCategory(
          expense.id,
          parentId: Value<String?>(income.id),
        ),
        throwsA(isA<DataValidationException>()),
      );
      await expectLater(
        f.categories.updateCategory(
          'нет-такого',
          name: const Value<String>('Еда'),
        ),
        throwsA(isA<DataValidationException>()),
      );
    },
  );

  test('системную категорию удалить нельзя', () async {
    final Category system = await f.seedCategory(
      name: 'Прочее',
      isSystem: true,
    );

    await expectLater(
      f.categories.softDelete(system.id),
      throwsA(isA<DataValidationException>()),
    );
    expect(system.isSystem, isTrue);
    expect(await f.categories.getAlive(), hasLength(1));
  });

  test('категорию с живыми вложенными удалить нельзя', () async {
    final Category root = await f.seedCategory(name: 'Еда');
    final Category child = await f.seedCategory(
      name: 'Сладости',
      parentId: root.id,
    );

    await expectLater(
      f.categories.softDelete(root.id),
      throwsA(isA<DataValidationException>()),
    );

    await f.categories.softDelete(child.id);
    await f.categories.softDelete(root.id);

    expect(await f.categories.getAlive(), isEmpty);
    expect(await rawRowCount(f.db, 'categories'), 2);
    expect((await f.categories.findById(root.id)), isNull);
  });

  test('категорию с живыми операциями удалить нельзя', () async {
    final Category category = await f.seedCategory();
    final Account account = await f.seedAccount();
    final Transaction expense = await f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
      amountMinor: 500,
    );

    await expectLater(
      f.categories.softDelete(category.id),
      throwsA(isA<DataValidationException>()),
    );

    await f.transactions.softDelete(expense.id);
    await f.categories.softDelete(category.id);

    expect(await f.categories.getAlive(), isEmpty);
  });

  test(
    'create/updateCategory: iconCode сохраняется, NULL валиден (v4)',
    () async {
      final Category created = await f.seedCategory();
      expect(created.iconCode, isNull, reason: 'иконка не выбрана — NULL');

      f.clock.advance(const Duration(hours: 1));
      final Category withIcon = await f.categories.create(
        name: 'Транспорт',
        kind: CategoryKind.expense,
        iconCode: 'transport',
      );
      expect(withIcon.iconCode, 'transport');

      f.clock.advance(const Duration(hours: 1));
      final Category renamed = await f.categories.updateCategory(
        created.id,
        iconCode: const Value<String?>('food'),
      );
      expect(renamed.iconCode, 'food');
      expect(renamed.updatedAt.toUtc(), f.clock.read());

      // Value(null) снимает иконку; Value.absent() не трогает её.
      f.clock.advance(const Duration(hours: 1));
      final Category cleared = await f.categories.updateCategory(
        created.id,
        iconCode: const Value<String?>(null),
      );
      expect(cleared.iconCode, isNull);

      final Category untouched = await f.categories.updateCategory(created.id);
      expect(untouched.iconCode, isNull);
    },
  );

  test(
    'create/updateCategory: неизвестный код иконки — отказ invalidInput',
    () async {
      final Category created = await f.seedCategory();

      await expectLater(
        f.categories.create(
          name: 'Еда',
          kind: CategoryKind.expense,
          iconCode: 'нет-такого',
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      await expectLater(
        f.categories.updateCategory(
          created.id,
          iconCode: const Value<String?>('нет-такого'),
        ),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.invalidInput,
          ),
        ),
      );
      // После отказов категория осталась без иконки (отказ до записи).
      expect((await f.categories.findById(created.id))?.iconCode, isNull);
    },
  );

  test('watchAlive отдаёт изменения дерева категорий', () async {
    final Stream<List<Category>> stream = f.categories.watchAlive();
    await f.seedCategory();

    await expectLater(stream, emitsThrough(hasLength(1)));
  });

  test(
    'hide: системная скрыта из живых списков, строка в БД осталась (M5-шаг 3)',
    () async {
      final Category system = await f.seedCategory(
        name: 'Прочее',
        isSystem: true,
      );
      f.clock.advance(const Duration(hours: 1));

      final Category hidden = await f.categories.hide(system.id);

      expect(hidden.deletedAt, isNotNull);
      expect(hidden.updatedAt.toUtc(), f.clock.read());
      // Исчезла из живых списков (getAlive/watchAlive, findById).
      expect(await f.categories.getAlive(), isEmpty);
      expect(await f.categories.getAlive(kind: CategoryKind.expense), isEmpty);
      expect(await f.categories.findById(system.id), isNull);
      // Но осталась в БД (soft delete, §3) и видна в списке скрытых.
      expect(await rawRowCount(f.db, 'categories'), 1);
      final List<Category> hiddenList = await f.categories
          .watchHiddenSystem()
          .first;
      expect(hiddenList.single.id, system.id);
    },
  );

  test('hide: не-системную скрыть нельзя — только softDelete', () async {
    final Category user = await f.seedCategory(name: 'Хобби');

    await expectLater(
      f.categories.hide(user.id),
      throwsA(
        isA<DataValidationException>().having(
          (DataValidationException e) => e.kind,
          'kind',
          DataFailure.categoryIsSystem,
        ),
      ),
    );
    expect(await f.categories.getAlive(), hasLength(1));
  });

  test('hide: неясный id и уже скрытая — отказ notFound', () async {
    final Category system = await f.seedCategory(
      name: 'Прочее',
      isSystem: true,
    );
    await expectLater(
      f.categories.hide('нет-такого'),
      throwsA(
        isA<DataValidationException>().having(
          (DataValidationException e) => e.kind,
          'kind',
          DataFailure.notFound,
        ),
      ),
    );
    await f.categories.hide(system.id);
    await expectLater(
      f.categories.hide(system.id),
      throwsA(isA<DataValidationException>()),
    );
  });

  test(
    'restore: скрытая системная возвращается во все живые списки (M5-шаг 3)',
    () async {
      final Category system = await f.seedCategory(
        name: 'Прочее',
        kind: CategoryKind.income,
        isSystem: true,
      );
      await f.categories.hide(system.id);
      f.clock.advance(const Duration(hours: 1));

      final Category restored = await f.categories.restore(system.id);

      expect(restored.deletedAt, isNull);
      expect(restored.updatedAt.toUtc(), f.clock.read());
      expect(await f.categories.getAlive(), hasLength(1));
      expect(
        await f.categories.getAlive(kind: CategoryKind.income),
        hasLength(1),
      );
      expect(await f.categories.findById(system.id), isNotNull);
      expect(await f.categories.watchHiddenSystem().first, isEmpty);
    },
  );

  test(
    'restore: не скрытые (живая, не-системная, удалённая) не возвращаются',
    () async {
      final Category system = await f.seedCategory(
        name: 'Прочее',
        isSystem: true,
      );
      final Category user = await f.seedCategory(name: 'Хобби');

      // Живая и не-системная: не в списке скрытых — отказ notFound.
      await expectLater(
        f.categories.restore(user.id),
        throwsA(
          isA<DataValidationException>().having(
            (DataValidationException e) => e.kind,
            'kind',
            DataFailure.notFound,
          ),
        ),
      );
      // Живая системная — тоже не «возврат».
      await expectLater(
        f.categories.restore(system.id),
        throwsA(isA<DataValidationException>()),
      );
      // Удалённая не-системная — не системная, возврату не подлежит.
      await f.categories.softDelete(user.id);
      await expectLater(
        f.categories.restore(user.id),
        throwsA(isA<DataValidationException>()),
      );
    },
  );

  test('watchHiddenSystem: скрытие добавляет, возврат убирает', () async {
    final Category system = await f.seedCategory(
      name: 'Прочее',
      isSystem: true,
    );
    final Stream<List<Category>> stream = f.categories.watchHiddenSystem();

    // До скрытия — пусто; после скрытия — одна; после возврата — пусто.
    await expectLater(stream, emitsThrough(isEmpty));
    final Category hidden = await f.categories.hide(system.id);
    await expectLater(stream, emitsThrough(hasLength(1)));
    await f.categories.restore(hidden.id);
    await expectLater(stream, emitsThrough(isEmpty));
    // Не-системные в потоке скрытых не появляются.
    final Category user = await f.seedCategory(name: 'Хобби');
    await f.categories.softDelete(user.id);
    await expectLater(stream, emitsThrough(isEmpty));
  });

  test('скрытие с операциями: операция живёт, имя резолвится в истории (LEFT JOIN), считается в отчётах-бюджетах', () async {
    final Category system = await f.seedCategory(
      name: 'Продукты',
      isSystem: true,
    );
    final Account account = await f.seedAccount();
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: system.id,
      amountMinor: 500,
    );
    await f.budgets.create(categoryId: system.id, limitMinor: 1000);

    await f.categories.hide(system.id);

    // Живые списки пусты, но операция и бюджет живы и считаются.
    expect(await f.categories.getAlive(), isEmpty);
    expect(await f.transactions.getFiltered(), hasLength(1));
    expect(await f.budgets.getAlive(), hasLength(1));
    // История (LEFT JOIN без фильтра deleted_at) — имя видно, как у удалённых.
    final List<TransactionView> views = await f.transactions
        .watchFilteredView()
        .first;
    expect(views.single.categoryName, 'Продукты');
    // Отчёты (JOIN c.deleted_at IS NULL, D-18) — категория не считается.
    expect(
      await f.transactions.expensesByCategoryForMonthInBase(
        moment: f.clock.read(),
      ),
      isEmpty,
    );
    // Бюджет жив, прогресс не теряет имя (категория в БД есть).
    final List<Budget> budgets = await f.budgets.getAlive();
    expect(budgets.single.categoryId, system.id);
  });

  test('hasAny: скрытые системные и удалённые пользовательские считаются (условие посева, D-62)', () async {
    // Пустой вид — посеву есть что создавать.
    expect(await f.categories.hasAny(kind: CategoryKind.expense), isFalse);

    final Category system = await f.seedCategory(
      name: 'Продукты',
      isSystem: true,
    );
    expect(await f.categories.hasAny(kind: CategoryKind.expense), isTrue);

    // Скрытие всех системных — вид НЕ пуст для посева (D-62).
    await f.categories.hide(system.id);
    expect(await f.categories.hasAny(kind: CategoryKind.expense), isTrue);
    expect(await f.categories.getAlive(kind: CategoryKind.expense), isEmpty);

    // restore возвращает вид в живые списки — hasAny по-прежнему true.
    await f.categories.restore(system.id);
    expect(await f.categories.hasAny(kind: CategoryKind.expense), isTrue);

    // Пользовательское удаление — тоже не делает вид пустым.
    final Category user = await f.seedCategory(name: 'Хобби');
    await f.categories.softDelete(user.id);
    expect(await f.categories.hasAny(kind: CategoryKind.expense), isTrue);
  });
}
