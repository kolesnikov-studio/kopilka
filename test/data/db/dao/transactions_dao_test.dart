// Тесты операций: правила видов (доход/расход/перевод), фильтры и поиск,
// обновление и soft delete.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

import 'dao_test_utils.dart';

void main() {
  late DataLayerFixture f;
  late Account cash;
  late Account card;
  late Category products;

  setUp(() async {
    f = DataLayerFixture();
    cash = await f.seedAccount(name: 'Наличные', initialBalanceMinor: 100000);
    card = await f.seedAccount(
      name: 'Карта',
      kind: AccountKind.card,
      initialBalanceMinor: 50000,
    );
    products = await f.seedCategory(name: 'Продукты');
  });

  tearDown(() async {
    await f.dispose();
  });

  test('create: валюта наследуется от счёта, заметка обрезается', () async {
    final Transaction transaction = await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 12345,
      note: '  Хлеб  ',
    );

    expect(transaction.id, 'tx-1');
    expect(TransactionType.fromDb(transaction.type), TransactionType.expense);
    expect(transaction.accountId, cash.id);
    expect(transaction.targetAccountId, isNull);
    expect(transaction.categoryId, products.id);
    expect(transaction.amountMinor, 12345);
    expect(transaction.currencyCode, cash.currencyCode);
    expect(transaction.note, 'Хлеб');
    expect(transaction.date.toUtc(), f.clock.read());
    expect(transaction.createdAt.toUtc(), f.clock.read());
    expect(transaction.deletedAt, isNull);

    final Transaction withoutNote = await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 100,
      note: '   ',
    );
    expect(withoutNote.note, isNull);
  });

  test('create: дата задаётся явно', () async {
    final DateTime date = DateTime.utc(2026, 8, 1, 9, 30);
    final Transaction transaction = await f.transactions.create(
      type: TransactionType.income,
      accountId: cash.id,
      amountMinor: 5000,
      date: date,
    );

    expect(transaction.date.toUtc(), date);
    expect(transaction.date.toUtc(), isNot(f.clock.read()));
  });

  test('create отклоняет неположительную сумму', () async {
    await expectLater(
      f.transactions.create(
        type: TransactionType.expense,
        accountId: cash.id,
        amountMinor: 0,
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.create(
        type: TransactionType.expense,
        accountId: cash.id,
        amountMinor: -100,
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('create отклоняет чужой счёт: неизвестный и удалённый', () async {
    await expectLater(
      f.transactions.create(
        type: TransactionType.expense,
        accountId: 'нет-такого',
        amountMinor: 100,
      ),
      throwsA(isA<DataValidationException>()),
    );

    await f.transactions.create(
      type: TransactionType.expense,
      accountId: card.id,
      amountMinor: 100,
    );
    await f.transactions.softDelete('tx-1');
    await f.accounts.softDelete(card.id);

    await expectLater(
      f.transactions.create(
        type: TransactionType.expense,
        accountId: card.id,
        amountMinor: 100,
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('перевод: обязателен другой живой счёт и запрещена категория', () async {
    await expectLater(
      f.transactions.create(
        type: TransactionType.transfer,
        accountId: cash.id,
        amountMinor: 1000,
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.create(
        type: TransactionType.transfer,
        accountId: cash.id,
        targetAccountId: cash.id,
        amountMinor: 1000,
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.create(
        type: TransactionType.transfer,
        accountId: cash.id,
        targetAccountId: card.id,
        categoryId: products.id,
        amountMinor: 1000,
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.create(
        type: TransactionType.transfer,
        accountId: cash.id,
        targetAccountId: 'нет-такого',
        amountMinor: 1000,
      ),
      throwsA(isA<DataValidationException>()),
    );

    final Transaction transfer = await f.transactions.create(
      type: TransactionType.transfer,
      accountId: cash.id,
      targetAccountId: card.id,
      amountMinor: 1000,
    );
    expect(transfer.targetAccountId, card.id);
    expect(transfer.categoryId, isNull);
    expect(transfer.currencyCode, 'RUB');
  });

  test('доход и расход не принимают счёт зачисления', () async {
    await expectLater(
      f.transactions.create(
        type: TransactionType.expense,
        accountId: cash.id,
        targetAccountId: card.id,
        amountMinor: 100,
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('категория обязана совпадать по виду и быть живой', () async {
    final Category salary = await f.categories.create(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );

    await expectLater(
      f.transactions.create(
        type: TransactionType.income,
        accountId: cash.id,
        categoryId: products.id,
        amountMinor: 100,
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.create(
        type: TransactionType.expense,
        accountId: cash.id,
        categoryId: 'нет-такого',
        amountMinor: 100,
      ),
      throwsA(isA<DataValidationException>()),
    );

    final Transaction income = await f.transactions.create(
      type: TransactionType.income,
      accountId: cash.id,
      categoryId: salary.id,
      amountMinor: 100,
    );
    expect(income.categoryId, salary.id);

    // Категорию с живой операцией удалить нельзя — удаляем операцию.
    await f.transactions.softDelete(income.id);
    await f.categories.softDelete(salary.id);
    await expectLater(
      f.transactions.create(
        type: TransactionType.income,
        accountId: cash.id,
        categoryId: salary.id,
        amountMinor: 100,
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('фильтры: счёт, категория, вид, период и поиск', () async {
    final Category salary = await f.categories.create(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );
    final DateTime day1 = DateTime.utc(2026, 9, 10, 12);
    final DateTime day2 = DateTime.utc(2026, 9, 20, 12);

    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 1000,
      date: day1,
      note: 'Coffee with friends',
    );
    await f.transactions.create(
      type: TransactionType.income,
      accountId: cash.id,
      categoryId: salary.id,
      amountMinor: 2000,
      date: day2,
      note: 'Кофе на работе',
    );
    await f.transactions.create(
      type: TransactionType.transfer,
      accountId: cash.id,
      targetAccountId: card.id,
      amountMinor: 3000,
      date: day2,
    );

    Future<int> count(TransactionFilter filter) async =>
        (await f.transactions.getFiltered(filter)).length;

    expect(await count(const TransactionFilter()), 3);
    expect(await count(TransactionFilter(accountId: card.id)), 1);
    expect(await count(TransactionFilter(accountId: cash.id)), 3);
    expect(await count(TransactionFilter(categoryId: products.id)), 1);
    expect(
      await count(const TransactionFilter(type: TransactionType.income)),
      1,
    );
    expect(await count(TransactionFilter(from: day2)), 2);
    expect(await count(TransactionFilter(to: day2)), 1);
    expect(
      await count(TransactionFilter(from: day1, to: day2)),
      1,
    );
    expect(await count(const TransactionFilter(search: 'coffee')), 1);
    expect(await count(const TransactionFilter(search: 'Кофе')), 1);
    expect(
      await count(TransactionFilter(search: 'офе')),
      1,
    );
    expect(
      await count(
        TransactionFilter(accountId: card.id, type: TransactionType.transfer),
      ),
      1,
    );

    // A12: %, _ и \ в поиске — литеральные символы, а не маски LIKE.
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 400,
      date: day1,
      note: 'Скидка 100%',
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 500,
      date: day1,
      note: '100x объём',
    );

    // Без экранирования «100%» нашло бы и «100x объём» (2 вместо 1).
    expect(await count(const TransactionFilter(search: '100%')), 1);
    // «_» — любой символ в маске LIKE: без экранирования «100_» нашло бы
    // «100x» и «100%»; литеральный поиск — только заметку с настоящим «_».
    expect(await count(const TransactionFilter(search: '100_')), 0);
  });

  test('watchFilteredView отдаёт имена счёта, целевого счёта и категории (R7)',
      () async {
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 100,
    );
    await f.transactions.create(
      type: TransactionType.transfer,
      accountId: cash.id,
      targetAccountId: card.id,
      amountMinor: 250,
    );
    // Расход без категории: имя категории null (U4 — UI покажет текст).
    await f.transactions.create(
      type: TransactionType.income,
      accountId: card.id,
      amountMinor: 500,
    );

    final List<TransactionView> rows =
        await f.transactions.watchFilteredView().first;
    expect(rows, hasLength(3));

    final TransactionView transfer = rows.firstWhere(
      (TransactionView r) =>
          TransactionType.fromDb(r.transaction.type) ==
          TransactionType.transfer,
    );
    expect(transfer.accountName, 'Наличные');
    expect(transfer.targetAccountName, 'Карта');
    expect(transfer.categoryName, isNull);

    final TransactionView expense = rows.firstWhere(
      (TransactionView r) =>
          TransactionType.fromDb(r.transaction.type) ==
          TransactionType.expense,
    );
    expect(expense.accountName, 'Наличные');
    expect(expense.categoryName, 'Продукты');
    expect(expense.targetAccountName, isNull);

    final TransactionView income = rows.firstWhere(
      (TransactionView r) =>
          TransactionType.fromDb(r.transaction.type) ==
          TransactionType.income,
    );
    expect(income.accountName, 'Карта');
    expect(income.categoryName, isNull);
  });

  test('watchFilteredView: view-фильтр совпадает с getFiltered', () async {
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 100,
    );
    await f.transactions.create(
      type: TransactionType.income,
      accountId: card.id,
      amountMinor: 500,
    );

    final List<TransactionView> view = await f.transactions
        .watchFilteredView(
          const TransactionFilter(type: TransactionType.expense),
        )
        .first;
    expect(view, hasLength(1));
    expect(view.single.accountName, 'Наличные');
    expect(view.single.categoryName, 'Продукты');
  });

  test('watchFilteredView реагирует на создание операции', () async {
    expect(await f.transactions.watchFilteredView().first, isEmpty);
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 100,
    );
    final List<TransactionView> rows =
        await f.transactions.watchFilteredView().first;
    expect(rows, hasLength(1));
    expect(rows.single.accountName, 'Наличные');
  });

  test('список отсортирован от новых к старым', () async {
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 100,
      date: DateTime.utc(2026, 9, 1),
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 200,
      date: DateTime.utc(2026, 9, 3),
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 300,
      date: DateTime.utc(2026, 9, 2),
    );

    final List<Transaction> list = await f.transactions.getFiltered();
    expect(
      list.map((Transaction t) => t.amountMinor),
      <int>[200, 300, 100],
    );
  });

  test('updateTransaction меняет сумму, дату, заметку и категорию', () async {
    final Transaction created = await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      categoryId: products.id,
      amountMinor: 1000,
      note: 'Старое',
    );
    final Category fun = await f.categories.create(
      name: 'Развлечения',
      kind: CategoryKind.expense,
    );
    f.clock.advance(const Duration(minutes: 5));

    final Transaction updated = await f.transactions.updateTransaction(
      created.id,
      amountMinor: const Value<int>(2500),
      date: Value<DateTime>(DateTime.utc(2026, 9, 5)),
      note: const Value<String?>(null),
      categoryId: Value<String?>(fun.id),
    );

    expect(updated.amountMinor, 2500);
    expect(updated.date.toUtc(), DateTime.utc(2026, 9, 5));
    expect(updated.note, isNull);
    expect(updated.categoryId, fun.id);
    expect(updated.type, created.type);
    expect(updated.accountId, created.accountId);
    expect(updated.createdAt.toUtc(), created.createdAt.toUtc());
    expect(updated.updatedAt.toUtc(), f.clock.read());
  });

  test('updateTransaction переносит перевод на другой счёт', () async {
    final Account savings = await f.seedAccount(
      name: 'Копилка',
      kind: AccountKind.other,
    );
    final Transaction transfer = await f.transactions.create(
      type: TransactionType.transfer,
      accountId: cash.id,
      targetAccountId: card.id,
      amountMinor: 1000,
    );

    final Transaction moved = await f.transactions.updateTransaction(
      transfer.id,
      targetAccountId: Value<String?>(savings.id),
    );
    expect(moved.targetAccountId, savings.id);

    // У перевода счёт зачисления обязателен, а категории не бывает (§3).
    await expectLater(
      f.transactions.updateTransaction(
        transfer.id,
        targetAccountId: const Value<String?>(null),
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.updateTransaction(
        transfer.id,
        categoryId: Value<String?>(products.id),
      ),
      throwsA(isA<DataValidationException>()),
    );
    // Отклонённые изменения не записались.
    final Transaction? raw = await f.transactions.findById(transfer.id);
    expect(raw?.targetAccountId, savings.id);
    expect(raw?.categoryId, isNull);
  });

  test('updateTransaction проверяет правила вида и сумму', () async {
    final Transaction expense = await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 1000,
    );

    await expectLater(
      f.transactions.updateTransaction(
        expense.id,
        amountMinor: const Value<int>(0),
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.updateTransaction(
        expense.id,
        targetAccountId: Value<String?>(card.id),
      ),
      throwsA(isA<DataValidationException>()),
    );
    final Category salary = await f.categories.create(
      name: 'Зарплата',
      kind: CategoryKind.income,
    );
    await expectLater(
      f.transactions.updateTransaction(
        expense.id,
        categoryId: Value<String?>(salary.id),
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.transactions.updateTransaction(
        'нет-такого',
        amountMinor: const Value<int>(10),
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('мягкое удаление скрывает операцию, строка остаётся', () async {
    final Transaction transaction = await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 1000,
    );

    await f.transactions.softDelete(transaction.id);

    expect(await f.transactions.getFiltered(), isEmpty);
    expect(await f.transactions.findById(transaction.id), isNull);
    expect(await rawRowCount(f.db, 'transactions'), 1);
    final Transaction raw = await (f.db.select(
      f.db.transactions,
    )).getSingle();
    expect(raw.deletedAt?.toUtc(), f.clock.read());
    await expectLater(
      f.transactions.softDelete(transaction.id),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('watchFiltered отдаёт изменения списка операций', () async {
    final Stream<List<Transaction>> stream = f.transactions.watchFiltered(
      const TransactionFilter(type: TransactionType.expense),
    );

    await f.transactions.create(
      type: TransactionType.income,
      accountId: cash.id,
      amountMinor: 1000,
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: cash.id,
      amountMinor: 2000,
    );

    await expectLater(
      stream,
      emitsThrough(
        predicate<List<Transaction>>(
          (List<Transaction> list) =>
              list.length == 1 && list.single.amountMinor == 2000,
          'одна живая операция расхода',
        ),
      ),
    );
  });

  group('агрегаты дашборда (M2)', () {
    test('границы месяца: первая секунда попадает в свой месяц (P3)', () async {
      final Account account = await f.seedAccount();
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: products.id,
        amountMinor: 111,
        // Ровно 00:00:00 первого дня месяца (UTC, §3).
        date: DateTime.utc(2026, 9, 1),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: products.id,
        amountMinor: 222,
        date: DateTime.utc(2026, 8, 31, 23, 59, 59),
      );

      final List<CategoryExpense> september =
          await f.db.transactionsDao.expensesByCategoryForMonth(
        moment: DateTime.utc(2026, 9, 15),
      );
      expect(september.single.amountMinor, 111);
      expect(september.single.categoryName, 'Продукты');

      final List<MonthTotals> totals = await f.db.transactionsDao.totalsByMonth(
        from: DateTime.utc(2026, 8, 1),
        to: DateTime.utc(2026, 10, 1),
      );
      expect(totals.map((MonthTotals m) => m.monthKey), <String>['2026-08', '2026-09']);
      expect(totals[0].expenseMinor, 222);
      expect(totals[1].expenseMinor, 111);
    });

    test('границы месяца: последняя секунда (23:59:59) остаётся в своём месяце (P3)', () async {
      final Account account = await f.seedAccount();
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: products.id,
        amountMinor: 333,
        date: DateTime.utc(2026, 9, 30, 23, 59, 59),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: products.id,
        amountMinor: 444,
        date: DateTime.utc(2026, 10, 1),
      );

      final List<CategoryExpense> september =
          await f.db.transactionsDao.expensesByCategoryForMonth(
        moment: DateTime.utc(2026, 9, 15),
      );
      expect(september.single.amountMinor, 333);

      final List<CategoryExpense> october =
          await f.db.transactionsDao.expensesByCategoryForMonth(
        moment: DateTime.utc(2026, 10, 15),
      );
      expect(october.single.amountMinor, 444);

      final List<MonthTotals> totals = await f.db.transactionsDao.totalsByMonth(
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 11, 1),
      );
      expect(totals.map((MonthTotals m) => m.monthKey), <String>['2026-09', '2026-10']);
      expect(totals[0].expenseMinor, 333);
      expect(totals[1].expenseMinor, 444);
    });

    test('расходы по категориям за месяц: только живые расходы, без переводов',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Account account = await f.seedAccount();
      final Category groceries = await f.seedCategory(name: 'Продукты');
      final Category transport = await f.seedCategory(name: 'Транспорт');
      final Category incomeCat = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );

      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: groceries.id,
        amountMinor: 30000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: groceries.id,
        amountMinor: 25000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: transport.id,
        amountMinor: 50000,
      );
      // Доход, перевод и мягко удалённый расход — не в агрегате.
      await f.transactions.create(
        type: TransactionType.income,
        accountId: account.id,
        categoryId: incomeCat.id,
        amountMinor: 700000,
      );
      final Account target = await f.accounts.create(
        name: 'B',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      await f.transactions.create(
        type: TransactionType.transfer,
        accountId: account.id,
        targetAccountId: target.id,
        amountMinor: 1000,
      );
      final Transaction deleted = await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: groceries.id,
        amountMinor: 999,
      );
      await f.transactions.softDelete(deleted.id);

      final List<CategoryExpense> expenses =
          await f.db.transactionsDao.expensesByCategoryForMonth(
        moment: f.clock.read(),
      );
      // Сортировка по сумме убыванию: Продукты 550, Транспорт 500.
      expect(expenses, hasLength(2));
      expect(expenses.first.categoryName, 'Продукты');
      expect(expenses.first.amountMinor, 55000);
      expect(expenses.last.categoryName, 'Транспорт');
      expect(expenses.last.amountMinor, 50000);
    });

    test('расходы по категориям: операции соседних месяцев не смешиваются',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Account account = await f.seedAccount();
      final Category category = await f.seedCategory();
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 100,
        date: DateTime.utc(2026, 8, 20),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 400,
        date: DateTime.utc(2026, 10, 3),
      );

      final List<CategoryExpense> september =
          await f.db.transactionsDao.expensesByCategoryForMonth(
        moment: DateTime.utc(2026, 9, 15),
      );
      expect(september, isEmpty);
      final List<CategoryExpense> october =
          await f.db.transactionsDao.expensesByCategoryForMonth(
        moment: DateTime.utc(2026, 10, 5),
      );
      expect(october.single.amountMinor, 400);
    });

    test('итоги по месяцам: доходы и расходы раздельно, месяцы по UTC',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Account account = await f.seedAccount();
      final Category expenseCat = await f.seedCategory();
      final Category incomeCat = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );
      // Сентябрь: доход 1000, расход 300 + 70.
      final DateTime sep = DateTime.utc(2026, 9, 15);
      await f.transactions.create(
        type: TransactionType.income,
        accountId: account.id,
        categoryId: incomeCat.id,
        amountMinor: 100000,
        date: sep,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: expenseCat.id,
        amountMinor: 30000,
        date: sep,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: expenseCat.id,
        amountMinor: 7000,
        date: DateTime.utc(2026, 9, 28, 23),
      );
      // Октябрь: расход 500; август: доход 100. Перевод — мимо.
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: expenseCat.id,
        amountMinor: 50000,
        date: DateTime.utc(2026, 10, 2),
      );
      await f.transactions.create(
        type: TransactionType.income,
        accountId: account.id,
        categoryId: incomeCat.id,
        amountMinor: 10000,
        date: DateTime.utc(2026, 8, 9),
      );
      final Account target = await f.accounts.create(
        name: 'B',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      await f.transactions.create(
        type: TransactionType.transfer,
        accountId: account.id,
        targetAccountId: target.id,
        amountMinor: 4242,
        date: sep,
      );

      final List<MonthTotals> totals =
          await f.db.transactionsDao.totalsByMonth(
        from: DateTime.utc(2026, 8, 1),
        to: DateTime.utc(2026, 11, 1),
      );
      expect(
        totals.map((MonthTotals m) => m.monthKey).toList(),
        <String>['2026-08', '2026-09', '2026-10'],
      );
      expect(totals[0].incomeMinor, 10000);
      expect(totals[0].expenseMinor, 0);
      expect(totals[1].incomeMinor, 100000);
      expect(totals[1].expenseMinor, 37000);
      expect(totals[2].incomeMinor, 0);
      expect(totals[2].expenseMinor, 50000);
    });

    test('итоги по месяцам: мягко удалённые не считаются', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Account account = await f.seedAccount();
      final Category category = await f.seedCategory();
      final Transaction deleted = await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: category.id,
        amountMinor: 12345,
      );
      await f.transactions.softDelete(deleted.id);

      final List<MonthTotals> totals = await f.db.transactionsDao.totalsByMonth(
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 10, 1),
      );
      expect(totals, isEmpty);
    });

    test('watchExpensesByCategoryForMonth реагирует на новые операции',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Account account = await f.seedAccount();
      final Category groceries = await f.seedCategory(name: 'Продукты');

      final Stream<List<CategoryExpense>> stream =
          f.db.transactionsDao.watchExpensesByCategoryForMonth(
        moment: f.clock.read(),
      );

      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: groceries.id,
        amountMinor: 1500,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: groceries.id,
        amountMinor: 500,
      );

      await expectLater(
        stream,
        emitsThrough(
          predicate<List<CategoryExpense>>(
            (List<CategoryExpense> list) =>
                list.length == 1 &&
                list.single.categoryName == 'Продукты' &&
                list.single.amountMinor == 2000,
            'сумма категории дожила до 2000',
          ),
        ),
      );
    });

    test('watchTotalsByMonth отдаёт итоги и не смешивает месяцы', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      final Account account = await f.seedAccount();
      final Category expenseCat = await f.seedCategory();
      final Category incomeCat = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );

      final Stream<List<MonthTotals>> stream =
          f.db.transactionsDao.watchTotalsByMonth(
        from: DateTime.utc(2026, 8, 1),
        to: DateTime.utc(2026, 10, 1),
      );

      await f.transactions.create(
        type: TransactionType.income,
        accountId: account.id,
        categoryId: incomeCat.id,
        amountMinor: 70000,
        date: DateTime.utc(2026, 8, 11),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: account.id,
        categoryId: expenseCat.id,
        amountMinor: 12000,
        date: DateTime.utc(2026, 9, 3),
      );

      await expectLater(
        stream,
        emitsThrough(
          predicate<List<MonthTotals>>(
            (List<MonthTotals> list) =>
                list.length == 2 &&
                list[0].monthKey == '2026-08' &&
                list[0].incomeMinor == 70000 &&
                list[1].monthKey == '2026-09' &&
                list[1].expenseMinor == 12000,
            'август доход, сентябрь расход',
          ),
        ),
      );
    });
  });

  group('агрегаты в базовой валюте (M3-шаг 5, D-18)', () {
    test('донат: построчная конвертация RUB, USD и JPY в базовую', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 2);
      // Курс — степень двойки: произведение точно в double, проверяется
      // именно правило построчного half-up, а не хвосты float.
      await f.seedCurrency('JPY', symbol: '¥', rateToBase: 0.0625);
      final Account rub = await f.seedAccount(name: 'Рублёвый');
      final Account usd = await f.accounts.create(
        name: 'Долларовый',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      final Account jpy = await f.accounts.create(
        name: 'Йенный',
        kind: AccountKind.card,
        currencyCode: 'JPY',
      );
      final Category food = await f.seedCategory(name: 'Еда');
      final Category fun = await f.seedCategory(name: 'Развлечения');

      // РУБ 100,00 → 10000; USD 20,00 × курс 2 → 4000; JPY 320
      // (экспонент 0) → 320 × 0,0625 = 20,00 → 2000. Еда = 12000.
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: rub.id,
        categoryId: food.id,
        amountMinor: 10000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: usd.id,
        categoryId: fun.id,
        amountMinor: 2000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: jpy.id,
        categoryId: food.id,
        amountMinor: 320,
      );

      final List<CategoryExpenseBase> expenses =
          await f.db.transactionsDao.expensesByCategoryForMonthInBase(
        moment: f.clock.read(),
      );
      expect(expenses, hasLength(2));
      expect(expenses[0].categoryName, 'Еда');
      expect(expenses[0].amountMinor, 12000);
      expect(expenses[1].categoryName, 'Развлечения');
      expect(expenses[1].amountMinor, 4000);
    });

    test('смена курса пересчитывает донат без перезапуска (watch, D-16)', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 2);
      final Account usd = await f.accounts.create(
        name: 'Долларовый',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      final Category food = await f.seedCategory(name: 'Еда');

      final Stream<List<CategoryExpenseBase>> stream = f.db.transactionsDao
          .watchExpensesByCategoryForMonthInBase(moment: f.clock.read());

      await f.transactions.create(
        type: TransactionType.expense,
        accountId: usd.id,
        categoryId: food.id,
        amountMinor: 2000,
      );
      await expectLater(
        stream,
        emitsThrough(
          predicate<List<CategoryExpenseBase>>(
            (List<CategoryExpenseBase> list) =>
                list.single.amountMinor == 4000,
            '40,00 ₽ по курсу 2',
          ),
        ),
      );

      await f.currencies.updateCurrency(
        'USD',
        rateToBase: const Value<double>(4),
      );
      await expectLater(
        stream,
        emitsThrough(
          predicate<List<CategoryExpenseBase>>(
            (List<CategoryExpenseBase> list) =>
                list.single.amountMinor == 8000,
            '80,00 ₽ по курсу 4 без перезапуска',
          ),
        ),
      );
    });

    test('динамика: месяцы в базовой, экспоненты JPY и KWD (D-27)', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();
      await f.seedCurrency('JPY', symbol: '¥', rateToBase: 0.0625);
      // 1 динар = 200 ₽: минорный KWD крупнее минорного рубля в 10 раз.
      await f.seedCurrency('KWD', symbol: 'K', rateToBase: 200);
      final Account rub = await f.seedAccount(name: 'Рублёвый');
      final Account jpy = await f.accounts.create(
        name: 'Йенный',
        kind: AccountKind.card,
        currencyCode: 'JPY',
      );
      final Account kwd = await f.accounts.create(
        name: 'Динаровый',
        kind: AccountKind.card,
        currencyCode: 'KWD',
      );
      final Category incomeCat = await f.seedCategory(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );
      final Category food = await f.seedCategory(name: 'Еда');

      await f.transactions.create(
        type: TransactionType.income,
        accountId: rub.id,
        categoryId: incomeCat.id,
        amountMinor: 70000,
        date: DateTime.utc(2026, 8, 11),
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: rub.id,
        categoryId: food.id,
        amountMinor: 12000,
        date: DateTime.utc(2026, 9, 3),
      );
      // JPY 320 (экспонент 0) → 2000.
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: jpy.id,
        categoryId: food.id,
        amountMinor: 320,
        date: DateTime.utc(2026, 9, 4),
      );
      // KWD 12345 (экспонент 3) → 123,45 динара × 200 = 246900.
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: kwd.id,
        categoryId: food.id,
        amountMinor: 12345,
        date: DateTime.utc(2026, 10, 5),
      );

      final List<MonthTotalsBase> totals =
          await f.db.transactionsDao.totalsByMonthInBase(
        from: DateTime.utc(2026, 8, 1),
        to: DateTime.utc(2026, 11, 1),
      );
      expect(totals.map((MonthTotalsBase m) => m.monthKey),
          <String>['2026-08', '2026-09', '2026-10']);
      expect(totals[0].incomeMinor, 70000);
      expect(totals[0].expenseMinor, 0);
      expect(totals[1].expenseMinor, 14000);
      expect(totals[1].incomeMinor, 0);
      expect(totals[2].expenseMinor, 246900);
    });

    test('ожидания конвертации — через formatMoneyMinor по экспоненту базы',
        () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();
      await f.seedCurrency('JPY', symbol: '¥', rateToBase: 0.0625);
      // 1 динар = 200 ₽: минорный KWD крупнее минорного рубля в 10 раз.
      await f.seedCurrency('KWD', symbol: 'K', rateToBase: 200);
      final Account jpy = await f.accounts.create(
        name: 'Йенный',
        kind: AccountKind.card,
        currencyCode: 'JPY',
      );
      final Account kwd = await f.accounts.create(
        name: 'Динаровый',
        kind: AccountKind.card,
        currencyCode: 'KWD',
      );
      final Category food = await f.seedCategory(name: 'Еда');
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: jpy.id,
        categoryId: food.id,
        amountMinor: 320,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: kwd.id,
        categoryId: food.id,
        amountMinor: 12345,
      );

      final List<CategoryExpenseBase> expenses =
          await f.db.transactionsDao.expensesByCategoryForMonthInBase(
        moment: f.clock.read(),
      );
      expect(expenses.single.amountMinor, 248900);
      // База — экспонент 2 (D-27): суммы показываются как рублёвые с копейками,
      // независимо от экспонентов валют-источников.
      String money(int minor) => formatMoneyMinor(minor, symbol: '₽', locale: 'ru');
      expect(money(expenses.single.amountMinor), money(248900));
    });

    test('одно- и двухвалютный переводы не попадают в агрегаты', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await f.ensureRub();
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 2);
      final Account rub = await f.seedAccount(name: 'Рублёвый');
      final Account rub2 = await f.seedAccount(name: 'Второй');
      final Account usd = await f.accounts.create(
        name: 'Долларовый',
        kind: AccountKind.card,
        currencyCode: 'USD',
      );
      final Category food = await f.seedCategory(name: 'Еда');

      // Перевод в одной валюте и мультивалютный (D-17): ни тот, ни другой
      // не доход и не расход — в донате и динамике их нет.
      await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: rub2.id,
        amountMinor: 999999,
      );
      await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 500000,
        targetAmountMinor: 5000,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: rub.id,
        categoryId: food.id,
        amountMinor: 10000,
      );

      final List<CategoryExpenseBase> expenses =
          await f.db.transactionsDao.expensesByCategoryForMonthInBase(
        moment: f.clock.read(),
      );
      expect(expenses, hasLength(1));
      expect(expenses.single.amountMinor, 10000);

      final List<MonthTotalsBase> totals =
          await f.db.transactionsDao.totalsByMonthInBase(
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 10, 1),
      );
      expect(totals.single.expenseMinor, 10000);
      expect(totals.single.incomeMinor, 0);
    });

    test('пустой период динамики — отказ invalidInput (как в исходной)', () async {
      final DataLayerFixture f = DataLayerFixture();
      addTearDown(f.dispose);
      await expectLater(
        f.db.transactionsDao.totalsByMonthInBase(
          from: DateTime.utc(2026, 9, 1),
          to: DateTime.utc(2026, 9, 1),
        ),
        throwsA(isA<DataValidationException>()),
      );
    });
  });
}
