// Тесты синхронизации курсов (D-36, M4-шаг 1): разбор ответа источника,
// применение курсов к справочнику через DAO и сервис end-to-end на
// фейковом http.Client (сеть не трогается).
//
// In-memory drift (DataLayerFixture) + MockClient — те же приёмы, что в
// тестах update-сервиса и DAO.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/rates/rate_sync_service.dart';

http.Response ratesResponse(Map<String, Object?> rates) =>
    http.Response(
      jsonEncode(<String, dynamic>{'result': 'success', 'rates': rates}),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );

http.Client clientAnswering(Future<http.Response> Function() answer) =>
    MockClient((http.Request request) async => answer());

/// Фикстура со справочником RUB(база) + USD + EUR.
class RatesFixture {
  RatesFixture()
    : db = AppDatabase.forTesting(NativeDatabase.memory()) {
    dao = CurrenciesDao(db);
  }

  final AppDatabase db;
  late final CurrenciesDao dao;

  Future<void> seed() async {
    await dao.create(code: 'RUB', symbol: '₽', isBase: true);
    await dao.create(code: 'USD', symbol: r'$', rateToBase: 90);
    await dao.create(code: 'EUR', symbol: '€', rateToBase: 100);
  }

  Future<void> dispose() => db.close();

  Future<double> rateOf(String code) async =>
      (await dao.findAlive(code))!.rateToBase;
}

void main() {
  group('parseRatesResponse', () {
    test('читает success-ответ со словарём чисел', () {
      final Map<String, double>? rates = parseRatesResponse(<String, dynamic>{
        'result': 'success',
        'rates': <String, dynamic>{'USD': 90.5, 'EUR': 100},
      });
      expect(rates, <String, double>{'USD': 90.5, 'EUR': 100});
    });

    test('не success, не объект или без словаря rates — null', () {
      expect(parseRatesResponse(<String, dynamic>{'result': 'failure'}),
          isNull);
      expect(parseRatesResponse(<String>['список']), isNull);
      expect(parseRatesResponse('строка'), isNull);
      expect(
        parseRatesResponse(<String, dynamic>{'result': 'success'}),
        isNull,
      );
      expect(
        parseRatesResponse(<String, dynamic>{
          'result': 'success',
          'rates': <String, dynamic>{},
        }),
        isNull,
      );
    });

    test('нечисловой или неположительный курс — null (весь ответ)', () {
      expect(
        parseRatesResponse(<String, dynamic>{
          'result': 'success',
          'rates': <String, dynamic>{'USD': '90'},
        }),
        isNull,
      );
      expect(
        parseRatesResponse(<String, dynamic>{
          'result': 'success',
          'rates': <String, dynamic>{'USD': 90, 'XXX': 0},
        }),
        isNull,
      );
      expect(
        parseRatesResponse(<String, dynamic>{
          'result': 'success',
          'rates': <String, dynamic>{'USD': -1},
        }),
        isNull,
      );
    });
  });

  group('applyRates (запись в справочник через DAO)', () {
    late RatesFixture f;

    setUp(() => f = RatesFixture());
    tearDown(() => f.dispose());

    test('небазовые валюты из словаря получают курс источника', () async {
      await f.seed();

      final RateSyncResult result = await RateSyncService().applyRates(
        f.dao,
        <String, double>{'USD': 80.5, 'EUR': 95.25},
        baseCode: 'RUB',
      );

      expect(result, isA<RateSyncUpdated>());
      expect((result as RateSyncUpdated).updatedCount, 2);
      expect(await f.rateOf('USD'), 80.5);
      expect(await f.rateOf('EUR'), 95.25);
    });

    test('база не трогается, валюты вне словаря пропускаются (не добавляются)',
        () async {
      await f.seed();

      final RateSyncResult result = await RateSyncService().applyRates(
        f.dao,
        <String, double>{'RUB': 1, 'USD': 80, 'JPY': 0.5},
        baseCode: 'RUB',
      );

      // JPY в базе пользователя нет — не создаётся; обновлён только USD.
      expect((result as RateSyncUpdated).updatedCount, 1);
      expect(await f.dao.findAlive('JPY'), isNull);
      expect(await f.rateOf('RUB'), 1);
      expect((await f.dao.baseCurrency())?.code, 'RUB');
      expect(await f.rateOf('EUR'), 100, reason: 'вне словаря — прежний курс');
    });

    test('мягко удалённая валюта не участвует', () async {
      await f.seed();
      await f.dao.softDelete('EUR');

      final RateSyncResult result = await RateSyncService().applyRates(
        f.dao,
        <String, double>{'USD': 80, 'EUR': 95},
        baseCode: 'RUB',
      );

      expect((result as RateSyncUpdated).updatedCount, 1);
      expect(await f.dao.findAlive('EUR'), isNull);
    });

    test('повторный запуск идемпотентен (тот же источник — то же состояние)',
        () async {
      await f.seed();
      final RateSyncService service = RateSyncService();
      final Map<String, double> rates = <String, double>{'USD': 80, 'EUR': 95};

      await service.applyRates(f.dao, rates, baseCode: 'RUB');
      final DateTime stamp = (await f.dao.findAlive('USD'))!.updatedAt;
      final RateSyncResult second =
          await service.applyRates(f.dao, rates, baseCode: 'RUB');

      expect(second, isA<RateSyncUpdated>());
      expect((second as RateSyncUpdated).updatedCount, 2);
      expect((await f.dao.findAlive('USD'))!.updatedAt, stamp,
          reason: 'повторная запись того же курса перезаписывает строку — '
              'состояние справочника идемпотентно');
      expect(await f.rateOf('USD'), 80);
      expect(await f.rateOf('EUR'), 95);
    });
  });

  group('RateSyncService.syncNow (end-to-end на MockClient)', () {
    late RatesFixture f;

    setUp(() => f = RatesFixture());
    tearDown(() => f.dispose());

    test('успех: запрос к источнику, курсы записаны, база не тронута',
        () async {
      await f.seed();
      late Uri requestedUrl;
      final RateSyncResult result = await RateSyncService(
        client: MockClient((http.Request request) async {
          requestedUrl = request.url;
          return ratesResponse(<String, Object?>{
            'USD': 80.5,
            'EUR': 95.25,
            'JPY': 0.55,
          });
        }),
      ).syncNow(f.dao);

      expect(requestedUrl.host, 'open.er-api.com');
      expect(requestedUrl.path, '/v6/latest/RUB');
      expect(result, isA<RateSyncUpdated>());
      expect((result as RateSyncUpdated).updatedCount, 2);
      expect(await f.rateOf('USD'), 80.5);
      expect(await f.rateOf('EUR'), 95.25);
      expect(await f.dao.findAlive('JPY'), isNull);
      expect(await f.rateOf('RUB'), 1);
    });

    test('таймаут: тихий отказ, курсы не изменились', () async {
      await f.seed();
      final RateSyncResult result = await RateSyncService(
        timeout: const Duration(milliseconds: 20),
        client: MockClient((http.Request request) async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return ratesResponse(<String, Object?>{'USD': 1});
        }),
      ).syncNow(f.dao);

      expect(result, isA<RateSyncOffline>());
      expect(await f.rateOf('USD'), 90, reason: 'D-36: остаются последние');
      expect(await f.rateOf('EUR'), 100);
    });

    test('сетевая ошибка: тихий отказ, курсы не изменились', () async {
      await f.seed();
      final RateSyncResult result = await RateSyncService(
        client: MockClient(
          (http.Request request) async => throw http.ClientException('нет'),
        ),
      ).syncNow(f.dao);

      expect(result, isA<RateSyncOffline>());
      expect(await f.rateOf('USD'), 90);
    });

    test('не-2xx: тихий отказ сети', () async {
      await f.seed();
      final RateSyncResult result = await RateSyncService(
        client: clientAnswering(
          () async => http.Response('rate limited', 403),
        ),
      ).syncNow(f.dao);

      expect(result, isA<RateSyncOffline>());
      expect(await f.rateOf('USD'), 90);
    });

    test('не-JSON и неожиданный формат: отказ, курсы не тронуты', () async {
      await f.seed();
      final RateSyncService service = RateSyncService(
        client: clientAnswering(() async => http.Response('<html>', 200)),
      );
      expect(await service.syncNow(f.dao), isA<RateSyncFailed>());
      expect(await f.rateOf('USD'), 90);

      final RateSyncService service2 = RateSyncService(
        client: clientAnswering(
          () async => ratesResponse(<String, Object?>{'USD': 0}),
        ),
      );
      expect(await service2.syncNow(f.dao), isA<RateSyncFailed>());
      expect(await f.rateOf('USD'), 90);
    });

    test('базовой валюты нет (до посева) — тихий отказ, сети нет', () async {
      int calls = 0;
      final RateSyncResult result = await RateSyncService(
        client: MockClient((http.Request request) async {
          calls++;
          return ratesResponse(<String, Object?>{});
        }),
      ).syncNow(f.dao);

      expect(result, isA<RateSyncOffline>());
      expect(calls, 0);
    });
  });

  group('syncForBase (синхронизация к заданной базовой)', () {
    late RatesFixture f;

    setUp(() => f = RatesFixture());
    tearDown(() => f.dispose());

    test('курсы записываются относительно переданной базовой', () async {
      await f.seed();
      final RateSyncResult result = await RateSyncService(
        client: clientAnswering(
          () async => ratesResponse(<String, Object?>{'USD': 80.5}),
        ),
      ).syncForBase(f.dao, 'RUB');

      expect(result, isA<RateSyncUpdated>());
      expect(await f.rateOf('USD'), 80.5);
    });
  });
}
