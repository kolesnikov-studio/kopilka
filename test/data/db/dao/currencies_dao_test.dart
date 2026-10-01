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

  test(
    'create отклоняет пустой код, пустой символ и неположительный курс',
    () async {
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
    },
  );

  test('повторное создание живой валюты отклоняется', () async {
    await f.currencies.create(code: 'RUB', symbol: '₽');

    await expectLater(
      f.currencies.create(code: 'RUB', symbol: 'руб'),
      throwsA(isA<DataValidationException>()),
    );
  });

  test(
    'удалённая валюта возвращается в справочник с новыми реквизитами',
    () async {
      final Currency created = await f.currencies.create(
        code: 'USD',
        symbol: r'$',
      );
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
    },
  );

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

  test('create с isBase: true демотирует прежнюю базовую (P2)', () async {
    await f.currencies.create(code: 'RUB', symbol: '₽', isBase: true);

    final Currency created = await f.currencies.create(
      code: 'USD',
      symbol: r'$',
      isBase: true,
    );

    // Инвариант «ровно одна базовая» держится и при создании (R9:
    // вставка и демотировка — одна транзакция, как в setBase).
    expect(created.isBase, isTrue);
    expect((await f.currencies.findAlive('RUB'))?.isBase, isFalse);
    expect((await f.currencies.baseCurrency())?.code, 'USD');
  });

  test(
    'воскрешение удалённой валюты с isBase: true тоже демотирует (P2)',
    () async {
      await f.currencies.create(code: 'RUB', symbol: '₽', isBase: true);
      await f.currencies.create(code: 'USD', symbol: r'$');
      await f.currencies.softDelete('USD');

      final Currency revived = await f.currencies.create(
        code: 'USD',
        symbol: r'$',
        isBase: true,
      );

      expect(revived.deletedAt, isNull);
      expect(revived.isBase, isTrue);
      expect((await f.currencies.findAlive('RUB'))?.isBase, isFalse);
      expect((await f.currencies.baseCurrency())?.code, 'USD');
    },
  );

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

  test(
    'updateCurrency отклоняет пустой символ и неположительный курс',
    () async {
      await f.currencies.create(code: 'RUB', symbol: '₽');

      await expectLater(
        f.currencies.updateCurrency('RUB', symbol: const Value<String>('   ')),
        throwsA(isA<DataValidationException>()),
      );
      await expectLater(
        f.currencies.updateCurrency('RUB', rateToBase: const Value<double>(-1)),
        throwsA(isA<DataValidationException>()),
      );
    },
  );

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

  test(
    'валюту живого счёта удалить нельзя, а после удаления счёта — можно',
    () async {
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
    },
  );

  test(
    'валюту можно удалить, даже если счёт не удалён, но валюта другая',
    () async {
      final Account account = await f.seedAccount();
      await f.currencies.create(code: 'USD', symbol: r'$');
      expect(account.currencyCode, 'RUB');

      await f.currencies.softDelete('USD');

      expect(await f.currencies.findAlive('USD'), isNull);
      expect(await f.accounts.findById(account.id), isNotNull);
    },
  );

  group('changeBase — смена базовой с пересчётом курсов (D-20/R9)', () {
    // Набор: RUB базовая (1), USD = 90, EUR = 100, JPY = 0.6.
    Future<void> seedRates() async {
      await f.currencies.create(code: 'RUB', symbol: '₽', isBase: true);
      await f.currencies.create(code: 'USD', symbol: r'$', rateToBase: 90);
      await f.currencies.create(code: 'EUR', symbol: '€', rateToBase: 100);
      await f.currencies.create(code: 'JPY', symbol: '¥', rateToBase: 0.6);
    }

    Future<double> rateOf(String code) async =>
        (await f.currencies.findAlive(code))!.rateToBase;

    test('пересчитывает курсы по формуле rate(v) / rate(newBase)', () async {
      await seedRates();

      await f.currencies.changeBase('USD');

      // Новая базовая — ровно 1 (D-16).
      expect(await rateOf('USD'), 1);
      expect((await f.currencies.baseCurrency())?.code, 'USD');
      // Прежняя базовая: 1 / 90.
      expect(await rateOf('RUB'), closeTo(1 / 90, 1e-12));
      // Остальные: свой курс / старый курс новой базовой.
      expect(await rateOf('EUR'), closeTo(100 / 90, 1e-12));
      expect(await rateOf('JPY'), closeTo(0.6 / 90, 1e-12));
    });

    test('сохраняет относительные курсы валют (инвариант пересчёта)', () async {
      await seedRates();
      // До смены: 1 USD = 90 RUB, 1 EUR = 100 RUB → 1 EUR = 100/90 USD.
      final double eurUsdBefore = 100 / 90;

      await f.currencies.changeBase('USD');

      final double eur = await rateOf('EUR');
      final double rub = await rateOf('RUB');
      // После смены курс EUR к RUB = (100/90) / (1/90) = 100 — не изменился.
      expect(eur / rub, closeTo(100, 1e-9));
      // Курс EUR к новой базовой — тот же коэффициент пересчёта.
      expect(eur, closeTo(eurUsdBefore, 1e-12));
    });

    test(
      'идемпотентен: запрос уже базовой — успешный выход без записи',
      () async {
        await seedRates();
        final DateTime stampBefore = (await f.currencies.findAlive('USD'))!
            .updatedAt;
        f.clock.advance(const Duration(hours: 1));

        await f.currencies.changeBase('RUB');

        // RUB уже была базовой: ничего не записано (updatedAt не тронут).
        expect((await f.currencies.baseCurrency())?.code, 'RUB');
        expect(
          (await f.currencies.findAlive('USD'))!.updatedAt.toUtc(),
          stampBefore.toUtc(),
        );
        expect(await rateOf('USD'), 90);
      },
    );

    test(
      'не найдена живая — отказ notFound (несуществующий и мягко удалённый)',
      () async {
        await seedRates();

        await expectLater(
          f.currencies.changeBase('XXX'),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.notFound,
            ),
          ),
        );

        await f.currencies.softDelete('JPY');
        await expectLater(
          f.currencies.changeBase('JPY'),
          throwsA(
            isA<DataValidationException>().having(
              (DataValidationException e) => e.kind,
              'kind',
              DataFailure.notFound,
            ),
          ),
        );
      },
    );

    test('отказ не меняет состояние (транзакционность, R9)', () async {
      await seedRates();
      final Map<String, Currency> before = <String, Currency>{
        for (final Currency currency in await f.currencies.getAlive())
          currency.code: currency,
      };

      await expectLater(
        f.currencies.changeBase('XXX'),
        throwsA(isA<DataValidationException>()),
      );

      for (final Currency currency in await f.currencies.getAlive()) {
        expect(currency.isBase, before[currency.code]!.isBase);
        expect(currency.rateToBase, before[currency.code]!.rateToBase);
        expect(
          currency.updatedAt.toUtc(),
          before[currency.code]!.updatedAt.toUtc(),
        );
      }
      expect((await f.currencies.baseCurrency())?.code, 'RUB');
    });

    test(
      'мягко удалённая валюта не участвует в пересчёте и не получает флаг',
      () async {
        await seedRates();
        await f.currencies.softDelete('JPY');

        await f.currencies.changeBase('USD');

        final Currency? jpy = await f.currencies.findAlive('JPY');
        expect(jpy, isNull);
        // Строка осталась физически (soft delete, §3) со старым курсом.
        final Currency any = await (f.db.select(
          f.db.currencies,
        )..where((t) => t.code.equals('JPY'))).getSingle();
        expect(any.deletedAt, isNotNull);
        expect(any.isBase, isFalse);
        expect(any.rateToBase, 0.6);
      },
    );

    test('watchAlive отдаёт новое состояние после смены базовой', () async {
      await seedRates();
      final Stream<List<Currency>> stream = f.currencies.watchAlive();

      await f.currencies.changeBase('USD');

      await expectLater(
        stream,
        emitsThrough(
          predicate<List<Currency>>(
            (List<Currency> list) =>
                list.any((Currency c) => c.code == 'USD' && c.isBase) &&
                !list.any((Currency c) => c.code == 'RUB' && c.isBase),
            'USD — базовая, RUB — нет',
          ),
        ),
      );
    });
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
    expect(<String>{
      first.id,
      second.id,
      category.id,
      transaction.id,
    }, hasLength(4));
    expect(
      first.createdAt.toUtc().difference(DateTime.now().toUtc()).abs(),
      lessThan(const Duration(minutes: 5)),
    );
    expect(await f.db.transactionsDao.getFiltered(), hasLength(1));
    expect(await f.db.accountsDao.getAlive(), hasLength(2));
  });
}
