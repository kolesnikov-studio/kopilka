import 'dart:async';

import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/scheduled_dates.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';

/// Тексты напоминаний (D-83): константы механики; финальные тексты —
/// спека дизайнера шага D (D-92.1) — шов закрыт правкой литералов.
const String reminderTitle = 'Kopilka: напоминание';

const String reminderBodyInterest = 'Пора начислить проценты по счёту';

const String reminderBodyDue = 'Приближается срок возврата долга';

/// Дата из UTC-строки колонки v7 (§3); NULL/битая строка — нет даты
/// (схема валидна, строка не обязана парситься — напоминание молча
/// не ставится; ту же терпимость показывает бэкап при чтении v1–v6).
DateTime? _parseUtcDate(String? iso) {
  if (iso == null || iso.isEmpty) {
    return null;
  }
  return DateTime.tryParse(iso)?.toUtc();
}

/// Стабильный числовой id из payload-ключа источника (D-83: расписание
/// перезаписывается целиком, id должен быть воспроизводим между запусками;
/// коллизии невозможны — множители взаимно просты).
int reminderNotificationId(String payloadKey) {
  int hash = 0;
  for (final int code in payloadKey.codeUnits) {
    hash = (hash * 31 + code) % 1000003;
  }
  return (hash * 131071) % 1000000007;
}

/// Ключи payload источника (D-83: напоминания из данных v7, D-81).
///
/// Для долгов — одна дата на долг: если due_date ещё в будущем,
/// планирование на её 09:00; если уже прошло — показ при ближайшем
/// запуске (однократно), без будущего слота.
const String reminderSourceAccount = 'account:';
const String reminderSourceDebt = 'debt:';

/// Шов персиста для тестов (fake persistence, образец Б2/D-80): живой
/// [RemindersPreferencesStore] в брифе, фейк — в тест-замке.
abstract class RemindersPreferencesFake {
  Future<bool> readEnabled();

  Future<void> writeEnabled(bool enabled);
}

/// Слот расписания: источник, дата показа и готовые тексты.
class ReminderSlot {
  const ReminderSlot({
    required this.payload,
    required this.reminderDate,
    required this.title,
    required this.body,
  });

  /// Payload уведомления: `account:<id>` / `debt:<id>`.
  final String payload;

  /// Дата напоминания (UTC-момент из БД, D-81).
  final DateTime reminderDate;

  final String title;
  final String body;

  /// Стабильный числовой id (см. [reminderNotificationId]).
  int get notificationId => reminderNotificationId(payload);
}

/// Источник единого обхода напоминаний (D-96): payload (`account:<id>` /
/// `debt:<id>`), дата показа и текст (заголовок общий — [reminderTitle]).
class _ReminderEntry {
  const _ReminderEntry({
    required this.payload,
    required this.date,
    required this.body,
  });

  final String payload;

  /// Дата напоминания (UTC-момент из БД, D-81).
  final DateTime date;

  final String body;
}

/// Механика напоминаний (M6/D-83): расписание = чистая функция над живыми
/// данными v7 (D-81), отдельной таблицы напоминаний нет.
///
/// Контракт:
/// - включение — opt-in: настройка по умолчанию выключена (D-83);
/// - пересчёт идемпотентен: расписание перезаписывается ЦЕЛИКОМ при
///   запуске и при каждом изменении источников (это же закрывает
///   перезапись после импорта бэкапа — D-83);
/// - момент показа — 09:00 локального времени устройства на дату
///   напоминания (D-83);
/// - просроченные показываются при ближайшем запуске один раз, без
///   повторов (D-83): «однократность» — отмена прошлого показа тем же
///   запуском пересчёта, который перезаписывает расписание.
///
/// Тест-замок (бриф B): in-memory БД + фейковый persistence/plugin по
/// образцу Б2/D-80 — подменяются [clock], [prefs], [plugin] и потоки DAO.
class RemindersService {
  RemindersService({
    required this.prefs,
    required this.plugin,
    this.clock = utcNow,
  });

  /// Настройка opt-in (reminders-preferences.json, D-43).
  final RemindersPreferencesFake prefs;

  /// Шов над платформенным плагином (в тестах — фейк).
  final RemindersPlugin plugin;

  /// Часы сервиса (в тестах — фиксированные, образец DAO `clock`).
  final Clock clock;

  bool _initialized = false;

  /// Показанные при этом запуске просроченные payload'ы: без повторов
  /// при следующих пересчётах того же запуска (D-83).
  final Set<String> _shownOverdue = <String>{};

  /// Инициализация плагина — не лениво при первом уведомлении, а при
  /// старте механики (после включения настройки). Повторные вызовы —
  /// no-op; отказ канала → false: «напоминания недоступны», дальнейшие
  /// попытки в этом запуске не предпринимаются (D-83).
  Future<bool> _ensureInitialized() async {
    if (_initialized) {
      return true;
    }
    final RemindersChannelError? error = await plugin.initialize();
    if (error != null) {
      return false;
    }
    _initialized = true;
    return true;
  }

  /// Включает/выключает напоминания (штатное включение пользователем —
  /// UI шага C/D): пишет настройку в файл (D-43) и при выключении
  /// сбрасывает платформенное расписание.
  ///
  /// Запрос разрешений — только здесь и только там, где платформа
  /// требует (Android 13+ POST_NOTIFICATIONS); на Windows/Linux
  /// разрешения нет. Разрешение добавляется при реализации UI шага C/D
  /// — механике нужен только факт opt-in (шов оставлен, D-83).
  Future<void> setEnabled(bool enabled) async {
    await prefs.writeEnabled(enabled);
    if (!enabled) {
      await plugin.replaceAll(const <ReminderScheduleEntry>[]);
    }
  }

  /// Читает настройку opt-in (для UI шага C/D; по умолчанию — выкл).
  Future<bool> readEnabled() => prefs.readEnabled();

  /// Слот расписания из живых потоков DAO (источники — D-81): дата
  /// напоминания живых счетов и срок возврата живых долгов.
  ///
  /// Просроченные источники в будущее расписание не попадают: показ
  /// при ближайшем запуске решает [showOverdue]; повторов нет.
  static Future<List<ReminderSlot>> collectSlots(
    AccountsDao accountsDao,
    DebtsDao debtsDao, {
    DateTime? nowUtc,
  }) async {
    final DateTime now = nowUtc ?? utcNow();
    final List<ReminderSlot> slots = <ReminderSlot>[];
    for (final _ReminderEntry entry in await _reminderEntries(
      accountsDao,
      debtsDao,
    )) {
      // Просроченные источники в будущее расписание не попадают (D-83):
      // показ при ближайшем запуске решает [showOverdue]; повторов нет.
      if (isReminderOverdue(entry.date, now)) {
        continue;
      }
      slots.add(
        ReminderSlot(
          payload: entry.payload,
          reminderDate: entry.date,
          title: reminderTitle,
          body: entry.body,
        ),
      );
    }
    return slots;
  }

  /// Живые источники напоминаний одним обходом (D-96): счёт — дата
  /// напоминания о процентах, долг — срок возврата; payload-префикс и
  /// тексты — параметры обхода. Непарсабельная/пустая дата — источник
  /// молча пропускается (терпимость схемы, см. [_parseUtcDate]); отбор
  /// просроченных — у потребителей ([collectSlots] / [_showOverdue]).
  static Future<List<_ReminderEntry>> _reminderEntries(
    AccountsDao accountsDao,
    DebtsDao debtsDao,
  ) async {
    final List<Account> accounts = await accountsDao.watchAlive().first;
    final List<Debt> debts = await debtsDao.watchAlive().first;
    final List<_ReminderEntry> entries = <_ReminderEntry>[];
    void collect(String? isoDate, String prefix, String id, String body) {
      final DateTime? date = _parseUtcDate(isoDate);
      if (date == null) {
        return;
      }
      entries.add(
        _ReminderEntry(payload: '$prefix$id', date: date, body: body),
      );
    }

    for (final Account account in accounts) {
      collect(
        account.interestReminderDate,
        reminderSourceAccount,
        account.id,
        reminderBodyInterest,
      );
    }
    for (final Debt debt in debts) {
      collect(debt.dueDate, reminderSourceDebt, debt.id, reminderBodyDue);
    }
    return entries;
  }

  /// Идемпотентный пересчёт расписания (D-83): сборка слотов из живых
  /// потоков DAO, инициализация плагина, полная перезапись расписания
  /// и однократный показ просроченных. Отказы канала глушатся — запуск
  /// не зависит от уведомлений (D-43.г-дух); при выключенной настройке
  /// (файл настроек — истина) метод no-op.
  Future<void> recalculate(
    AccountsDao accountsDao,
    DebtsDao debtsDao, {
    bool? enabled,
  }) async {
    final bool isEnabled = enabled ?? await prefs.readEnabled();
    if (!isEnabled) {
      return;
    }
    if (!await _ensureInitialized()) {
      // «Напоминания недоступны»: ни расписание, ни показ (D-83).
      return;
    }
    final List<ReminderSlot> slots = await collectSlots(
      accountsDao,
      debtsDao,
      nowUtc: clock(),
    );
    await _replaceSchedule(slots);
    await _showOverdue(accountsDao, debtsDao);
  }

  /// Полная перезапись расписания. [Error] (Linux: UnimplementedError из
  /// zonedSchedule) и [Exception] глушатся одинаково — «напоминания
  /// недоступны на этой платформе» (D-83; расписание на Linux пусто,
  /// просроченные всё равно показываются прямым show()).
  Future<void> _replaceSchedule(List<ReminderSlot> slots) async {
    try {
      await plugin.replaceAll(
        slots
            .map(
              (ReminderSlot slot) => ReminderScheduleEntry(
                notificationId: slot.notificationId,
                reminderDate: slot.reminderDate,
                title: slot.title,
                body: slot.body,
                payload: slot.payload,
              ),
            )
            .toList(),
      );
    } on Exception {
      // «Напоминания недоступны»: запуск не зависит от уведомлений.
    } catch (_) {
      // Error-иерархия (Linux): см. док-класс [FlNRemindersPlugin].
    }
  }

  /// Разовое показывание просроченных (D-83): «сегодняшний» момент 09:00
  /// уже в прошлом — показ при ближайшем запуске. Без повторов: тот же
  /// запуск сначала перезаписал расписание (отменив прошлые показы), а
  /// показанные payload'ы запоминаются до конца сессии.
  Future<void> _showOverdue(AccountsDao accountsDao, DebtsDao debtsDao) async {
    final DateTime now = clock();
    for (final _ReminderEntry entry in await _reminderEntries(
      accountsDao,
      debtsDao,
    )) {
      // Разовое показывание просроченных (D-83): тот же запуск сначала
      // перезаписал расписание (отменив прошлые показы), показанные
      // payload'ы запоминаются до конца сессии.
      if (!isReminderOverdue(entry.date, now)) {
        continue;
      }
      if (_shownOverdue.contains(entry.payload)) {
        continue;
      }
      _shownOverdue.add(entry.payload);
      try {
        await plugin.show(
          reminderNotificationId(entry.payload),
          title: reminderTitle,
          body: entry.body,
          payload: entry.payload,
        );
      } on Exception {
        // «Напоминания недоступны»: не критично.
      }
    }
  }
}
