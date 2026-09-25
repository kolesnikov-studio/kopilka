// Тесты контроллера обновлений (§5): ручная проверка, автопроверка
// раз в 7 дней, хранилище предпочтений. Сеть фейковая (MockClient),
// версия подменена провайдером-загрузчиком, время — фиксированными часами.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kopilka/data/update/update_service.dart';
import 'package:kopilka/features/settings/update_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';

/// Фиксированный момент «сейчас».
final DateTime _now = DateTime.utc(2026, 9, 25, 12);

http.Client _clientReleasing(List<Map<String, dynamic>> releases) =>
    MockClient(
      (http.Request request) async => http.Response(
        jsonEncode(releases),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );

http.Client _clientEmpty() => MockClient(
      (http.Request request) async =>
          http.Response(jsonEncode(<dynamic>[]), 200),
    );

Map<String, dynamic> _release(String tag) => <String, dynamic>{
      'tag_name': tag,
      'name': 'Kopilka $tag',
      'body': 'notes',
      'html_url': 'https://github.com/kolesnikov-studio/kopilka/releases/tag/$tag',
      'published_at': '2026-09-24T12:00:00Z',
      'draft': false,
      'prerelease': false,
    };

ProviderContainer _container({
  required Directory baseDirectory,
  required http.Client client,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      updatePreferencesStoreProvider.overrideWithValue(
        UpdatePreferencesStore(baseDirectory: baseDirectory),
      ),
      updateServiceProvider.overrideWithValue(
        UpdateService(client: client),
      ),
      currentVersionLoaderProvider.overrideWithValue(
        () async => '0.1.0',
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Каталог настроек: реальный файловый I/O только вне testWidgets,
/// поэтому тесты — обычные (не testWidgets).
Future<Directory> tempDir() async {
  final Directory directory = await Directory.systemTemp.createTemp(
    'kopilka_update_test',
  );
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

void main() {
  group('checkNow (ручная проверка)', () {
    test('новый релиз → UpdateActionFound с данными диалога', () async {
      final Directory directory = await tempDir();
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: _clientReleasing(<Map<String, dynamic>>[_release('v0.2.0')]),
      );

      final UpdateActionOutcome outcome =
          await container.read(updateControllerProvider.notifier).checkNow();

      expect(outcome, isA<UpdateActionFound>());
      expect(
        (outcome as UpdateActionFound).update.version,
        'v0.2.0',
      );
    });

    test('актуальная версия → UpdateActionUpToDate', () async {
      final Directory directory = await tempDir();
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: _clientEmpty(),
      );

      expect(
        await container.read(updateControllerProvider.notifier).checkNow(),
        isA<UpdateActionUpToDate>(),
      );
    });

    test('ошибка сети → UpdateActionUnavailable', () async {
      final Directory directory = await tempDir();
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: MockClient(
          (http.Request request) async => throw http.ClientException('нет'),
        ),
      );

      expect(
        await container.read(updateControllerProvider.notifier).checkNow(),
        isA<UpdateActionUnavailable>(),
      );
    });
  });

  group('checkOnLaunch (автопроверка раз в 7 дней)', () {
    test('настройка выключена — сетевых вызовов нет', () async {
      final Directory directory = await tempDir();
      int calls = 0;
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response('[]', 200);
        }),
      );

      await container.read(updateControllerProvider.notifier).checkOnLaunch(
            clock: () => _now,
          );

      expect(calls, 0);
    });

    test('включена, проверки не было — проверяет и запоминает время', () async {
      final Directory directory = await tempDir();
      final UpdatePreferencesStore store = UpdatePreferencesStore(
        baseDirectory: directory,
      );
      await store.writeEnabled(true);
      int calls = 0;
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response(jsonEncode(<dynamic>[_release('v0.2.0')]), 200);
        }),
      );

      await container.read(updateControllerProvider.notifier).checkOnLaunch(
            clock: () => _now,
          );

      expect(calls, 1);
      // Флаг найденного обновления поднят: экран покажет диалог.
      expect(
        container.read(updateControllerProvider).foundUpdate?.version,
        'v0.2.0',
      );
      // Время проверки сохранено.
      expect(await store.readLastAutoCheck(), isNotNull);
    });

    test('включена, но проверялась недавно — не проверяет', () async {
      final Directory directory = await tempDir();
      final UpdatePreferencesStore store = UpdatePreferencesStore(
        baseDirectory: directory,
      );
      await store.writeEnabled(true);
      await store.writeLastAutoCheck(_now.subtract(const Duration(days: 2)));
      int calls = 0;
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response('[]', 200);
        }),
      );

      await container.read(updateControllerProvider.notifier).checkOnLaunch(
            clock: () => _now,
          );

      expect(calls, 0);
    });

    test('прошло 7 дней — проверяет снова', () async {
      final Directory directory = await tempDir();
      final UpdatePreferencesStore store = UpdatePreferencesStore(
        baseDirectory: directory,
      );
      await store.writeEnabled(true);
      await store.writeLastAutoCheck(_now.subtract(const Duration(days: 8)));
      int calls = 0;
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: MockClient((http.Request request) async {
          calls++;
          return http.Response('[]', 200);
        }),
      );

      await container.read(updateControllerProvider.notifier).checkOnLaunch(
            clock: () => _now,
          );

      expect(calls, 1);
      // Обновления нет: foundUpdate не поднят.
      expect(
        container.read(updateControllerProvider).foundUpdate,
        isNull,
      );
    });

    test('сетевая ошибка автопроверки не роняет запуск', () async {
      final Directory directory = await tempDir();
      final UpdatePreferencesStore store = UpdatePreferencesStore(
        baseDirectory: directory,
      );
      await store.writeEnabled(true);
      final ProviderContainer container = _container(
        baseDirectory: directory,
        client: MockClient(
          (http.Request request) async => throw http.ClientException('нет'),
        ),
      );

      // Не бросает.
      await container.read(updateControllerProvider.notifier).checkOnLaunch(
            clock: () => _now,
          );
      expect(
        container.read(updateControllerProvider).foundUpdate,
        isNull,
      );
    });
  });

  group('UpdatePreferencesStore', () {
    test('по умолчанию: выключена, времени нет, предложение не показано',
        () async {
      final Directory directory = await tempDir();
      final UpdatePreferencesStore store = UpdatePreferencesStore(
        baseDirectory: directory,
      );

      expect(await store.readEnabled(), isFalse);
      expect(await store.readLastAutoCheck(), isNull);
      expect(await store.readOfferShown(), isFalse);
    });

    test('цикл записи-чтения: включение, штамп, предложение', () async {
      final Directory directory = await tempDir();
      final UpdatePreferencesStore store = UpdatePreferencesStore(
        baseDirectory: directory,
      );

      await store.writeEnabled(true);
      await store.writeLastAutoCheck(_now);
      await store.writeOfferShown();

      expect(await store.readEnabled(), isTrue);
      expect((await store.readLastAutoCheck())!.toUtc(), _now);
      expect(await store.readOfferShown(), isTrue);
    });

    test('isAutoCheckDue: порог ровно 7 дней', () {
      expect(
        isAutoCheckDue(
          enabled: true,
          lastCheck: _now.subtract(const Duration(days: 7)),
          now: _now,
        ),
        isTrue,
      );
      expect(
        isAutoCheckDue(
          enabled: true,
          lastCheck: _now.subtract(const Duration(days: 6)),
          now: _now,
        ),
        isFalse,
      );
      expect(
        isAutoCheckDue(
          enabled: false,
          lastCheck: null,
          now: _now,
        ),
        isFalse,
      );
    });
  });
}
