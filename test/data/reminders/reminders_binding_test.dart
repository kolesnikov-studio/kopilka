// Замок защёлки in-flight пересчёта (находка D-138, п.3): два
// interleaving-пересчёта через биндинг показывают ключ перерасхода за
// сутки ровно один раз. Без защёлки оба читают карту lastShown до записи
// и показывают ключ дважды (воспроизведение ревью — `Future.wait` из двух
// пересчётов). Вторая половина замка — защёлка отпускается: пересчёт
// следующего дня снова показывает.
//
// Образец — reminders_over_budget_test.dart: in-memory drift + фейки
// prefs/plugin, фиксированные часы; простой `test` (потоки drift читаются
// real async — вне fake_async, D-136). Биндинг — настоящий
// (remindersBindingProvider) с подменённым сервисом.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';

class _FakePrefs implements RemindersPreferencesFake {
  bool enabled = true;
  Map<String, String> alertLastShown = <String, String>{};

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;

  @override
  Future<Map<String, String>> readAlertLastShown() async =>
      Map<String, String>.of(alertLastShown);

  @override
  Future<void> writeAlertLastShown(Map<String, String> lastShown) async =>
      alertLastShown = Map<String, String>.of(lastShown);
}

class _FakePlugin implements RemindersPlugin {
  /// Показанные уведомления: «payload|body».
  final List<String> shown = <String>[];

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
    shown.add('$payload|$body');
    return null;
  }
}

void main() {
  late AppDatabase db;
  late _FakePrefs prefs;
  late _FakePlugin plugin;
  late DateTime fixedNow;
  late RemindersService service;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seedDefaultsIfEmpty(db);
    prefs = _FakePrefs();
    plugin = _FakePlugin();
    // Фиксированный момент: 2026-10-15 12:00 UTC (образец
    // reminders_over_budget_test).
    fixedNow = DateTime.utc(2026, 10, 15, 12);
    service = RemindersService(
      prefs: prefs,
      plugin: plugin,
      title: () => 'Kopilka: напоминание',
      overBudgetBody: ({
        required String categoryName,
        required int remainingMinor,
        required int daysLeft,
      }) => 'K=$remainingMinor D=$daysLeft',
      clock: () => fixedNow,
    );
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        remindersServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
  });

  /// Бюджет 10000 и расход 9000 (90% — порог D-118 взят).
  Future<Category> seedOverBudget() async {
    final Category food = await db.categoriesDao.create(
      name: 'Продукты',
      kind: CategoryKind.expense,
    );
    await db.budgetsDao.create(categoryId: food.id, limitMinor: 10000);
    final Account account = await db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: 'RUB',
    );
    await db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: food.id,
      amountMinor: 9000,
      date: DateTime.utc(2026, 10, 5),
    );
    return food;
  }

  test(
    'D-138: два interleaving-пересчёта биндинга → один показ за сутки',
    () async {
      final Category food = await seedOverBudget();
      final String key = 'budget:${food.id}:2026-10';
      final RemindersBinding binding = container.read(remindersBindingProvider);

      await Future.wait(<Future<void>>[
        binding.recalculateNow(),
        binding.recalculateNow(),
      ]);

      expect(plugin.shown, hasLength(1));
      expect(plugin.shown.single, startsWith('$key|'));
      expect(prefs.alertLastShown[key], '2026-10-15');

      // Тот же день — повторного показа нет (дедуп держится).
      await binding.recalculateNow();
      expect(plugin.shown, hasLength(1));
    },
  );

  test(
    'D-138: защёлка отпускается — пересчёт следующего дня показывает',
    () async {
      final Category food = await seedOverBudget();
      final String key = 'budget:${food.id}:2026-10';
      final RemindersBinding binding = container.read(remindersBindingProvider);

      await Future.wait(<Future<void>>[
        binding.recalculateNow(),
        binding.recalculateNow(),
      ]);
      expect(plugin.shown, hasLength(1));

      // Новые сутки: in-flight сброшен, новый пересчёт стартует сам и
      // дедуп пропускает показ (ключа за новый день ещё нет).
      fixedNow = DateTime.utc(2026, 10, 16, 12);
      await binding.recalculateNow();

      expect(plugin.shown, hasLength(2));
      expect(prefs.alertLastShown[key], '2026-10-16');
    },
  );
}
