// Тесты справочника валют: нормализация, базовая валюта, soft delete
// с защитой от удаления используемой валюты.
//
// isNull и isNotNull из drift конфликтуют с матчерами flutter_test —
// скрываем drift-варианты (те же имена, но SQL-выражения).
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

  test('create нормализует код и символ, ставит штампы UTC', () async {
    final Currency currency = await f.currencies.create(
      code: '  rub ',
      symbol: ' ₽ ',
    );

    expect(currency.code, 'RUB');
    expect(currency.symbol, '₽');
    expect(currency.isBase, isFalse);
    expect(currency.rateToBase, 1);
    expect(currency.createdAt.toUtc(), f.clock.read());
    expect(currency.updatedAt.toUtc(), f.clock.read());
    expect(currency.deletedAt, isNull);
  });

  test('create отклоняет пустой код, пустой символ и неположительный курс', () async {
    await expectLater(
      f.currencies.create(code: '   ', symbol: '₽'),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.currencies.create(code: 'RUB', symbol: '  '),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.currencies.create(code: 'RUB', symbol: '₽', rateToBase: 0),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('повторное создание живой валюты отклоняется', () async {
    await f.currencies.create(code: 'RUB', symbol: '₽');

    await expectLater(
      f.currencies.create(code: 'RUB', symbol: 'руб'),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('удалённая валюта возвращается в справочник с новыми реквизитами', () async {
    final Currency created = await f.currencies.create(code: 'USD', symbol: r'$');
    f.clock.advance(const Duration(hours: 1));
    await f.currencies.softDelete('USD');
    expect(await f.currencies.findAlive('USD'), isNull);

    final Currency revived = await f.currencies.create(
      code: 'USD',
      symbol: r'US$',
      rateToBase: 2,
    );

    expect(revived.code, 'USD');
    expect(revived.symbol, r'US$');
    expect(revived.rateToBase, 2);
    expect(revived.deletedAt, isNull);
    expect(revived.createdAt.toUtc(), created.createdAt.toUtc());
    expect(revived.updatedAt.toUtc(), f.clock.read());
  });

  test('getAlive сортирует по коду, watchAlive отдаёт изменения', () async {
    await f.currencies.create(code: 'USD', symbol: r'$');
    await f.currencies.create(code: 'EUR', symbol: '€');

    final List<Currency> alive = await f.currencies.getAlive();
    expect(alive.map((Currency c) => c.code), <String>['EUR', 'USD']);

    final Stream<List<Currency>> stream = f.currencies.watchAlive();
    await f.currencies.create(code: 'RUB', symbol: '₽');

    await expectLater(
      stream,
      emitsThrough(
        predicate<List<Currency>>(
          (List<Currency> list) => list.length == 3,
          'три живые валюты',
        ),
      ),
    );
  });

  test('setBase снимает флаг с прежней базовой валюты', () async {
    await f.currencies.create(code: 'RUB', symbol: '₽', isBase: true);
    await f.currencies.create(code: 'USD', symbol: r'$');

    expect((await f.currencies.baseCurrency())?.code, 'RUB');

    await f.currencies.setBase('USD');

    expect((await f.currencies.baseCurrency())?.code, 'USD');
    expect((await f.currencies.findAlive('RUB'))?.isBase, isFalse);
    expect(await f.currencies.findAlive('USD'), isNotNull);
  });

  test('updateCurrency меняет реквизиты и трогает только updated_at', () async {
    final Currency created = await f.currencies.create(
      code: 'RUB',
      symbol: '₽',
    );
    f.clock.advance(const Duration(minutes: 30));

    final Currency updated = await f.currencies.updateCurrency(
      'RUB',
      symbol: const Value<String>(' руб.'),
      rateToBase: const Value<double>(1.5),
    );

    expect(updated.symbol, 'руб.');
    expect(updated.rateToBase, 1.5);
    expect(updated.createdAt.toUtc(), created.createdAt.toUtc());
    expect(updated.updatedAt.toUtc(), f.clock.read());
    expect(updated.updatedAt.toUtc(), isNot(created.updatedAt.toUtc()));
  });

  test('updateCurrency отклоняет пустой символ и неположительный курс', () async {
    await f.currencies.create(code: 'RUB', symbol: '₽');

    await expectLater(
      f.currencies.updateCurrency('RUB', symbol: const Value<String>('   ')),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.currencies.updateCurrency('RUB', rateToBase: const Value<double>(-1)),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('операции с несуществующим кодом отклоняются', () async {
    expect(await f.currencies.findAlive('XXX'), isNull);
    await expectLater(
      f.currencies.updateCurrency('XXX', symbol: const Value<String>('?')),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.currencies.setBase('XXX'),
      throwsA(isA<DataValidationException>()),
    );
    await expectLater(
      f.currencies.softDelete('XXX'),
      throwsA(isA<DataValidationException>()),
    );
  });

  test('валюту живого счёта удалить нельзя, а после удаления счёта — можно', () async {
    final Account account = await f.seedAccount();

    await expectLater(
      f.currencies.softDelete('RUB'),
      throwsA(isA<DataValidationException>()),
    );

    await f.accounts.softDelete(account.id);
    await f.currencies.softDelete('RUB');

    expect(await f.currencies.findAlive('RUB'), isNull);
    expect(await rawRowCount(f.db, 'currencies'), 1);
    expect(
      (await (f.db.select(f.db.currencies)).getSingle()).deletedAt?.toUtc(),
      f.clock.read(),
    );
  });

  test('валюту можно удалить, даже если счёт не удалён, но валюта другая', () async {
    final Account account = await f.seedAccount();
    await f.currencies.create(code: 'USD', symbol: r'$');
    expect(account.currencyCode, 'RUB');

    await f.currencies.softDelete('USD');

    expect(await f.currencies.findAlive('USD'), isNull);
    expect(await f.accounts.findById(account.id), isNotNull);
  });

  test('DAOs подключены к БД: ключи — UUID v4, часы настоящие', () async {
    await f.currencies.create(code: 'RUB', symbol: '₽');
    final Account first = await f.db.accountsDao.create(
      name: 'Первый',
      kind: AccountKind.bank,
      currencyCode: 'RUB',
    );
    final Account second = await f.db.accountsDao.create(
      name: 'Второй',
      kind: AccountKind.bank,
      currencyCode: 'RUB',
    );
    final Category category = await f.db.categoriesDao.create(
      name: 'Продукты',
      kind: CategoryKind.expense,
    );
    final Transaction transaction = await f.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: first.id,
      categoryId: category.id,
      amountMinor: 100,
    );

    expect(first.id, matches(uuidV4));
    expect(second.id, matches(uuidV4));
    expect(category.id, matches(uuidV4));
    expect(transaction.id, matches(uuidV4));
    expect(
      <String>{first.id, second.id, category.id, transaction.id},
      hasLength(4),
    );
    expect(
      first.createdAt.toUtc().difference(DateTime.now().toUtc()).abs(),
      lessThan(const Duration(minutes: 5)),
    );
    expect(await f.db.transactionsDao.getFiltered(), hasLength(1));
    expect(await f.db.accountsDao.getAlive(), hasLength(2));
  });
}
