// Тесты контроллеров фич поверх in-memory слоя данных (§2: UI → контроллеры
// → DAO): потоки, CRUD, объяснение отказов по машиночитаемому виду.
//
// drift импортируется с hide isNull/isNotNull: имена конфликтуют с матчерами
// flutter_test. Даты сравниваем через toUtc (drift отдаёт локальную зону).
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
