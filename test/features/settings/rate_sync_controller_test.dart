// Тесты контроллера синхронизации курсов (M4-шаг 1): исходы syncNow,
// opt-in галочка (D-36), шов applyRates. Сеть фейковая (MockClient),
// БД — in-memory, подменённая в провайдерах.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/rates/rate_sync_service.dart';
import 'package:kopilka/features/settings/rate_sync_controller.dart';

http.Response _ratesResponse(Map<String, Object?> rates) => http.Response(
      jsonEncode(<String, dynamic>{'result': 'success', 'rates': rates}),
      200,
    );

ProviderContainer _container({
  required AppDatabase db,
  required http.Client client,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      rateSyncServiceProvider.overrideWithValue(
        RateSyncService(client: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  late AppDatabase db;
  late CurrenciesDao dao;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    dao = db.currenciesDao;
    await dao.create(code: 'RUB', symbol: '₽', isBase: true);
    await dao.create(code: 'USD', symbol: r'$', rateToBase: 90);
    await dao.create(code: 'EUR', symbol: '€', rateToBase: 100);
  });

  test('галочка выключена (по умолчанию) — syncNow без сетевых вызовов',
      () async {
    int calls = 0;
    final ProviderContainer container = _container(
      db: db,
      client: MockClient((http.Request request) async {
        calls++;
        return _ratesResponse(<String, Object?>{});
      }),
    );

    final RateSyncResult result =
        await container.read(rateSyncControllerProvider.notifier).syncNow();

    expect(result, isA<RateSyncDisabled>());
    expect(calls, 0);
    expect((await dao.findAlive('USD'))!.rateToBase, 90);
  });

  test('включённая синхронизация: успех — курсы записаны, флаг сброшен',
      () async {
    final ProviderContainer container = _container(
      db: db,
      client: MockClient(
        (http.Request request) async =>
            // Единицы источника — «CODE за единицу базы» (D-42): сервис
            // разворачивает их в «база за единицу CODE».
            _ratesResponse(<String, Object?>{'USD': 0.0125, 'EUR': 0.01}),
      ),
    );
    await container.read(rateSyncEnabledProvider.notifier).setEnabled(true);

    final RateSyncResult result =
        await container.read(rateSyncControllerProvider.notifier).syncNow();

    expect(result, isA<RateSyncUpdated>());
    expect((result as RateSyncUpdated).updatedCount, 2);
    expect((await dao.findAlive('USD'))!.rateToBase, closeTo(80, 1e-9));
    expect((await dao.findAlive('EUR'))!.rateToBase, closeTo(100, 1e-9));
    expect(
      container.read(rateSyncControllerProvider).syncing,
      isFalse,
      reason: 'после завершения запроса флаг сброшен',
    );
  });

  test('включённая синхронизация: сеть недоступна — тихий отказ, курсы целы',
      () async {
    final ProviderContainer container = _container(
      db: db,
      client: MockClient(
        (http.Request request) async => throw http.ClientException('нет'),
      ),
    );
    await container.read(rateSyncEnabledProvider.notifier).setEnabled(true);

    final RateSyncResult result =
        await container.read(rateSyncControllerProvider.notifier).syncNow();

    expect(result, isA<RateSyncOffline>());
    expect((await dao.findAlive('USD'))!.rateToBase, 90);
  });

  test('applyRates — шов без сети: словарь применяется через DAO', () async {
    final ProviderContainer container = _container(
      db: db,
      client: MockClient((http.Request request) async {
        fail('applyRates не должен ходить в сеть');
      }),
    );

    final RateSyncResult result =
        await container.read(rateSyncControllerProvider.notifier).applyRates(
              <String, double>{'USD': 77.5},
            );

    expect(result, isA<RateSyncUpdated>());
    expect((result as RateSyncUpdated).updatedCount, 1);
    expect((await dao.findAlive('USD'))!.rateToBase, 77.5);
    expect((await dao.findAlive('EUR'))!.rateToBase, 100);
  });
}
