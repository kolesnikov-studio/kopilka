// Тесты категорий: вложенность, защита от циклов и запреты soft delete
// (системные, с живыми вложенными, с живыми операциями).
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
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

  test('create: корневая и вложенная категории, пустые иконка и цвет — NULL', () async {
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
  });

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
    expect(
      expenses.map((Category c) => c.name),
      <String>['Аренда', 'Транспорт'],
    );

    final List<Category> all = await f.categories.getAlive();
    expect(all, hasLength(3));
    expect(all.last.name, 'Зарплата');
  });

  test('updateCategory: переименование, переоформление и очистка полей', () async {
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
  });

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
      f.categories.updateCategory(
        root.id,
        parentId: Value<String?>(root.id),
      ),
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

  test('updateCategory отклоняет пустое имя, чужой вид и неизвестный id', () async {
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
  });

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

  test('watchAlive отдаёт изменения дерева категорий', () async {
    final Stream<List<Category>> stream = f.categories.watchAlive();
    await f.seedCategory();

    await expectLater(stream, emitsThrough(hasLength(1)));
  });
}
