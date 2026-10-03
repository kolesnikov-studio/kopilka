// Замок сборки уведомления «исполнен отложенный перевод» (M7-шаг D,
// P2-1 аудита, D-133): binding собирает `scheduledTransferExecutedBody`
// (D-130 §2) — сумма списания в валюте счёта списания (не в базовой) и
// имя счёта зачисления; заголовок — единый `reminderTitle`; payload —
// `scheduled:<id>` (D-119).
//
// Канал уведомлений — спай-плагин (образец reminders_service_test.dart),
// исполнение — настоящий ScheduledTransfersService над in-memory БД,
// onExecuted — настоящий обработчик биндинга (проверяется весь путь).
// Простой `test` (не testWidgets): потоки drift читаются real async (§7);
// локаль — тест-машины (deviceLocalizations), строки-эталоны — из неё же.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/money_format.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/export/backup_service.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';
import 'package:kopilka/data/reminders/reminders_texts.dart'
    show deviceLocalizations;
import 'package:kopilka/data/scheduled/scheduled_transfers_binding.dart';
import 'package:kopilka/data/scheduled/scheduled_transfers_service.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

class _SpyPrefs implements RemindersPreferencesFake {
  bool enabled = true;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;

  @override
  Future<Map<String, String>> readAlertLastShown() async => <String, String>{};

  @override
  Future<void> writeAlertLastShown(Map<String, String> lastShown) async {}
}

class _SpyPlugin implements RemindersPlugin {
  final List<({String title, String body, String payload})> shown =
      <({String title, String body, String payload})>[];

  @override
  Future<RemindersChannelError?> initialize() async => null;

  @override
  Future<RemindersChannelError?> replaceAll(
    List<ReminderScheduleEntry> entries,
  ) async => null;

  @override
  Future<RemindersChannelError?> show(
    int notificationId, {
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add((title: title, body: body, payload: payload));
    return null;
  }
}

/// Сервис исполнения со счётчиком проходов: замки триггеров D-119
/// (D-138, §6 п.1) проверяют не только результат, но и факт запуска
/// прохода на событии markExecuted (scheduled_transfers_binding.dart:88–95).
class _CountingService extends ScheduledTransfersService {
  _CountingService({
    required super.db,
    required super.scheduledDao,
    required super.transactionsDao,
    required super.onExecuted,
  });

  /// Сколько проходов executeDue запустил биндинг.
  int calls = 0;

  @override
  Future<void> executeDue() {
    calls += 1;
    return super.executeDue();
  }
}

/// Ждёт наступления условия (real async: события drift приходят
/// асинхронно); таймаут — явный отказ теста, а не молчаливый пропуск.
Future<void> waitUntil(
  Future<bool> Function() condition, {
  String reason = 'условие не наступило',
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > const Duration(seconds: 10)) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Локаль теста — тест-машины (deviceLocalizations биндинга читает
  // реальный PlatformDispatcher, который в plain test не подменяется);
  // строки-эталоны строятся из той же deviceLocalizations — контракт
  // замка (валюта счёта списания, имя счёта, payload) от локали не
  // зависит, а сами l10n-тексты закрыты reminders_texts_test.
  final AppLocalizations l = deviceLocalizations();

  Future<(AppDatabase, ProviderContainer, _SpyPlugin)> build() async {
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDefaultsIfEmpty(db);
    final _SpyPlugin plugin = _SpyPlugin();
    final RemindersService service = RemindersService(
      prefs: _SpyPrefs(),
      plugin: plugin,
      title: () => l.reminderTitle,
      overBudgetBody: ({
        required String categoryName,
        required int remainingMinor,
        required int daysLeft,
      }) => 'K',
    );
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        remindersServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    return (db, container, plugin);
  }

  test('D-133: тело — сумма в валюте счёта списания + имя счёта зачисления, payload scheduled:<id>', () async {
    final (AppDatabase db, ProviderContainer container, _SpyPlugin plugin) =
        await build();
    final Account from = await db.accountsDao.create(
      name: 'Рубли',
      kind: AccountKind.card,
      currencyCode: 'RUB',
    );
    final Account to = await db.accountsDao.create(
      name: 'Копилка',
      kind: AccountKind.bank,
      currencyCode: 'RUB',
    );
    final ScheduledTransfer transfer = await db.scheduledTransfersDao.create(
      accountId: from.id,
      targetAccountId: to.id,
      amountMinor: 123456,
      executeAt: DateTime.utc(2026, 1, 1),
    );

    // Исполнение — настоящий сервис биндинга (onExecuted — код
    // scheduledTransfersServiceProvider, D-130 §2).
    await container.read(scheduledTransfersServiceProvider).executeDue();

    expect(plugin.shown, hasLength(1));
    expect(
      plugin.shown.single.payload,
      '$scheduledTransferSource${transfer.id}',
    );
    expect(plugin.shown.single.title, l.reminderTitle);
    expect(
      plugin.shown.single.body,
      l.scheduledTransferExecutedBody(
        formatMoneyMinor(
          123456,
          symbol: '₽',
          locale: l.localeName,
          exponent: 2,
        ),
        'Копилка',
      ),
    );
  });

  test(
    'D-133: мультивалютный перевод — сумма списания в валюте счёта списания',
    () async {
      final (AppDatabase db, ProviderContainer container, _SpyPlugin plugin) =
          await build();
      await db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      final Account from = await db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      final Account to = await db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      await db.scheduledTransfersDao.create(
        accountId: from.id,
        targetAccountId: to.id,
        amountMinor: 5000,
        targetAmountMinor: 487500,
        executeAt: DateTime.utc(2026, 1, 1),
      );

      await container.read(scheduledTransfersServiceProvider).executeDue();

      expect(plugin.shown, hasLength(1));
      // Сумма — в валюте счёта списания ($ 50,00), не в базовой
      // (₽ 4 875,00) — решение D-130 §2.
      expect(
        plugin.shown.single.body,
        l.scheduledTransferExecutedBody(
          formatMoneyMinor(
            5000,
            symbol: r'$',
            locale: l.localeName,
            exponent: 2,
          ),
          'Рубли',
        ),
      );
      // Контроль: базовая сумма в тело не попала.
      expect(plugin.shown.single.body, isNot(contains('4')));
    },
  );

  group('D-119: замки триггеров биндинга (D-138, §6 п.1 и п.4)', () {
    /// Живая пара счетов для отложенного перевода.
    Future<(Account, Account)> seedAccounts(AppDatabase db) async {
      final Account from = await db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      final Account to = await db.accountsDao.create(
        name: 'Копилка',
        kind: AccountKind.bank,
        currencyCode: 'RUB',
      );
      return (from, to);
    }

    /// Контейнер с настоящим биндингом и считающим сервисом: уведомление —
    /// запись в список (текст уведомления закрыт замком D-133 выше).
    Future<
      (
        AppDatabase,
        ProviderContainer,
        _CountingService,
        List<ScheduledTransfer>,
      )
    >
    buildBinding() async {
      final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await seedDefaultsIfEmpty(db);
      final List<ScheduledTransfer> notified = <ScheduledTransfer>[];
      final _CountingService service = _CountingService(
        db: db,
        scheduledDao: db.scheduledTransfersDao,
        transactionsDao: db.transactionsDao,
        onExecuted: (ScheduledTransfer transfer) async =>
            notified.add(transfer),
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          scheduledTransfersServiceProvider.overrideWithValue(service),
        ],
      );
      addTearDown(container.dispose);
      return (db, container, service, notified);
    }

    test(
      'назревшие исполняются при старте, событие markExecuted — no-op',
      () async {
        final (
          AppDatabase db,
          ProviderContainer container,
          _CountingService service,
          List<ScheduledTransfer> notified,
        ) = await buildBinding();
        final (Account from, Account to) = await seedAccounts(db);
        await db.scheduledTransfersDao.create(
          accountId: from.id,
          targetAccountId: to.id,
          amountMinor: 123456,
          executeAt: DateTime.utc(2026, 1, 1),
        );

        final ScheduledTransfersBinding binding = container.read(
          scheduledTransfersBindingProvider,
        );
        await binding.start();

        // Стартовый проход: строка исполнена, уведомление ровно одно,
        // операция одна (параллельные стартовые вызовы гасит перепроверка
        // внутри транзакции — D-119).
        final List<ScheduledTransfer> rows = await db.scheduledTransfersDao
            .watchAlive()
            .first;
        expect(rows.single.executedAt, isNotNull);
        expect(notified, hasLength(1));
        expect(await db.select(db.transactions).get(), hasLength(1));

        // Три прохода: событие подписки при старте + явный вызов start()
        // + событие markExecuted (:88–95) — последний обязателен и
        // обязан быть no-op.
        await waitUntil(
          () async => service.calls >= 3,
          reason: 'событие markExecuted не запустило следующий проход',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(notified, hasLength(1));
        expect(await db.select(db.transactions).get(), hasLength(1));
        final List<ScheduledTransfer> after = await db.scheduledTransfersDao
            .watchAlive()
            .first;
        expect(after.single.executedAt, rows.single.executedAt);
      },
    );

    test('запись pending после старта — проход по событию потока', () async {
      final (
        AppDatabase db,
        ProviderContainer container,
        _CountingService service,
        List<ScheduledTransfer> notified,
      ) = await buildBinding();
      final (Account from, Account to) = await seedAccounts(db);
      final ScheduledTransfersBinding binding = container.read(
        scheduledTransfersBindingProvider,
      );
      await binding.start();
      expect(notified, isEmpty);
      final int afterStart = service.calls;

      await db.scheduledTransfersDao.create(
        accountId: from.id,
        targetAccountId: to.id,
        amountMinor: 5000,
        executeAt: DateTime.utc(2026, 1, 1),
      );

      await waitUntil(
        () async => notified.isNotEmpty,
        reason: 'запись pending не привела к исполнению',
      );
      expect(service.calls, greaterThan(afterStart));
      final List<ScheduledTransfer> rows = await db.scheduledTransfersDao
          .watchAlive()
          .first;
      expect(rows.single.executedAt, isNotNull);
    });

    test('импорт бэкапа → биндинг исполняет назревшие (§6 п.4)', () async {
      // Источник: бэкап с назревшей строкой (v8, D-120).
      final AppDatabase source = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(source.close);
      await seedDefaultsIfEmpty(source);
      final (Account sFrom, Account sTo) = await seedAccounts(source);
      await source.scheduledTransfersDao.create(
        accountId: sFrom.id,
        targetAccountId: sTo.id,
        amountMinor: 777,
        executeAt: DateTime.utc(2026, 1, 1),
      );
      final String json = await BackupService(source).exportJson();

      final (
        AppDatabase db,
        ProviderContainer container,
        _CountingService service,
        List<ScheduledTransfer> notified,
      ) = await buildBinding();
      final ScheduledTransfersBinding binding = container.read(
        scheduledTransfersBindingProvider,
      );
      await binding.start();
      expect(notified, isEmpty); // в целевой базе назревших нет
      final int afterStart = service.calls;

      await BackupService(db).importJson(json);

      await waitUntil(
        () async => notified.isNotEmpty,
        reason: 'импорт бэкапа не породил проход биндинга',
      );
      expect(service.calls, greaterThan(afterStart));
      final List<ScheduledTransfer> rows = await db.scheduledTransfersDao
          .watchAlive()
          .first;
      expect(rows.single.executedAt, isNotNull);
      expect(notified.single.id, rows.single.id);
    });
  });
}
