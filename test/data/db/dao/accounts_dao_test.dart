// Тесты счетов: CRUD, soft delete и главное — балансы, вычисляемые запросом
// из начального остатка и живых операций (§3: балансы не хранятся).
//
// isNull и isNotNull из drift конфликтуют с матчерами flutter_test.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
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

  test('create: порядок в списке и штампы по умолчанию', () async {
    final Account cash = await f.seedAccount(name: 'Наличные');
    final Account card = await f.seedAccount(
      name: 'Карта',
      kind: AccountKind.card,
    );

    expect(cash.id, 'acc-1');
    expect(card.id, 'acc-2');
    expect(cash.sortOrder, 0);
    expect(card.sortOrder, 1);
    expect(cash.initialBalanceMinor, 0);
    expect(AccountKind.fromDb(cash.kind), AccountKind.cash);
    expect(AccountKind.fromDb(card.kind), AccountKind.card);
    expect(cash.createdAt.toUtc(), f.clock.read());
    expect(cash.updatedAt.toUtc(), f.clock.read());
    expect(cash.deletedAt, isNull);
  });

  test('create отклоняет пустое название и недоступную валюту', () async {
    await f.ensureRub();

    await expectLater(
      f.accounts.create(
        name: '   ',
        kind: AccountKind.cash,
        currencyCode: 'RUB',
      ),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.accounts.create(
        name: 'Счёт',
        kind: AccountKind.cash,
        currencyCode: 'USD',
      ),
      throwsA(isA<DataValidationException>()),
    );

    await f.currencies.create(code: 'USD', symbol: r'$');
    await f.currencies.softDelete('USD');
    await expectLater(
      f.accounts.create(
        name: 'Счёт',
        kind: AccountKind.cash,
        currencyCode: 'USD',
      ),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('баланс без операций равен начальному остатку, включая минус', () async {
    final Account cash = await f.seedAccount(initialBalanceMinor: 100000);
    final Account credit = await f.seedAccount(
      name: 'Кредитка',
      kind: AccountKind.card,
      initialBalanceMinor: -50000,
    );

    expect(await f.accounts.balanceMinor(cash.id), 100000);
    expect(await f.accounts.balanceMinor(credit.id), -50000);
  });

  test('доход увеличивает баланс, расход уменьшает', () async {
    final Account account = await f.seedAccount(initialBalanceMinor: 100000);

    await f.transactions.create(
      type: TransactionType.income,
      accountId: account.id,
      amountMinor: 30000,
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      amountMinor: 12345,
    );

    expect(await f.accounts.balanceMinor(account.id), 100000 + 30000 - 12345);
  });

  test('перевод списывает со счёта-источника и зачисляет целевому', () async {
    final Account first = await f.seedAccount(
      name: 'Наличные',
      initialBalanceMinor: 100000,
    );
    final Account second = await f.seedAccount(
      name: 'Карта',
      kind: AccountKind.card,
      initialBalanceMinor: 5000,
    );

    await f.transactions.create(
      type: TransactionType.transfer,
      accountId: first.id,
      targetAccountId: second.id,
      amountMinor: 20000,
    );

    expect(await f.accounts.balanceMinor(first.id), 80000);
    expect(await f.accounts.balanceMinor(second.id), 25000);
  });

  test(
    'инвариант D-17: мультивалютный перевод зачисляет target_amount_minor',
    () async {
      // Регресс DoD M3-шага 7: входящий перевод раньше crédитировался
      // суммой списания (amount_minor, валютой источника) — баланс
      // целевого счёта и общий баланс дашборда уезжали в разы.
      final Account rub = await f.seedAccount(
        name: 'Рубли',
        initialBalanceMinor: 1000000,
      );
      await f.seedCurrency('USD', symbol: r'$', rateToBase: 100);
      final Account usd = await f.seedAccount(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );

      await f.transactions.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 500000, // списание 5 000,00 ₽
        targetAmountMinor: 5000, // зачисление 50,00 $
      );

      // Списание — по сумме списания, зачисление — по сумме зачисления.
      expect(await f.accounts.balanceMinor(rub.id), 500000);
      expect(await f.accounts.balanceMinor(usd.id), 5000);
      expect(
        (await f.accounts.getBalances())
            .map((AccountBalance b) => b.balanceMinor),
        <int>[500000, 5000],
      );
    },
  );

  test('удалённые операции в балансе не учитываются', () async {
    final Account account = await f.seedAccount(initialBalanceMinor: 100000);
    final Transaction expense = await f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      amountMinor: 40000,
    );
    expect(await f.accounts.balanceMinor(account.id), 60000);

    await f.transactions.softDelete(expense.id);

    expect(await f.accounts.balanceMinor(account.id), 100000);
    expect(await rawRowCount(f.db, 'transactions'), 1);
  });

  test('getBalances: порядок как у списка счетов, баланс свой у каждого', () async {
    final Account second = await f.seedAccount(
      name: 'Карта',
      kind: AccountKind.card,
      initialBalanceMinor: 5000,
    );
    final Account first = await f.accounts.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: 'RUB',
      initialBalanceMinor: 100000,
      sortOrder: -1,
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: second.id,
      amountMinor: 3000,
    );

    final List<AccountBalance> balances = await f.accounts.getBalances();

    expect(
      balances.map((AccountBalance b) => b.account.name),
      <String>['Наличные', 'Карта'],
    );
    expect(balances.map((AccountBalance b) => b.balanceMinor), <int>[100000, 2000]);
    expect(balances.first.account.id, first.id);
  });

  test('watchBalances пересчитывается при новой операции', () async {
    final Account account = await f.seedAccount(initialBalanceMinor: 100000);
    final Stream<List<AccountBalance>> stream = f.accounts.watchBalances();

    await f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      amountMinor: 25000,
    );

    await expectLater(
      stream,
      emitsThrough(
        predicate<List<AccountBalance>>(
          (List<AccountBalance> list) => list.single.balanceMinor == 75000,
          'баланс 75 000',
        ),
      ),
    );
  });

  test('balanceMinor по неизвестному счёту отклоняется', () async {
    await expectLater(
      f.accounts.balanceMinor('нет-такого'),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('balanceMinor (однострочный SQL, R6) совпадает с watchBalances', () async {
    final Account first = await f.seedAccount(initialBalanceMinor: 100000);
    final Account second = await f.seedAccount(
      name: 'Вторая',
      initialBalanceMinor: 50000,
    );
    await f.transactions.create(
      type: TransactionType.income,
      accountId: first.id,
      amountMinor: 30000,
    );
    await f.transactions.create(
      type: TransactionType.expense,
      accountId: first.id,
      amountMinor: 12345,
    );
    await f.transactions.create(
      type: TransactionType.transfer,
      accountId: second.id,
      targetAccountId: first.id,
      amountMinor: 7000,
    );

    final int single = await f.accounts.balanceMinor(first.id);
    final int fromStream = (await f.accounts.watchBalances().first)
        .firstWhere((AccountBalance b) => b.account.id == first.id)
        .balanceMinor;
    expect(single, 100000 + 30000 - 12345 + 7000);
    expect(single, fromStream);
  });

  test('updateAccount меняет поля и обновляет только updatedAt', () async {
    final Account created = await f.seedAccount();
    f.clock.advance(const Duration(days: 1));

    final Account updated = await f.accounts.updateAccount(
      created.id,
      name: const Value<String>('  Кошелёк '),
      kind: const Value<AccountKind>(AccountKind.other),
      initialBalanceMinor: const Value<int>(-100),
      sortOrder: const Value<int>(5),
    );

    expect(updated.name, 'Кошелёк');
    expect(AccountKind.fromDb(updated.kind), AccountKind.other);
    expect(updated.initialBalanceMinor, -100);
    expect(updated.sortOrder, 5);
    expect(updated.currencyCode, 'RUB');
    expect(updated.createdAt.toUtc(), created.createdAt.toUtc());
    expect(updated.updatedAt.toUtc(), f.clock.read());
  });

  test('updateAccount отклоняет пустое название и неизвестный счёт', () async {
    final Account account = await f.seedAccount();

    await expectLater(
      f.accounts.updateAccount(account.id, name: const Value<String>('  ')),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.accounts.updateAccount('нет-такого', name: const Value<String>('Х')),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('смена валюты счёта запрещена, пока есть живые операции', () async {
    final Account account = await f.seedAccount(initialBalanceMinor: 1000);
    await f.currencies.create(code: 'USD', symbol: r'$');
    final Transaction expense = await f.transactions.create(
      type: TransactionType.expense,
      accountId: account.id,
      amountMinor: 100,
    );

    await expectLater(
      f.accounts.updateAccount(
        account.id,
        currencyCode: const Value<String>('USD'),
      ),
      throwsA(isA<DataValidationException>()),
    );

    await f.transactions.softDelete(expense.id);
    final Account updated = await f.accounts.updateAccount(
      account.id,
      currencyCode: const Value<String>('USD'),
    );

    expect(updated.currencyCode, 'USD');
  });

  test('softDelete запрещён, пока на счёт ссылаются живые операции', () async {
    final Account source = await f.seedAccount(name: 'Наличные');
    final Account target = await f.seedAccount(
      name: 'Карта',
      kind: AccountKind.card,
    );
    final Transaction transfer = await f.transactions.create(
      type: TransactionType.transfer,
      accountId: source.id,
      targetAccountId: target.id,
      amountMinor: 1000,
    );

    await expectLater(
      f.accounts.softDelete(source.id),
      throwsA(isA<DataValidationException>()),
    );
    // Счёт зачисления тоже защищён: у операции два конца.
    await expectLater(
      f.accounts.softDelete(target.id),
      throwsA(isA<DataValidationException>()),
    );
    expect(await f.accounts.getAlive(), hasLength(2));

    await f.transactions.softDelete(transfer.id);
    await f.accounts.softDelete(source.id);

    expect((await f.accounts.getAlive()).single.id, target.id);
    expect(await f.accounts.findById(source.id), isNull);
    expect(await rawRowCount(f.db, 'accounts'), 2);
    await expectLater(
      f.accounts.softDelete(source.id),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('watchAlive отдаёт изменения списка счетов', () async {
    final Stream<List<Account>> stream = f.accounts.watchAlive();
    await f.seedAccount();

    await expectLater(stream, emitsThrough(hasLength(1)));
  });

  test('create: флаг exclude_from_balance сохраняется (v5/D-54)', () async {
    await f.ensureRub();
    final Account excluded = await f.accounts.create(
      name: 'Накопления',
      kind: AccountKind.bank,
      currencyCode: 'RUB',
      initialBalanceMinor: 500000,
      excludeFromBalance: true,
    );
    expect(excluded.excludeFromBalance, isTrue);

    // Дефолт: флага нет — false, а не NULL (DAO пишет bool всегда).
    final Account normal = await f.seedAccount(name: 'Обычный');
    expect(normal.excludeFromBalance, isFalse);
  });

  test(
    'балансные агрегаты: счёт с флагом остаётся в выдаче, баланс свой (v5/D-54)',
    () async {
      // Решение по брифу: исключение из СУММАРНОГО баланса — на уровне
      // агрегата контроллера отчётов; _balanceExpression (§8) не тронут,
      // поэтому DAO обязан отдавать строку исключённого счёта с его
      // персональным балансом как раньше.
      final Account normal = await f.seedAccount(initialBalanceMinor: 100000);
      final Account excluded = await f.accounts.create(
        name: 'Накопления',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
        initialBalanceMinor: 900000,
        excludeFromBalance: true,
      );
      await f.transactions.create(
        type: TransactionType.expense,
        accountId: excluded.id,
        amountMinor: 50000,
      );

      final List<AccountBalance> balances = await f.accounts.getBalances();
      // Строка исключённого счёта не выпадает из потока балансов.
      expect(balances, hasLength(2));
      expect(
        balances.firstWhere((AccountBalance b) => b.account.id == excluded.id)
            .balanceMinor,
        850000,
        reason: 'персональный баланс исключённого счёта не меняется',
      );
      expect(
        balances.firstWhere((AccountBalance b) => b.account.id == normal.id)
            .balanceMinor,
        100000,
      );
      expect(await f.accounts.balanceMinor(excluded.id), 850000);
    },
  );

  test('updateAccount переключает флаг у живого счёта (v5/D-54)', () async {
    final Account account = await f.seedAccount(initialBalanceMinor: 100000);
    expect(account.excludeFromBalance, isFalse);

    f.clock.advance(const Duration(days: 1));
    final Account excluded = await f.accounts.updateAccount(
      account.id,
      excludeFromBalance: const Value<bool>(true),
    );
    expect(excluded.excludeFromBalance, isTrue);
    expect(excluded.updatedAt.toUtc(), f.clock.read());
    expect(excluded.createdAt.toUtc(), account.createdAt.toUtc());

    // Обратное переключение: флаг снимается.
    final Account restored = await f.accounts.updateAccount(
      account.id,
      excludeFromBalance: const Value<bool>(false),
    );
    expect(restored.excludeFromBalance, isFalse);

    // Value.absent() — поле не менять (семантика частичных обновлений A1).
    final Account untouched = await f.accounts.updateAccount(
      account.id,
      name: const Value<String>('Переименованный'),
    );
    expect(untouched.excludeFromBalance, isFalse);
    expect(untouched.name, 'Переименованный');
  });
}
