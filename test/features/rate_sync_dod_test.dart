// DoD-сценарий M4 «синхронизация курсов с интернетом» (ROADMAP M4,
// релиз v0.3.1, D-36). Образец стиля — two_currencies_dod_test.dart
// (полный KopilkaApp, RU-локаль, ожидания через l10n-ключи); сеть —
// фейковый http.Client вместо реальной, как в rate_sync_controller_test.dart.
//
// Проверяются оба DoD-пункта брифа:
// 1. галочка синхронизации включена → тихий автозапуск при старте обновил
//    курсы без действий пользователя; курс виден в UI (экран «Валюты») и
//    в пересчёте отчёта в базовой валюте (D-18: живой поток currencies);
// 2. сеть недоступна (клиент бросает) → приложение работает, курсы
//    вводятся вручную через экран «Валюты» (офлайн-fallback D-36),
//    персист «молча выкл» не падает (D-43.г, T-2).
//
// Продуктовый код не менялся. Единицы фейкового источника — «CODE за
// единицу базы», разворот в rate_to_base делает сервис на сетевой
// границе (D-42): источник отвечает 0.01 → в справочнике 100.
//
// Грабли fake_async (§7): «старт приложения» и файловый I/O — только через
// tester.runAsync (приём rate_sync_ui_test.dart, Dz-3/D-44.б): тихий
// автозапуск эмулируется вызовом syncOnLaunch как в main — fire-and-forget,
// без UI; включённость — по файлу настроек приложения, а не по стейту
// галочки. Прямые await по in-memory drift в теле теста допустимы
// (прецедент two_currencies_dod_test.dart), файловый I/O — нет.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/rates/rate_sync_service.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';
import 'package:kopilka/features/settings/rate_sync_controller.dart';
import 'package:kopilka/features/settings/rate_sync_preferences.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Ответ фейкового источника в его единицах (D-42): «USD 0.01 за единицу
/// базовой» — сервис запишет rate_to_base = 1 / 0.01 = 100.
http.Response _ratesResponse() => http.Response(
  jsonEncode(<String, dynamic>{
    'result': 'success',
    'rates': <String, dynamic>{'USD': 0.01},
  }),
  200,
);

/// Полный KopilkaApp в RU-локали (харнесс S2) с подменёнными хранилищами
/// настроек и фейковой сетью — как pumpDialogApp, но с швами rate-sync
/// (состав подмен — как в rate_sync_ui_test.dart: экран настроек в
/// initState грузит все три хранилища). Возвращает контейнер, БД и каталог
/// настроек приложения.
Future<(ProviderContainer, AppDatabase, Directory)> _pumpApp(
  WidgetTester tester, {
  required http.Client client,
}) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  tester.platformDispatcher.localeTestValue = const Locale('ru');
  tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final Directory appDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('kopilka_dod_rate_sync'),
  ))!;
  addTearDown(() => tester.runAsync(() => appDir.delete(recursive: true)));

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);
  await db.currenciesDao.create(code: 'USD', symbol: r'$', rateToBase: 90);

  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider.overrideWithValue(
        AutoBackupDirectoryStore(baseDirectory: appDir),
      ),
      updatePreferencesStoreProvider.overrideWithValue(
        UpdatePreferencesStore(baseDirectory: appDir),
      ),
      rateSyncPreferencesStoreProvider.overrideWithValue(
        RateSyncPreferencesStore(baseDirectory: appDir),
      ),
      // Напоминания (M6/D-89): RemindersBinding при старте читает opt-in
      // состояние — хранилище подменяется как остальные (D-43).
      remindersPreferencesStoreProvider.overrideWithValue(
        RemindersPreferencesStore(baseDirectory: appDir),
      ),
      rateSyncServiceProvider.overrideWithValue(
        RateSyncService(client: client),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const KopilkaApp()),
  );
  await tester.pumpAndSettle();
  return (container, db, appDir);
}

/// Включённая галочка «до запуска»: файл настроек приложения — истина
/// (D-44.б: syncOnLaunch читает файл, не стейт галочки).
Future<void> _enableByFile(WidgetTester tester, ProviderContainer container) =>
    tester.runAsync(
      () => container.read(rateSyncPreferencesStoreProvider).writeEnabled(true),
    );

/// Тихий автозапуск при старте (шаг 3, D-36): вызов syncOnLaunch как в
/// main — fire-and-forget, без UI и без действий пользователя. Реальный
/// I/O (файл настроек, база) доводится до сетевого запроса внутри
/// runAsync; ответ фейкового клиента приходит там же.
Future<void> _runLaunchSync(WidgetTester tester, ProviderContainer container) =>
    tester.runAsync(() async {
      container.read(rateSyncControllerProvider.notifier).syncOnLaunch();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

Future<void> _openCurrencies(WidgetTester tester) async {
  await tester.tap(find.text('Настройки').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Валюты').last);
  await tester.pumpAndSettle();
}

/// Подзаголовок строки валюты на экране «Валюты»: «1 = 100 RUB»
/// (форматтер EN-точки, D-26).
Finder _rateRow(String rate) => find.text('1 = $rate RUB');

void main() {
  testWidgets(
    'DoD: галочка включена — тихий автозапуск при старте обновил курсы; '
    'курс виден в UI и в пересчёте отчёта',
    (WidgetTester tester) async {
      final AppLocalizations l10n = await AppLocalizations.delegate.load(
        const Locale('ru'),
      );
      int calls = 0;
      final (ProviderContainer container, AppDatabase db, _) = await _pumpApp(
        tester,
        client: MockClient((http.Request request) async {
          calls++;
          expect(
            request.url.path,
            '/v6/latest/RUB',
            reason: 'один запрос за базовой из справочника',
          );
          return _ratesResponse();
        }),
      );

      // Пользователь включил синхронизацию раньше; при старте приложения
      // (без действий пользователя) тихий автозапуск сделал ровно один
      // сетевой вызов и перезаписал курс USD (0.01 → 100, D-42).
      await _enableByFile(tester, container);
      await _runLaunchSync(tester, container);
      await tester.pumpAndSettle();
      expect(calls, 1, reason: 'тихий автозапуск сделал один вызов');
      expect(
        (await db.currenciesDao.findAlive('USD'))!.rateToBase,
        closeTo(100, 1e-9),
      );
      expect(container.read(rateSyncControllerProvider).syncing, isFalse);

      // Курс виден в UI: экран «Валюты» показывает новый курс USD.
      await _openCurrencies(tester);
      expect(_rateRow('100'), findsOneWidget);

      // Курс виден в пересчёте: расходы 1 000,00 ₽ и 10,00 $ по категории
      // «Еда» со счетов в обеих валютах — отчёт «по текущему курсу»
      // пересчитывает USD по новому курсу: 1 000,00 ₽ + 10,00 $ × 100 =
      // 2 000,00 ₽ (D-18: живой поток currencies). Счета двух валют нужны
      // и для пометки B5 (мультивалютность — по живым счетам).
      final Account rub = await db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Account usd = await db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: rub.id,
        categoryId: food.id,
        amountMinor: 100000, // 1 000,00 ₽
      );
      await db.transactionsDao.create(
        type: TransactionType.expense,
        accountId: usd.id,
        categoryId: food.id,
        amountMinor: 1000, // 10,00 $
      );

      // Подмаршрут «Валюты» живёт внутри ветки настроек: панель навигации
      // оболочки видна — на «Отчёты» уходим напрямую.
      await tester.tap(find.text('Отчёты').last);
      await tester.pumpAndSettle();

      // «Всего» доната: 1 000,00 ₽ + 10,00 $ × 100 = 2 000,00 ₽;
      // пометка «по текущему курсу» на карточках отчёта есть (B5).
      expect(
        find.text(
          '${l10n.reportsTotalLabel}: '
          '${formatMoneyMinor(200000, symbol: '₽', locale: 'ru')}',
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.reportsAtCurrentRate), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'DoD: сеть недоступна — приложение работает, курс вводится вручную, '
    '«молча выкл» персиста не падает',
    (WidgetTester tester) async {
      // Галочка включена, но сеть недоступна (клиент бросает): путь
      // включённого автозапуска по недоступной сети (офлайн-fallback D-36).
      int calls = 0;
      final (
        ProviderContainer container,
        AppDatabase db,
        Directory appDir,
      ) = await _pumpApp(
        tester,
        client: MockClient((http.Request request) async {
          calls++;
          throw http.ClientException('нет сети');
        }),
      );

      // Автозапуск по включённой галочке сделал вызов и тихо отказался:
      // приложение работает, запуск не упал, курсы не тронуты (D-36).
      await _enableByFile(tester, container);
      await _runLaunchSync(tester, container);
      await tester.pumpAndSettle();
      expect(calls, 1, reason: 'включённый автозапуск пробил сеть ровно раз');
      expect((await db.currenciesDao.findAlive('USD'))!.rateToBase, 90);
      expect(container.read(rateSyncControllerProvider).syncing, isFalse);

      // Приложение живо: на «Валютах» курс — прежний ручной.
      await _openCurrencies(tester);
      expect(_rateRow('90'), findsOneWidget);

      // Офлайн-fallback D-36: курс USD вводится вручную — тап по строке,
      // правка «97,5» (запятая равнозначна точке, B1.1), сохранение;
      // экран показывает «1 = 97.5 RUB».
      await tester.tap(find.text('USD — Доллар США').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '97,5');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить').last);
      await tester.pumpAndSettle();
      expect(_rateRow('97.5'), findsOneWidget);
      expect(
        (await db.currenciesDao.findAlive('USD'))!.rateToBase,
        closeTo(97.5, 1e-9),
      );

      // «Молча выкл» персиста (D-43.г, T-2): битый JSON настроек читается
      // как «выкл» без исключений; запись поверх чинит файл в валидный JSON.
      await tester.runAsync(
        () =>
            File('${appDir.path}/rate-sync-preferences.json')
                .writeAsString('{oops'),
      );
      await tester.runAsync(
        () async => expect(
          await container.read(rateSyncPreferencesStoreProvider).readEnabled(),
          isFalse,
        ),
      );
      await tester.runAsync(
        () =>
            container.read(rateSyncEnabledProvider.notifier).setEnabled(false),
      );
      await tester.runAsync(
        () async => expect(
          File('${appDir.path}/rate-sync-preferences.json').readAsStringSync(),
          '{"enabled":false}',
        ),
      );
    },
  );
}
