// Виджет-тесты секции синхронизации курсов в настройках (M4-шаг 2, D-36):
// отключённое состояние и все исходы кнопки «Обновить сейчас».
//
// Грабли: секция стоит сразу после пункта «Валюты» — в тестовой поверхности
// 800×600 видна без прокрутки. Реальный файловый I/O в testWidgets не
// завершается (fake_async): включение галочки в сетевых тестах выполняется
// контроллером внутри tester.runAsync (персист файла покрыт обычными
// тестами rate_sync_controller_test.dart), создание временного каталога —
// тоже через runAsync. Сеть фейковая (MockClient), БД — in-memory с посевом.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/rates/rate_sync_service.dart';
import 'package:kopilka/features/settings/rate_sync_controller.dart';
import 'package:kopilka/features/settings/rate_sync_preferences.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/settings_screen.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

const ValueKey<String> _tileKey = ValueKey<String>('rateSyncEnabledTile');
const ValueKey<String> _buttonKey = ValueKey<String>('rateSyncNowButton');

/// Источник отвечает «USD: 0.0125 за единицу базы» (D-42: сервис развернёт
/// в 80); [answer] — общая заготовка ответа.
http.Client _client(Future<http.Response> Function() answer) => MockClient(
      (http.Request request) async => answer(),
    );

Future<Directory> _tempDir(WidgetTester tester) async {
  final Directory directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_ratesync_widget'),
  ))!;
  addTearDown(
    () => tester.runAsync(() => directory.delete(recursive: true)),
  );
  return directory;
}

Future<(ProviderContainer, AppDatabase)> _pump(
  WidgetTester tester, {
  required http.Client client,
}) async {
  tester.platformDispatcher.localeTestValue = const Locale('ru');
  tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final Directory tempDir = await _tempDir(tester);
  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);
  await db.currenciesDao.create(code: 'USD', symbol: r'$', rateToBase: 90);

  // Экран в initState грузит все три хранилища настроек — каждое нужно
  // подменить (иначе провайдер бросает UnimplementedError в тесте).
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider.overrideWithValue(
        AutoBackupDirectoryStore(baseDirectory: tempDir),
      ),
      updatePreferencesStoreProvider.overrideWithValue(
        UpdatePreferencesStore(baseDirectory: tempDir),
      ),
      rateSyncPreferencesStoreProvider.overrideWithValue(
        RateSyncPreferencesStore(baseDirectory: tempDir),
      ),
      rateSyncServiceProvider.overrideWithValue(
        RateSyncService(client: client),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container, db);
}

/// Включает галочку тапом по плитке (как пользователь) и ждёт кадр.
///
/// Важно: setEnabled внутри пишет файл настроек — этот real-IO future в
/// fake_async не завершается, поэтому ждать его await'ом в тесте нельзя;
/// тап ставит состояние синхронно, а запись не нужна сценарию (персист
/// файла покрыт обычными тестами rate_sync_controller_test.dart).
Future<void> _enableByTap(WidgetTester tester) async {
  await tester.tap(find.byKey(_tileKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('галочка выключена — кнопка неактивна (D-36, opt-in)',
      (WidgetTester tester) async {
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    await _pump(
      tester,
      client: _client(() async => fail('сеть не ожидается')),
    );

    expect(find.text(l10n.rateSyncSectionTitle), findsOneWidget);
    expect(find.text(l10n.rateSyncEnabled), findsOneWidget);
    expect(find.text(l10n.rateSyncEnabledHint), findsOneWidget);
    expect(find.text(l10n.rateSyncNow), findsOneWidget);
    expect(
      tester.widget<Switch>(find.byType(Switch).first).value,
      isFalse,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(_buttonKey)).onPressed,
      isNull,
      reason: 'при выключенной галочке кнопка неактивна',
    );
  });

  testWidgets('включение галочки активирует кнопку',
      (WidgetTester tester) async {
    final (ProviderContainer container, _) =
        await _pump(tester, client: _client(() async => fail('сеть не ожидается')));

    // Тап по плитке меняет состояние (UI), запись файла не влияет на UI.
    await tester.tap(find.byKey(_tileKey));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Switch>(find.byType(Switch).first).value,
      isTrue,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(_buttonKey)).onPressed,
      isNotNull,
    );
    expect(container.read(rateSyncEnabledProvider), isTrue);
  });

  testWidgets('успех: снек «Обновлено 1 валюта», курс перезаписан',
      (WidgetTester tester) async {
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final (ProviderContainer container, AppDatabase db) = await _pump(
      tester,
      client: _client(() async => http.Response(
            jsonEncode(<String, dynamic>{
              'result': 'success',
              'rates': <String, dynamic>{'USD': 0.0125},
            }),
            200,
          )),
    );

    await _enableByTap(tester);
    await tester.tap(find.byKey(_buttonKey));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(l10n.rateSyncUpdated(1)), findsOneWidget);
    final Currency? usd = await db.currenciesDao.findAlive('USD');
    expect(usd!.rateToBase, closeTo(80, 1e-9));
    expect(container.read(rateSyncControllerProvider).syncing, isFalse);
  });

  testWidgets('сеть недоступна: снек «сеть недоступна», курс цел',
      (WidgetTester tester) async {
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final (ProviderContainer container, AppDatabase db) = await _pump(
      tester,
      client: _client(() async => throw http.ClientException('нет')),
    );

    await _enableByTap(tester);
    await tester.tap(find.byKey(_buttonKey));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(l10n.rateSyncOffline), findsOneWidget);
    final Currency? usd = await db.currenciesDao.findAlive('USD');
    expect(usd!.rateToBase, 90);
    expect(container.read(rateSyncControllerProvider).syncing, isFalse);
  });

  testWidgets('сбой источника: снек «источник не отвечает», курс цел',
      (WidgetTester tester) async {
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final (ProviderContainer container, AppDatabase db) = await _pump(
      tester,
      client: _client(() async => http.Response(
            jsonEncode(<String, dynamic>{'result': 'error'}),
            200,
          )),
    );

    await _enableByTap(tester);
    await tester.tap(find.byKey(_buttonKey));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text(l10n.rateSyncFailed), findsOneWidget);
    final Currency? usd = await db.currenciesDao.findAlive('USD');
    expect(usd!.rateToBase, 90);
  });

  testWidgets('второй вызов во время запроса — снек «уже выполняется» (D-42.в)',
      (WidgetTester tester) async {
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    // Первый запрос «висит» (ответ не приходит): снек второго вызова
    // остаётся видимым и не вытесняется успехом первого.
    final (ProviderContainer container, _) = await _pump(
      tester,
      client: _client(() => Completer<http.Response>().future),
    );

    await _enableByTap(tester);
    // Кнопка неактивна во время запроса — двойной тап невозможен, но гонка
    // (повторный вызов до простановки неактивности) не должна показывать
    // снек «фича выключена». Часы в testWidgets фейковые: pumpAndSettle
    // прокрутил бы время мимо таймаута сервиса (10 с, Offline), поэтому
    // снек второго вызова проверяем до settle.
    await tester.tap(find.byKey(_buttonKey));
    await tester.tap(find.byKey(_buttonKey));
    await tester.pump();
    await tester.pump();

    expect(find.text(l10n.rateSyncAlreadyRunning), findsOneWidget);
    expect(find.text(l10n.rateSyncDisabled), findsNothing);
    expect(container.read(rateSyncControllerProvider).syncing, isTrue);

    // Зачистка: фейковое время доводит первый запрос до таймаута, снеки гасят
    // анимации — незавершённых таймеров в конце теста не остаётся.
    await tester.pumpAndSettle();
  });
}
