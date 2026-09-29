// Замки посева первого запуска: идемпотентность и главный инвариант
// M5 (D-57/D-62) — посев не воскрешает скрытое и не возвращает
// пользовательски удалённые категории.
//
// Условие посева — «в БД ни одной категории вида, включая скрытые»
// (`hasAny`, D-62), а не «живые пусты»: иначе скрытие всех предустановок
// откатывалось бы рестартом.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import 'dao/dao_test_utils.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('посев: пустая база получает предустановки обоих видов и валюту', () async {
    await seedDefaultsIfEmpty(db);

    expect(
      await db.categoriesDao.getAlive(kind: CategoryKind.expense),
      hasLength(presetExpenseCategories.length),
    );
    expect(
      await db.categoriesDao.getAlive(kind: CategoryKind.income),
      hasLength(presetIncomeCategories.length),
    );
    expect(await db.currenciesDao.getAlive(), hasLength(1));
  });

  test('посев идемпотентен: на занятом виде повторный вызов ничего не добавляет', () async {
    await seedDefaultsIfEmpty(db);
    final int before = await rawRowCount(db, 'categories');

    await seedDefaultsIfEmpty(db);

    expect(await rawRowCount(db, 'categories'), before);
  });

  test('скрытие всех предустановок переживает рестарт: посев не воскрешает (D-62)', () async {
    await seedDefaultsIfEmpty(db);

    // Пользователь скрыл ВСЕ системные категории обоих видов.
    for (final Category c in await db.categoriesDao.getAlive()) {
      await db.categoriesDao.hide(c.id);
    }
    expect(await db.categoriesDao.getAlive(), isEmpty);
    final int hiddenRows = (await db.categoriesDao.getHiddenSystem()).length;
    expect(hiddenRows, presetExpenseCategories.length + presetIncomeCategories.length);

    // «Рестарт»: повторный посев на той же базе.
    await seedDefaultsIfEmpty(db);

    // Набор НЕ вернулся, скрытые остались скрытыми, новых строк нет.
    expect(await db.categoriesDao.getAlive(kind: CategoryKind.expense), isEmpty);
    expect(await db.categoriesDao.getAlive(kind: CategoryKind.income), isEmpty);
    expect(await db.categoriesDao.getHiddenSystem(), hasLength(hiddenRows));
  });

  test('посев не восстанавливает пользовательски удалённые категории', () async {
    await seedDefaultsIfEmpty(db);
    final Category user = await db.categoriesDao.create(
      name: 'Хобби',
      kind: CategoryKind.expense,
    );
    await db.categoriesDao.softDelete(user.id);
    final int before = await rawRowCount(db, 'categories');

    await seedDefaultsIfEmpty(db);

    expect(await rawRowCount(db, 'categories'), before);
    expect(
      await db.categoriesDao.getAlive(kind: CategoryKind.expense),
      isNot(contains(user)),
    );
  });

  test('частично скрытый вид не добирается предустановками', () async {
    await seedDefaultsIfEmpty(db);

    // Скрыта только часть расходов: живые расходы есть — посев молчит,
    // состав живых не меняется.
    final List<Category> alive =
        await db.categoriesDao.getAlive(kind: CategoryKind.expense);
    await db.categoriesDao.hide(alive.first.id);
    final int before = await rawRowCount(db, 'categories');

    await seedDefaultsIfEmpty(db);

    expect(
      await db.categoriesDao.getAlive(kind: CategoryKind.expense),
      hasLength(alive.length - 1),
    );
    expect(await rawRowCount(db, 'categories'), before);
  });
}
