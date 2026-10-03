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
}
