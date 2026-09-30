// Тесты контроллеров фич поверх in-memory слоя данных (§2: UI → контроллеры
// → DAO): потоки, CRUD, объяснение отказов по машиночитаемому виду.
//
// drift импортируется с hide isNull/isNotNull: имена конфликтуют с матчерами
// flutter_test. Даты сравниваем через toUtc (drift отдаёт локальную зону).
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/category_icons.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/accounts/accounts_controller.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/reports/reports_controller.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';

class Fixture {
  Fixture() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
  }

  late final AppDatabase db;
  late final ProviderContainer container;

  AccountsController get accounts =>
      container.read(accountsControllerProvider.notifier);
  CategoriesController get categories =>
      container.read(categoriesControllerProvider.notifier);
  TransactionsController get transactions =>
      container.read(transactionsControllerProvider.notifier);

  Future<String> newAccount(String name, {int initial = 0}) async {
    final Result<Account> result = await accounts.createAccount(
      name: name,
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
      initialBalanceMinor: initial,
    );
    return result.value.id;
  }

  Future<String> newCategory(String name, CategoryKind kind) async {
    final Result<Category> result = await categories.createCategory(
      name: name,
      kind: kind,
      iconCode: defaultCategoryIconCode,
    );
    return result.value.id;
  }
}

/// Ждёт, пока [condition] не станет истинной (bounded): drift-потоки и
/// Riverpod асинхронны — фиксированная пауза или чтение .future после
/// записи не гарантируют выдачу нового значения (гонка).
Future<void> waitUntil(bool Function() condition) async {
  for (int i = 0; i < 200; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('условие не выполнилось за отведённое время');
}

void main() {
  test('посев создаёт базовую валюту и системные категории', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final List<Currency> currencies =
        await f.db.currenciesDao.getAlive();
    expect(currencies, hasLength(1));
    expect(currencies.single.code, baseCurrencyCode);
    expect(currencies.single.isBase, isTrue);

    final List<Category> expense =
        await f.db.categoriesDao.getAlive(kind: CategoryKind.expense);
    final List<Category> income =
        await f.db.categoriesDao.getAlive(kind: CategoryKind.income);
    expect(expense, isNotEmpty);
    expect(income, isNotEmpty);
    expect(expense.every((Category c) => c.isSystem), isTrue);
    expect(income.every((Category c) => c.isSystem), isTrue);

    // M5-шаг 2 (D-55): предустановки сеются с иконками из справочника.
    expect(
      expense.map((Category c) => c.iconCode),
      everyElement(isIn(categoryIconCodes)),
    );
    expect(
      income.map((Category c) => c.iconCode),
      everyElement(isIn(categoryIconCodes)),
    );
    expect(
      expense.firstWhere((Category c) => c.name == 'Продукты').iconCode,
      'groceries',
    );
    expect(
      expense.firstWhere((Category c) => c.name == 'Прочие расходы').iconCode,
      'other',
    );
    expect(
      income.firstWhere((Category c) => c.name == 'Зарплата').iconCode,
      'salary',
    );

    // Идемпотентность: повторный вызов не удваивает набор.
    await seedDefaultsIfEmpty(f.db);
    expect(await f.db.categoriesDao.getAlive(), hasLength(expense.length + income.length));
  });

  test('контроллер счетов: создание и watchBalances отдают баланс DAO', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String id = await f.newAccount('Наличные', initial: 10000);
    final Result<void> expense = await f.transactions.createIncomeOrExpense(
      type: TransactionType.expense,
      accountId: id,
      amountMinor: 1500,
    );
    expect(expense.isSuccess, isTrue);

    final List<AccountBalance> balances = await f.db.accountsDao.getBalances();
    expect(balances, hasLength(1));
    expect(balances.single.balanceMinor, 8500);
  });

  test(
    'удаление счёта с операциями — отказ accountHasTransactions',
    () async {
      final Fixture f = Fixture();
      await seedDefaultsIfEmpty(f.db);

      final String id = await f.newAccount('Карта');
      await f.transactions.createIncomeOrExpense(
        type: TransactionType.income,
        accountId: id,
        amountMinor: 500,
      );

      final Result<void> result = await f.accounts.deleteAccount(id);
      expect(result.isFailure, isTrue);
      expect(result.failure, DataFailure.accountHasTransactions);
    },
  );

  test('удаление чистого счёта проходит', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String id = await f.newAccount('Копилка');
    final Result<void> result = await f.accounts.deleteAccount(id);
    expect(result.isSuccess, isTrue);
    expect(await f.db.accountsDao.getAlive(), isEmpty);
  });

  test('системная категория не удаляется — отказ categoryIsSystem', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final List<Category> expense =
        await f.db.categoriesDao.getAlive(kind: CategoryKind.expense);
    final Result<void> result = await f.categories.deleteCategory(expense.first.id);
    expect(result.isFailure, isTrue);
    expect(result.failure, DataFailure.categoryIsSystem);
  });

  test('категория с операциями не удаляется — отказ categoryHasTransactions',
      () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String accountId = await f.newAccount('Наличные');
    final String categoryId = await f.newCategory('Мойки', CategoryKind.expense);
    await f.transactions.createIncomeOrExpense(
      type: TransactionType.expense,
      accountId: accountId,
      categoryId: categoryId,
      amountMinor: 700,
    );

    final Result<void> result = await f.categories.deleteCategory(categoryId);
    expect(result.isFailure, isTrue);
    expect(result.failure, DataFailure.categoryHasTransactions);
  });

  test('скрытие системной категории убирает из живых потоков, возврат возвращает (M5-шаг 3)',
      () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final List<Category> seeded =
        await f.db.categoriesDao.getAlive(kind: CategoryKind.expense);
    final String id =
        seeded.firstWhere((Category c) => c.name == 'Транспорт').id;

    // Инициализируем потоки (StreamProvider ленивый и умирает без слушателя,
    // замок из теста R5 ниже): до скрытия категория живая, скрытых нет.
    f.container.listen(allCategoriesProvider, (_, _) {});
    f.container.listen(hiddenSystemCategoriesProvider, (_, _) {});
    await waitUntil(
      () => (f.container.read(allCategoriesProvider).value ?? <Category>[])
          .any((Category c) => c.id == id),
    );

    // Скрываем через контроллер — из живого потока категория уходит.
    final Result<Category> hidden = await f.categories.hideCategory(id);
    expect(hidden.isSuccess, isTrue);
    await waitUntil(
      () => (f.container.read(allCategoriesProvider).value ?? <Category>[])
          .every((Category c) => c.id != id),
    );
    expect(
      (f.container.read(allCategoriesProvider).value ?? <Category>[])
          .where((Category c) => c.isSystem),
      isNotEmpty,
      reason: 'остальные предустановки на месте',
    );
    // Скрытая — в потоке скрытых (провайдер настроек).
    await waitUntil(
      () => (f.container
                  .read(hiddenSystemCategoriesProvider)
                  .value ??
              <Category>[])
          .any((Category c) => c.id == id),
    );

    // Возвращаем через контроллер — категория снова во всех живых списках.
    final Result<Category> restored = await f.categories.restoreCategory(id);
    expect(restored.isSuccess, isTrue);
    await waitUntil(
      () => (f.container.read(allCategoriesProvider).value ?? <Category>[])
          .any((Category c) => c.id == id),
    );
    await waitUntil(
      () => (f.container
                  .read(hiddenSystemCategoriesProvider)
                  .value ??
              <Category>[])
          .every((Category c) => c.id != id),
    );
  });

  test('скрытие не-системной и повторное скрытие — отказы; удаление пустой работает (M5-шаг 3)',
      () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String userId = await f.newCategory('Хобби', CategoryKind.expense);
    final Result<Category> notSystem = await f.categories.hideCategory(userId);
    expect(notSystem.isFailure, isTrue);
    expect(notSystem.failure, DataFailure.categoryIsSystem);

    final List<Category> seeded =
        await f.db.categoriesDao.getAlive(kind: CategoryKind.expense);
    final String systemId = seeded.first.id;
    expect((await f.categories.hideCategory(systemId)).isSuccess, isTrue);
    // Повторное скрытие — отказ (уже скрыта, живой строки нет).
    final Result<Category> again = await f.categories.hideCategory(systemId);
    expect(again.isFailure, isTrue);
    expect(again.failure, DataFailure.notFound);

    // Семантика удаления не изменилась: пустая пользовательская удаляется.
    final Result<void> deleted = await f.categories.deleteCategory(userId);
    expect(deleted.isSuccess, isTrue);
    // А системная не удаляется и скрытой — тоже (категорияIsSystem).
    final Result<void> deleteHiddenSystem =
        await f.categories.deleteCategory(systemId);
    expect(deleteHiddenSystem.isFailure, isTrue);
    expect(deleteHiddenSystem.failure, DataFailure.notFound);
  });

  test('операции: расход, доход и перевод обновляют балансы DAO', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String from = await f.newAccount('Списание', initial: 5000);
    final String to = await f.newAccount('Зачисление', initial: 0);

    await f.transactions.createIncomeOrExpense(
      type: TransactionType.income,
      accountId: to,
      amountMinor: 300,
    );
    final Result<Transaction> transfer = await f.transactions.createTransfer(
      accountId: from,
      targetAccountId: to,
      amountMinor: 1000,
    );
    expect(transfer.isSuccess, isTrue);

    final int fromBalance = await f.db.accountsDao.balanceMinor(from);
    final int toBalance = await f.db.accountsDao.balanceMinor(to);
    expect(fromBalance, 4000);
    expect(toBalance, 1300);
  });

  test('перевод на тот же счёт — отказ invalidInput', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String id = await f.newAccount('Единственный');
    final Result<Transaction> result = await f.transactions.createTransfer(
      accountId: id,
      targetAccountId: id,
      amountMinor: 100,
    );
    expect(result.isFailure, isTrue);
    expect(result.failure, DataFailure.invalidInput);
  });

  test('поток фильтра отдаёт операции по типу и поиску по заметке', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String accountId = await f.newAccount('Наличные');
    await f.transactions.createIncomeOrExpense(
      type: TransactionType.income,
      accountId: accountId,
      amountMinor: 1000,
      note: 'аванс',
    );
    await f.transactions.createIncomeOrExpense(
      type: TransactionType.expense,
      accountId: accountId,
      amountMinor: 200,
      note: 'кофе',
    );

    final List<Transaction> incomes = await f.db.transactionsDao.getFiltered(
      const TransactionFilter(type: TransactionType.income),
    );
    expect(incomes, hasLength(1));
    expect(incomes.single.note, 'аванс');

    final List<Transaction> searched = await f.db.transactionsDao.getFiltered(
      const TransactionFilter(search: 'кофе'),
    );
    expect(searched, hasLength(1));
    expect(TransactionType.fromDb(searched.single.type),
        TransactionType.expense);
  });

  test('операция удаляется мягко: строка остаётся в таблице', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    final String accountId = await f.newAccount('Наличные');
    final Result<Transaction> created = await f.transactions
        .createIncomeOrExpense(
      type: TransactionType.expense,
      accountId: accountId,
      amountMinor: 100,
    );

    final Result<void> result =
        await f.transactions.deleteTransaction(created.value.id);
    expect(result.isSuccess, isTrue);
    expect(await f.db.transactionsDao.getFiltered(), isEmpty);

    final List<QueryRow> raw = await f.db
        .customSelect('SELECT COUNT(*) AS count FROM transactions')
        .get();
    expect(raw.single.read<int>('count'), 1);
  });

  test('currenciesMapProvider: карта код → валюта (R5), базовая из потока (R5)',
      () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);

    // autoDispose-провайдеры живут, только пока есть слушатель.
    f.container.listen(currenciesMapProvider, (_, _) {});
    f.container.listen(baseCurrencyStreamProvider, (_, _) {});

    final Map<String, Currency> map =
        await f.container.read(currenciesMapProvider.future);
    expect(map[baseCurrencyCode], isNotNull);
    expect(map[baseCurrencyCode]!.isBase, isTrue);

    final Currency base =
        await f.container.read(baseCurrencyStreamProvider.future);
    expect(base.code, baseCurrencyCode);
    expect(base.symbol, '₽');

    // Символ по коду — то, чем пользуются плитки после R4/R5.
    expect(map['RUB']!.symbol, '₽');
  });

  test('общий баланс дашборда: конвертация по текущему курсу (D-18)', () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);
    // Слушатель держит autoDispose-провайдер живым между чтениями.
    f.container.listen(totalBalanceProvider, (_, _) {});

    // Счёт в базовой: 1000,00; счёт в USD: 20,00 × курс 2 = 40,00.
    await f.db.accountsDao.create(
      name: 'Рублёвый',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
      initialBalanceMinor: 100000,
    );
    await f.db.currenciesDao.create(code: 'USD', symbol: r'$', rateToBase: 2);
    await f.db.accountsDao.create(
      name: 'Долларовый',
      kind: AccountKind.card,
      currencyCode: 'USD',
      initialBalanceMinor: 2000,
    );

    await waitUntil(
      () => f.container.read(totalBalanceProvider).value == 104000,
    );

    // Смена курса пересчитывает итог без перезапуска (D-18).
    await f.db.currenciesDao.updateCurrency(
      'USD',
      rateToBase: const Value<double>(4),
    );
    await waitUntil(
      () => f.container.read(totalBalanceProvider).value == 108000,
    );
  });

  test(
    'счёт с флагом «не учитывать в балансе» выпадает из суммарного, персональный цел (v5/D-54)',
    () async {
      final Fixture f = Fixture();
      await seedDefaultsIfEmpty(f.db);
      f.container.listen(totalBalanceProvider, (_, _) {});

      final String normal = await f.newAccount('Рублёвый', initial: 100000);
      final Account excluded = await f.db.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.bank,
        currencyCode: baseCurrencyCode,
        initialBalanceMinor: 900000,
        excludeFromBalance: true,
      );
      // У исключённого счёта живёт история: её смена не должна попадать
      // в общий итог.
      await f.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: excluded.id,
        amountMinor: 50000,
      );

      // В суммарном — только обычный счёт; накопительный с балансом
      // 850 000 не раздувает итог (идея 14/D-54).
      await waitUntil(
        () => f.container.read(totalBalanceProvider).value == 100000,
      );

      // Персональный баланс исключённого счёта не изменился.
      expect(
        await f.db.accountsDao.balanceMinor(excluded.id),
        850000,
      );

      // Переключение флага у живого счёта возвращает его в суммарный.
      await f.db.accountsDao.updateAccount(
        excluded.id,
        excludeFromBalance: const Value<bool>(false),
      );
      await waitUntil(
        () => f.container.read(totalBalanceProvider).value == 950000,
      );

      // И обратно: включение флага убирает счёт из суммы.
      await f.db.accountsDao.updateAccount(
        normal,
        excludeFromBalance: const Value<bool>(true),
      );
      await waitUntil(
        () => f.container.read(totalBalanceProvider).value == 850000,
      );
    },
  );

  test(
    'DoD v0.5: флаг «не учитывать в балансе» не трогает донат и динамику — '
    'операции исключённого счёта считаются в отчётах (D-54/D-60)',
    () async {
      final Fixture f = Fixture();
      await seedDefaultsIfEmpty(f.db);
      f.container.listen(totalBalanceProvider, (_, _) {});
      f.container.listen(expensesByCategoryProvider, (_, _) {});
      f.container.listen(monthTotalsProvider, (_, _) {});

      // Отчётный месяц зафиксирован — тест не зависит от реальной даты.
      final DateTime month = DateTime.utc(2026, 9, 15);
      f.container.read(reportsMonthProvider.notifier).state = month;

      final Account excluded = await f.db.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.bank,
        currencyCode: baseCurrencyCode,
        excludeFromBalance: true,
      );
      final String hobby = await f.newCategory('Хобби', CategoryKind.expense);
      await f.db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: excluded.id,
        categoryId: hobby,
        amountMinor: 50000,
        date: month,
      );

      // Расход исключённого счёта виден в донате и динамике: исключение
      // по D-60 живёт только в общем балансе, отчёты честные.
      await waitUntil(
        () => (f.container.read(expensesByCategoryProvider).value ??
                    const <CategoryExpenseBase>[])
                .length ==
            1,
      );
      expect(
        f.container.read(expensesByCategoryProvider).value!.single.amountMinor,
        50000,
      );
      expect(
        f.container.read(expensesByCategoryProvider).value!.single.categoryName,
        'Хобби',
      );
      final MonthTotalsBase september =
          (f.container.read(monthTotalsProvider).value ?? const <MonthTotalsBase>[])
              .singleWhere((MonthTotalsBase t) => t.monthKey == '2026-09');
      expect(september.expenseMinor, 50000);
      expect(september.incomeMinor, 0);

      // Переключение флага общий баланс меняет, агрегаты отчётов — нет:
      // граница решения D-60, SQL отчётов флаг не читает.
      await f.db.accountsDao.updateAccount(
        excluded.id,
        excludeFromBalance: const Value<bool>(false),
      );
      await waitUntil(
        () => f.container.read(totalBalanceProvider).value == -50000,
      );
      expect(
        f.container.read(expensesByCategoryProvider).value!.single.amountMinor,
        50000,
        reason: 'донат считает операции и учитываемого счёта так же',
      );
      final MonthTotalsBase septemberAfter =
          (f.container.read(monthTotalsProvider).value ?? const <MonthTotalsBase>[])
              .singleWhere((MonthTotalsBase t) => t.monthKey == '2026-09');
      expect(septemberAfter.expenseMinor, 50000);
    },
  );

  test('reportsMultiCurrencyProvider: одна валюта — false, две — true (B5)',
      () async {
    final Fixture f = Fixture();
    await seedDefaultsIfEmpty(f.db);
    f.container.listen(reportsMultiCurrencyProvider, (_, _) {});

    await f.newAccount('Рублёвый');
    await waitUntil(
      () => f.container.read(reportsMultiCurrencyProvider).value == false,
    );

    await f.db.currenciesDao.create(code: 'USD', symbol: r'$', rateToBase: 2);
    await f.db.accountsDao.create(
      name: 'Долларовый',
      kind: AccountKind.card,
      currencyCode: 'USD',
    );
    await waitUntil(
      () => f.container.read(reportsMultiCurrencyProvider).value == true,
    );
  });

  test('convertBalanceToBase: half-up по модулю, знак отдельно (D-22)', () {
    int convert(int minor, double rate) => convertBalanceToBase(
          AccountBalance(
            account: Account(
              id: 'a',
              name: 'А',
              kind: 'cash',
              currencyCode: 'USD',
              initialBalanceMinor: 0,
              sortOrder: 0,
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
            balanceMinor: minor,
          ),
          <String, double>{'USD': rate},
        );

    // Половина округляется вверх по модулю: 0.5 → 1, −0.5 → −1.
    expect(convert(1, 0.5), 1);
    expect(convert(-1, 0.5), -1);
    expect(convert(2500, 1.0005), 2501);
    expect(convert(-2500, 1.0005), -2501);
    // Курс 1 и отсутствующий код — без изменений.
    expect(convert(12345, 1.0), 12345);
    expect(convert(12345, 1.0), 12345);
  });
}
