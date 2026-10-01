// Тест-замок пересчёта расписания напоминаний (M6-шаг B, D-83): in-memory
// drift-БД + фейковые persistence/plugin по образцу Б2/D-80 (без
// платформенных каналов). Проверяются: сборка слотов из живых источников
// v7 (D-81), идемпотентность пересчёта (полная перезапись), разовое
// показывание просроченных, no-op при выключенной настройке.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';

class _FakePrefs implements RemindersPreferencesFake {
  bool enabled = false;

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

class _FakePlugin implements RemindersPlugin {
  final List<ReminderScheduleEntry> scheduled = <ReminderScheduleEntry>[];
  final List<String> shown = <String>[];
  int replaceAllCalls = 0;
  int initializeCalls = 0;
  RemindersChannelError? nextError;

  @override
  Future<RemindersChannelError?> initialize() async {
    initializeCalls++;
    return nextError;
  }

  @override
  Future<RemindersChannelError?> replaceAll(
    List<ReminderScheduleEntry> entries,
  ) async {
    replaceAllCalls++;
    scheduled
      ..clear()
      ..addAll(entries);
    return nextError;
  }

  @override
  Future<RemindersChannelError?> show(
    int notificationId, {
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add(payload);
    return nextError;
  }

  void reset() {
    scheduled.clear();
    shown.clear();
    replaceAllCalls = 0;
    initializeCalls = 0;
    nextError = null;
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
    // Фиксированный момент: среда 2026-09-30 12:00 UTC (D-80: зона
    // тест-машины не читается).
    fixedNow = DateTime.utc(2026, 9, 30, 12, 0);
    service = RemindersService(
      prefs: prefs,
      plugin: plugin,
      clock: () => fixedNow,
    );
    addTearDown(db.close);
  });

  group('сборка слотов из живых источников v7 (D-81/D-83)', () {
    test(
      'дата счёта и срок долга попадают в слоты, просроченные — нет',
      () async {
        final Account savings = await db.accountsDao.create(
          name: 'Накопительный',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
        );
        final Account overdue = await db.accountsDao.create(
          name: 'Просроченный',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          interestReminderDate: DateTime.utc(2026, 9, 1, 0, 0),
        );
        await db.debtsDao.create(
          person: 'Иван',
          direction: DebtDirection.theyOweMe,
          amountMinor: 100_00,
          currencyCode: 'RUB',
          dueDate: DateTime.utc(2026, 10, 20, 18, 30),
        );
        await db.debtsDao.create(
          person: 'Пётр',
          direction: DebtDirection.iOweThem,
          amountMinor: 50_00,
          currencyCode: 'RUB',
        );

        final List<ReminderSlot> slots = await RemindersService.collectSlots(
          db.accountsDao,
          db.debtsDao,
          nowUtc: fixedNow,
        );

        expect(slots, hasLength(2));
        expect(
          slots.map((ReminderSlot slot) => slot.payload),
          containsAll(<String>['account:${savings.id}']),
        );
        // Просроченный счёт не в расписании (показ при запуске — отдельно).
        expect(
          slots.any(
            (ReminderSlot slot) => slot.payload == 'account:${overdue.id}',
          ),
          isFalse,
        );
      },
    );

    test(
      'мягкое удаление источника убирает его из расписания (живые потоки)',
      () async {
        final Account account = await db.accountsDao.create(
          name: 'Временно',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
        );
        await db.accountsDao.softDelete(account.id);

        final List<ReminderSlot> slots = await RemindersService.collectSlots(
          db.accountsDao,
          db.debtsDao,
          nowUtc: fixedNow,
        );

        expect(slots, isEmpty);
      },
    );

    test('обычные счёт/долг без дат слотов не дают', () async {
      await db.accountsDao.create(
        name: 'Обычный',
        kind: AccountKind.cash,
        currencyCode: 'RUB',
      );
      await db.debtsDao.create(
        person: 'Анна',
        direction: DebtDirection.theyOweMe,
        amountMinor: 70_00,
        currencyCode: 'RUB',
      );

      final List<ReminderSlot> slots = await RemindersService.collectSlots(
        db.accountsDao,
        db.debtsDao,
        nowUtc: fixedNow,
      );

      expect(slots, isEmpty);
    });
  });

  group('идемпотентный пересчёт (D-83)', () {
    test('повторный recalculate перезаписывает то же расписание — '
        'без дублей и хвостов', () async {
      final Account account = await db.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
      );
      prefs.enabled = true;

      await service.recalculate(db.accountsDao, db.debtsDao);
      await service.recalculate(db.accountsDao, db.debtsDao);

      expect(plugin.replaceAllCalls, 2);
      expect(plugin.scheduled, hasLength(1));
      expect(plugin.scheduled.single.payload, 'account:${account.id}');
      // Повторная инициализация не нужна: инициализация — once per service.
      expect(plugin.initializeCalls, 1);
    });

    test('изменение источника меняет расписание после пересчёта', () async {
      final Account first = await db.accountsDao.create(
        name: 'Первый',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
      );
      prefs.enabled = true;
      await service.recalculate(db.accountsDao, db.debtsDao);
      expect(plugin.scheduled.single.payload, 'account:${first.id}');

      // Источник исчез (сброс даты Value(null) = счёт снова обычный,
      // D-81: NULL — обычный счёт) — расписание пусто.
      await db.accountsDao.updateAccount(
        first.id,
        interestReminderDate: const Value<DateTime?>(null),
      );
      await service.recalculate(db.accountsDao, db.debtsDao);

      expect(plugin.scheduled, isEmpty);
    });

    test(
      'выключенная настройка — no-op: ни плагин, ни расписание (opt-in)',
      () async {
        await db.accountsDao.create(
          name: 'Накопительный',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
        );

        await service.recalculate(db.accountsDao, db.debtsDao);

        expect(plugin.replaceAllCalls, 0);
        expect(plugin.initializeCalls, 0);
        expect(plugin.shown, isEmpty);
      },
    );

    test('setEnabled(false) сбрасывает платформенное расписание', () async {
      prefs.enabled = true;
      await service.setEnabled(false);

      expect(prefs.enabled, isFalse);
      expect(plugin.replaceAllCalls, 1);
      expect(plugin.scheduled, isEmpty);
    });
  });

  group('разовое показывание просроченных (D-83)', () {
    test('просроченное показывается при ближайшем запуске один раз', () async {
      final Account account = await db.accountsDao.create(
        name: 'Просроченный',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2026, 9, 1, 0, 0),
      );
      prefs.enabled = true;

      await service.recalculate(db.accountsDao, db.debtsDao);
      await service.recalculate(db.accountsDao, db.debtsDao);

      expect(plugin.shown, <String>['account:${account.id}']);
      // Просроченное не планируется в будущее расписание.
      expect(plugin.scheduled, isEmpty);
    });

    test('будущее напоминание не показывается сразу', () async {
      await db.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
      );
      prefs.enabled = true;

      await service.recalculate(db.accountsDao, db.debtsDao);

      expect(plugin.shown, isEmpty);
      expect(plugin.scheduled, hasLength(1));
    });

    test('отказ канала не мешает запуску: «напоминания недоступны»', () async {
      await db.accountsDao.create(
        name: 'Просроченный',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2026, 9, 1, 0, 0),
      );
      prefs.enabled = true;
      plugin.nextError = const RemindersChannelError('initialization');

      // Не бросает.
      await service.recalculate(db.accountsDao, db.debtsDao);

      expect(plugin.shown, isEmpty);
    });
  });

  group('тексты — шов для спеки дизайнера (шаг D, закрыт D-92.1)', () {
    test('финальные тексты D-92.1 в слотах', () async {
      await db.accountsDao.create(
        name: 'Накопительный',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        interestReminderDate: DateTime.utc(2026, 10, 15, 0, 0),
      );

      final List<ReminderSlot> slots = await RemindersService.collectSlots(
        db.accountsDao,
        db.debtsDao,
        nowUtc: fixedNow,
      );

      expect(slots.single.title, reminderTitle);
      expect(slots.single.body, reminderBodyInterest);
    });
  });
}
