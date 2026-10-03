// Тест-замок оповещений «близко к перерасходу» (M7-шаг B, D-118):
// in-memory drift-БД + фейковые persistence/plugin (образец D-83).
// Проверяются: порог 80% (бюджеты и планы-расходы), условие «>= 1 дня до
// конца периода», направление планов по виду категории, K в тексте,
// дедуп «не чаще раза в сутки на ключ», no-op при выключенном opt-in.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
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

  /// Следующий отказ канала (одноразовый сценарий теста).
  RemindersChannelError? nextError;

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
    if (nextError != null) {
      return nextError;
    }
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

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seedDefaultsIfEmpty(db);
    prefs = _FakePrefs();
    plugin = _FakePlugin();
    // Фиксированный момент: 2026-10-15 12:00 UTC; до конца месяца
    // (2026-11-01 00:00 UTC) — 16 полных дней.
    fixedNow = DateTime.utc(2026, 10, 15, 12);
    service = RemindersService(
      prefs: prefs,
      plugin: plugin,
      title: () => 'Kopilka: напоминание',
      overBudgetBody:
          ({
            required String categoryName,
            required int remainingMinor,
            required int daysLeft,
          }) => 'K=$remainingMinor D=$daysLeft',
      clock: () => fixedNow,
    );
    addTearDown(db.close);
  });

  Future<void> recalculate() => service.recalculate(
    db.accountsDao,
    db.debtsDao,
    budgetsDao: db.budgetsDao,
    plansDao: db.plansDao,
    categoriesDao: db.categoriesDao,
  );

  Future<Account> seedAccount() =>
      db.accountsDao.create(name: 'Наличные', kind: AccountKind.cash, currencyCode: 'RUB');

  Future<void> seedExpense(Category category, int amountMinor) async {
    final Account account = await seedAccount();
    await db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: category.id,
      amountMinor: amountMinor,
      date: DateTime.utc(2026, 10, 5),
    );
  }

  group('условие 80% (D-118)', () {
    test('бюджет: ровно 80% показывается, 79% — нет', () async {
      final Category near = await db.categoriesDao.create(
        name: 'Близкая',
        kind: CategoryKind.expense,
      );
      final Category far = await db.categoriesDao.create(
        name: 'Далёкая',
        kind: CategoryKind.expense,
      );
      await db.budgetsDao.create(categoryId: near.id, limitMinor: 10000);
      await db.budgetsDao.create(categoryId: far.id, limitMinor: 10000);
      await seedExpense(near, 8000); // ровно 80%
      await seedExpense(far, 7999);

      await recalculate();

      expect(plugin.shown, hasLength(1));
      expect(plugin.shown.single, startsWith('budget:${near.id}:2026-10|'));
      // K = 10000 − 8000, D = 16 (до конца октября UTC).
      expect(plugin.shown.single, contains('K=2000 D=16'));
    });

    test('плановые 80% считаются по факту периода плана', () async {
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.plansDao.create(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 10, 1),
        periodEnd: DateTime.utc(2026, 11, 1),
        amountMinor: 10000,
      );
      await seedExpense(food, 8000);

      await recalculate();

      expect(plugin.shown, hasLength(1));
      expect(plugin.shown.single, startsWith('plan:${food.id}:'));
      expect(plugin.shown.single, contains('K=2000 D=16'));
    });

    test('меньше 80% — оповещения нет', () async {
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.plansDao.create(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 10, 1),
        periodEnd: DateTime.utc(2026, 11, 1),
        amountMinor: 10000,
      );
      await seedExpense(food, 7999);

      await recalculate();

      expect(plugin.shown, isEmpty);
    });

    test('перерасход: K отрицательный и уходит в текст', () async {
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.plansDao.create(
        categoryId: food.id,
        periodStart: DateTime.utc(2026, 10, 1),
        periodEnd: DateTime.utc(2026, 11, 1),
        amountMinor: 1000,
      );
      await seedExpense(food, 1500);

      await recalculate();

      expect(plugin.shown, hasLength(1));
      expect(plugin.shown.single, contains('K=-500 D=16'));
    });

    test('до конца периода меньше суток — оповещения нет', () async {
      // 2026-10-31 23:00 UTC: до конца месяца — один час.
      fixedNow = DateTime.utc(2026, 10, 31, 23);
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.budgetsDao.create(categoryId: food.id, limitMinor: 10000);
      await seedExpense(food, 10000);

      await recalculate();

      expect(plugin.shown, isEmpty);
    });

    test('план доходной категории не считается перерасходом', () async {
      final Category salary = await db.categoriesDao.create(
        name: 'Зарплата',
        kind: CategoryKind.income,
      );
      final Account account = await seedAccount();
      await db.plansDao.create(
        categoryId: salary.id,
        periodStart: DateTime.utc(2026, 10, 1),
        periodEnd: DateTime.utc(2026, 11, 1),
        amountMinor: 10000,
      );
      await db.transactionsDao.create(
        type: TransactionType.income,
        accountId: account.id,
        categoryId: salary.id,
        amountMinor: 9000,
        date: DateTime.utc(2026, 10, 5),
      );

      await recalculate();

      expect(plugin.shown, isEmpty);
    });
  });

  group('дедуп и opt-in (D-118)', () {
    test('повторный пересчёт в те же сутки не повторяет показ; на '
        'следующий день — показывает снова', () async {
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.budgetsDao.create(categoryId: food.id, limitMinor: 10000);
      await seedExpense(food, 9000);

      await recalculate();
      await recalculate();
      expect(plugin.shown, hasLength(1));
      expect(
        prefs.alertLastShown['budget:${food.id}:2026-10'],
        '2026-10-15',
      );

      fixedNow = DateTime.utc(2026, 10, 16, 12);
      await recalculate();
      expect(plugin.shown, hasLength(2));
      expect(
        prefs.alertLastShown['budget:${food.id}:2026-10'],
        '2026-10-16',
      );
    });

    test('выключенный opt-in — ни показа, ни записи состояния дедупа', () async {
      prefs.enabled = false;
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.budgetsDao.create(categoryId: food.id, limitMinor: 10000);
      await seedExpense(food, 10000);

      await recalculate();

      expect(plugin.shown, isEmpty);
      expect(prefs.alertLastShown, isEmpty);
    });

    test('показ не состоялся (канал недоступен) — дедуп не отмечается, '
        'следующий пересчёт пробует снова', () async {
      final Category food = await db.categoriesDao.create(
        name: 'Еда',
        kind: CategoryKind.expense,
      );
      await db.budgetsDao.create(categoryId: food.id, limitMinor: 10000);
      await seedExpense(food, 10000);
      plugin.nextError = const RemindersChannelError('show');

      await recalculate();
      expect(plugin.shown, isEmpty);
      expect(prefs.alertLastShown, isEmpty);

      plugin.nextError = null;
      await recalculate();
      expect(plugin.shown, hasLength(1));
    });
  });
}
