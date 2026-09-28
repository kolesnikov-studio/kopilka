// Тесты контроллера синхронизации курсов (M4-шаг 1): исходы syncNow,
// opt-in галочка (D-36), шов applyRates; с шага 3 — автосинхронизация
// при запуске (syncOnLaunch). Сеть фейковая (MockClient), БД — in-memory,
// подменённая в провайдерах. С шага 2 (UI) галочка персистится в файл
// настроек — тесты персиста ниже (реальный файловый I/O только в
// обычных тестах, не testWidgets).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:kopilka/features/settings/rate_sync_preferences.dart';

http.Response _ratesResponse(Map<String, Object?> rates) => http.Response(
      jsonEncode(<String, dynamic>{'result': 'success', 'rates': rates}),
      200,
    );

ProviderContainer _container({
  required AppDatabase db,
  required http.Client client,
  RateSyncPreferencesStore? preferencesStore,
}) {
  // С шага 2 setEnabled пишет в файл настроек: без явного хранилища —
  // временный каталог, чтобы тесты шага 1 не трогали реальные файлы.
  RateSyncPreferencesStore? store = preferencesStore;
  Directory? tempDirectory;
  if (store == null) {
    tempDirectory = Directory.systemTemp
        .createTempSync('kopilka_ratesync_default');
    addTearDown(() => tempDirectory!.delete(recursive: true));
    store = RateSyncPreferencesStore(baseDirectory: tempDirectory);
  }
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      rateSyncServiceProvider.overrideWithValue(
        RateSyncService(client: client),
      ),
      rateSyncPreferencesStoreProvider.overrideWithValue(store),
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

  test('повторный вызов во время запроса — AlreadyRunning, не «выключено» (D-42.в)', () async {
    final Completer<http.Response> gate = Completer<http.Response>();
    final ProviderContainer container = _container(
      db: db,
      client: MockClient(
        (http.Request request) async => gate.future,
      ),
    );
    await container.read(rateSyncEnabledProvider.notifier).setEnabled(true);
    final RateSyncController notifier =
        container.read(rateSyncControllerProvider.notifier);

    // Состояние syncing ставится синхронно до первого await: сразу после
    // вызова запрос «идёт», второй вызов обязан попасть в ту же ветку.
    final Future<RateSyncResult> first = notifier.syncNow();
    expect(container.read(rateSyncControllerProvider).syncing, isTrue,
        reason: 'первый запрос ещё идёт');

    final RateSyncResult second = await notifier.syncNow();
    expect(second, isA<RateSyncAlreadyRunning>());

    gate.complete(_ratesResponse(<String, Object?>{'USD': 0.0125}));
    final RateSyncResult result = await first;
    expect(result, isA<RateSyncUpdated>());
    expect(container.read(rateSyncControllerProvider).syncing, isFalse);
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

  group('персист галочки (M4-шаг 2, D-36)', () {
    test('по умолчанию выключена и в файле ничего нет', () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);
      final ProviderContainer container = _container(
        db: db,
        client: MockClient(
          (http.Request request) async => fail('сеть не нужна'),
        ),
        preferencesStore: store,
      );

      await container.read(rateSyncEnabledProvider.notifier).load();

      expect(container.read(rateSyncEnabledProvider), isFalse);
      expect(await store.readEnabled(), isFalse);
      expect(
        File('${directory.path}/rate-sync-preferences.json').existsSync(),
        isFalse,
      );
    });

    test('setEnabled пишет в файл; новый контейнер load читает', () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);
      final ProviderContainer first = _container(
        db: db,
        client: MockClient(
          (http.Request request) async => fail('сеть не нужна'),
        ),
        preferencesStore: store,
      );

      await first.read(rateSyncEnabledProvider.notifier).setEnabled(true);
      expect(await store.readEnabled(), isTrue);

      // «Перезапуск»: свежий контейнер с тем же каталогом настроек.
      final ProviderContainer second = _container(
        db: db,
        client: MockClient(
          (http.Request request) async => fail('сеть не нужна'),
        ),
        preferencesStore: store,
      );
      expect(second.read(rateSyncEnabledProvider), isFalse);
      await second.read(rateSyncEnabledProvider.notifier).load();
      expect(second.read(rateSyncEnabledProvider), isTrue);

      await second.read(rateSyncEnabledProvider.notifier).setEnabled(false);
      expect(await store.readEnabled(), isFalse);
      await second.read(rateSyncEnabledProvider.notifier).load();
      expect(second.read(rateSyncEnabledProvider), isFalse);
    });

    test('битый JSON — readEnabled() = false, исключение не наружу (T-2, D-43.г)',
        () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final File file =
          File('${directory.path}/rate-sync-preferences.json');
      // Полусформированный/повреждённый файл настроек: например, запись
      // оборвалась. D-43.г: настройка не критична для запуска — «молча выкл».
      await file.writeAsString('{oops');
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);

      // До правки (on IOException) FormatException отсюда вылетал наружу.
      expect(await store.readEnabled(), isFalse);
    });
  });

  group('автосинхронизация при запуске (M4-шаг 3, D-36)', () {
    test('выключена — syncOnLaunch без сетевых вызовов, стейт галочки не тронут',
        () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);
      int calls = 0;
      final ProviderContainer container = _container(
        db: db,
        client: MockClient((http.Request request) async {
          calls++;
          return _ratesResponse(<String, Object?>{'USD': 0.0125});
        }),
        preferencesStore: store,
      );

      // Свежий запуск: load() из main мог ещё не выполниться — стейт
      // провайдера по умолчанию false; включённость читается из файла.
      final RateSyncResult result = await container
          .read(rateSyncControllerProvider.notifier)
          .syncOnLaunch();

      expect(result, isA<RateSyncDisabled>());
      expect(calls, 0);
      expect(container.read(rateSyncEnabledProvider), isFalse);
      expect((await dao.findAlive('USD'))!.rateToBase, 90);
    });

    test('включена — ровно один сетевой вызов за базовой, курсы записаны',
        () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);
      await store.writeEnabled(true);
      final List<String> paths = <String>[];
      final ProviderContainer container = _container(
        db: db,
        client: MockClient((http.Request request) async {
          paths.add(request.url.path);
          // Единицы источника — «CODE за единицу базы» (D-42).
          return _ratesResponse(<String, Object?>{'USD': 0.0125, 'EUR': 0.01});
        }),
        preferencesStore: store,
      );

      final RateSyncResult result = await container
          .read(rateSyncControllerProvider.notifier)
          .syncOnLaunch();

      expect(result, isA<RateSyncUpdated>());
      expect((result as RateSyncUpdated).updatedCount, 2);
      expect(paths, <String>['/v6/latest/RUB'],
          reason: 'один запрос с базовой из справочника');
      expect((await dao.findAlive('USD'))!.rateToBase, closeTo(80, 1e-9));
      expect((await dao.findAlive('EUR'))!.rateToBase, closeTo(100, 1e-9));
      expect(container.read(rateSyncControllerProvider).syncing, isFalse);
    });

    test('включена, сеть недоступна — тихий отказ, курсы целы', () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);
      await store.writeEnabled(true);
      int calls = 0;
      final ProviderContainer container = _container(
        db: db,
        client: MockClient((http.Request request) async {
          calls++;
          throw http.ClientException('нет');
        }),
        preferencesStore: store,
      );

      final RateSyncResult result = await container
          .read(rateSyncControllerProvider.notifier)
          .syncOnLaunch();

      // Запуск не падает: исход машиночитаемый, курсы не тронуты (D-36).
      expect(result, isA<RateSyncOffline>());
      expect(calls, 1);
      expect((await dao.findAlive('USD'))!.rateToBase, 90);
    });

    test('идёт ручная синхронизация — запуск возвращает AlreadyRunning, второй запрос не стартует',
        () async {
      final Directory directory = await Directory.systemTemp
          .createTemp('kopilka_ratesync_test');
      addTearDown(() => directory.delete(recursive: true));
      final RateSyncPreferencesStore store =
          RateSyncPreferencesStore(baseDirectory: directory);
      await store.writeEnabled(true);
      int calls = 0;
      final Completer<http.Response> gate = Completer<http.Response>();
      final ProviderContainer container = _container(
        db: db,
        client: MockClient((http.Request request) async {
          calls++;
          return gate.future;
        }),
        preferencesStore: store,
      );
      // Ручная синхронизация смотрит на стейт галочки, а не в файл: грузим.
      await container.read(rateSyncEnabledProvider.notifier).setEnabled(true);
      final RateSyncController notifier =
          container.read(rateSyncControllerProvider.notifier);

      final Future<RateSyncResult> manual = notifier.syncNow();
      expect(container.read(rateSyncControllerProvider).syncing, isTrue);

      final RateSyncResult launch = await notifier.syncOnLaunch();
      expect(launch, isA<RateSyncAlreadyRunning>());

      gate.complete(_ratesResponse(<String, Object?>{'USD': 0.0125}));
      expect(await manual, isA<RateSyncUpdated>());
      // Запуск во время ручной синхронизации не дошёл до сети: после
      // завершения единственного (ручного) прогона счётчик — 1.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1, reason: 'второй сетевой запрос не стартовал');
      expect(container.read(rateSyncControllerProvider).syncing, isFalse);
    });
  });
}
