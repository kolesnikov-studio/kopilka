import 'dart:async';

import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/scheduled_dates.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';

/// Тексты напоминаний (D-83): константы механики; заголовок всех
/// оповещений — l10n-ключ `reminderTitle`, приходит швом [RemindersService.title]
/// от биндинга (M7-шаг D, D-130 §2 — константа удалена).
const String reminderBodyInterest = 'Пора начислить проценты по счёту';

const String reminderBodyDue = 'Приближается срок возврата долга';

/// Порог «близко к перерасходу» (D-118): 80% лимита/плана — константа кода,
/// не настройка. Сравнение целочисленное и точное: факт/лимит >= 4/5.
const int overBudgetThresholdNumerator = 4;
const int overBudgetThresholdDenominator = 5;

/// Источники оповещений о перерасходе (D-118) — префиксы ключа дедупа.
const String overBudgetSourceBudget = 'budget';
const String overBudgetSourcePlan = 'plan';

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

/// Текст тела оповещения о перерасходе (D-118): формулировка — шов.
/// Живой binding собирает его из l10n-ключей `reminderOverBudgetBody` /
/// `reminderOverBudgetExceededBody` (`reminders_texts.dart`), сумма —
/// со символом базовой валюты (D-130 §2); тесты — детерминированный
/// литерал. Финальные тексты утверждает спека шага D.
typedef OverBudgetBodyBuilder = String Function({
  required String categoryName,
  required int remainingMinor,
  required int daysLeft,
});

/// Заголовок всех оповещений (D-130 §2): l10n-ключ `reminderTitle`
/// резолвится на момент показа — шов биндинга, как у тела.
typedef ReminderTitleBuilder = String Function();

/// Кандидат оповещения «близко к перерасходу» (D-118): источник, ключ
/// дедупа «источник + категория + месяц/период», подпись категории,
/// остаток K (лимит/план − факт; отрицательный — перерасход) и D — дней
/// до конца месяца (UTC, для бюджета) или периода плана.
class OverBudgetCandidate {
  const OverBudgetCandidate({
    required this.source,
    required this.key,
    required this.categoryName,
    required this.remainingMinor,
    required this.daysLeft,
  });

  /// [overBudgetSourceBudget] или [overBudgetSourcePlan].
  final String source;

  /// Ключ дедупа «не чаще раза в сутки» (D-118).
  final String key;

  final String categoryName;

  /// K — лимит/план минус факт, минорные единицы базовой.
  final int remainingMinor;

  /// D — дней до конца периода (UTC), не меньше одного (условие показа).
  final int daysLeft;
}

/// Шов персиста для тестов (fake persistence, образец Б2/D-80): живой
/// [RemindersPreferencesStore] в брифе, фейк — в тест-замке.
abstract class RemindersPreferencesFake {
  Future<bool> readEnabled();

  Future<void> writeEnabled(bool enabled);

  /// Состояние дедупа оповещений о перерасходе (D-118): карта «ключ показа
  /// → дата последнего показа (UTC, `YYYY-MM-DD`)». Старый файл без поля
  /// (или поле не карта строк) — пусто, как необязательные поля v4/v5.
  Future<Map<String, String>> readAlertLastShown();

  Future<void> writeAlertLastShown(Map<String, String> lastShown);
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
/// `debt:<id>`), дата показа и текст (заголовок — шов [RemindersService.title]).
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
    required this.overBudgetBody,
    required this.title,
    this.clock = utcNow,
  });

  /// Настройка opt-in (reminders-preferences.json, D-43).
  final RemindersPreferencesFake prefs;

  /// Шов над платформенным плагином (в тестах — фейк).
  final RemindersPlugin plugin;

  /// Сборка текста оповещения о перерасходе (D-118): у живого приложения —
  /// l10n-тексты, у тестов — литерал.
  final OverBudgetBodyBuilder overBudgetBody;

  /// Заголовок всех оповещений (D-130 §2): у живого приложения —
  /// l10n-ключ `reminderTitle` через биндинг, у тестов — литерал.
  final ReminderTitleBuilder title;

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

  /// Разовое уведомление механики вне расписания (D-119: «исполнен
  /// отложенный перевод»): общий opt-in (D-83/D-118 — при выключенной
  /// настройке no-op), отказы канала глушатся, расписание не трогается.
  /// [payload] — ключ источника (стабильный числовой id — D-83).
  Future<void> showNow({
    required String payload,
    required String body,
    String? title,
  }) async {
    if (!await prefs.readEnabled()) {
      return;
    }
    if (!await _ensureInitialized()) {
      return; // «напоминания недоступны» — показ не состоялся (D-83)
    }
    try {
      await plugin.show(
        reminderNotificationId(payload),
        title: title ?? this.title(),
        body: body,
        payload: payload,
      );
    } on Exception {
      // Отказ канала не влияет на механику-источник (D-119).
    } catch (_) {
      // Error-иерархия (Linux): см. док-класс [FlNRemindersPlugin].
    }
  }

  /// Слот расписания из живых потоков DAO (источники — D-81): дата
  /// напоминания живых счетов и срок возврата живых долгов.
  ///
  /// Просроченные источники в будущее расписание не попадают: показ
  /// при ближайшем запуске решает [showOverdue]; повторов нет.
  static Future<List<ReminderSlot>> collectSlots(
    AccountsDao accountsDao,
    DebtsDao debtsDao, {
    DateTime? nowUtc,
    required String title,
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
          title: title,
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

  /// Кандидаты оповещений «близко к перерасходу» (D-118): прогресс бюджетов
  /// (месяц UTC) и планов-расходов (собственный период плана). Условие:
  /// факт >= 80% лимита/плана и >= 1 дня до конца месяца/периода;
  /// K = лимит − факт (базовая), D = дней до конца. Порядок — по ключу
  /// дедупа (детерминированный показ и тесты).
  static Future<List<OverBudgetCandidate>> collectOverBudgetCandidates(
    BudgetsDao budgetsDao,
    PlansDao plansDao,
    CategoriesDao categoriesDao, {
    required DateTime nowUtc,
  }) async {
    final DateTime now = nowUtc.toUtc();
    final List<OverBudgetCandidate> candidates = <OverBudgetCandidate>[];
    // Бюджеты: лимит и факт — базовые (D-19), период — месяц UTC (D-14).
    final int daysToMonthEnd = nextMonthStart(now).difference(now).inDays;
    if (daysToMonthEnd >= 1) {
      final List<BudgetProgress> progress = await budgetsDao
          .watchProgress(moment: now)
          .first;
      for (final BudgetProgress row in progress) {
        if (!isNearOverBudget(
          factMinor: row.spentMinor,
          limitMinor: row.limitMinor,
        )) {
          continue;
        }
        candidates.add(
          OverBudgetCandidate(
            source: overBudgetSourceBudget,
            key:
                '$overBudgetSourceBudget:${row.budget.categoryId}:'
                '${_monthKey(now)}',
            categoryName: row.categoryName,
            remainingMinor: row.limitMinor - row.spentMinor,
            daysLeft: daysToMonthEnd,
          ),
        );
      }
    }
    // Планы-расходы: направление — производная вида категории (D-115.а),
    // поэтому доходные отсеиваются по живому справочнику.
    final Set<String> expenseCategories = <String>{
      for (final Category category in await categoriesDao.getAlive(
        kind: CategoryKind.expense,
      ))
        category.id,
    };
    if (expenseCategories.isNotEmpty) {
      // Горизонт — год: карточка планов и алерты живут в этом горизонте;
      // завершённые периоды в выборку не попадают (period_end > now).
      final DateTime horizonEnd = DateTime.utc(
        now.year + 1,
        now.month,
        now.day,
      );
      final List<PlanVsFact> planRows = await plansDao
          .watchPlanVsFact(from: now, to: horizonEnd)
          .first;
      for (final PlanVsFact row in planRows) {
        if (!expenseCategories.contains(row.plan.categoryId)) {
          continue;
        }
        final DateTime? periodEnd = _parseUtcDate(row.plan.periodEnd);
        if (periodEnd == null) {
          continue; // несогласованный импорт: битая дата — пропуск
        }
        final int daysLeft = periodEnd.difference(now).inDays;
        if (daysLeft < 1) {
          continue;
        }
        if (!isNearOverBudget(
          factMinor: row.factMinor,
          limitMinor: row.plan.amountMinor,
        )) {
          continue;
        }
        candidates.add(
          OverBudgetCandidate(
            source: overBudgetSourcePlan,
            key:
                '$overBudgetSourcePlan:${row.plan.categoryId}:'
                '${row.plan.periodStart}|${row.plan.periodEnd}',
            categoryName: row.categoryName,
            remainingMinor: row.plan.amountMinor - row.factMinor,
            daysLeft: daysLeft,
          ),
        );
      }
    }
    candidates.sort(
      (OverBudgetCandidate a, OverBudgetCandidate b) => a.key.compareTo(b.key),
    );
    return candidates;
  }

  /// Идемпотентный пересчёт расписания (D-83): сборка слотов из живых
  /// потоков DAO, инициализация плагина, полная перезапись расписания
  /// и однократный показ просроченных. Отказы канала глушатся — запуск
  /// не зависит от уведомлений (D-43.г-дух); при выключенной настройке
  /// (файл настроек — истина) метод no-op.
  ///
  /// Оповещения о перерасходе (D-118) считаются здесь же, когда переданы
  /// [budgetsDao], [plansDao] и [categoriesDao] (binding передаёт все;
  /// тесты расписания могут не передавать): порог 80%, показ немедленный,
  /// дедуп — не чаще раза в сутки на ключ.
  Future<void> recalculate(
    AccountsDao accountsDao,
    DebtsDao debtsDao, {
    BudgetsDao? budgetsDao,
    PlansDao? plansDao,
    CategoriesDao? categoriesDao,
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
      title: title(),
    );
    await _replaceSchedule(slots);
    await _showOverdue(accountsDao, debtsDao);
    if (budgetsDao != null && plansDao != null && categoriesDao != null) {
      await _showOverBudgetAlerts(budgetsDao, plansDao, categoriesDao);
    }
  }

  /// Показ оповещений о перерасходе с дедупом (D-118): дата последнего
  /// показа хранится картой ключ → дата в reminders-preferences.json
  /// (старый файл без поля = пусто). Отметка ставится только после
  /// успешного show(): при недоступном канале кандидат честно подождёт
  /// следующего пересчёта.
  Future<void> _showOverBudgetAlerts(
    BudgetsDao budgetsDao,
    PlansDao plansDao,
    CategoriesDao categoriesDao,
  ) async {
    final DateTime now = clock();
    final List<OverBudgetCandidate> candidates =
        await collectOverBudgetCandidates(
          budgetsDao,
          plansDao,
          categoriesDao,
          nowUtc: now,
        );
    if (candidates.isEmpty) {
      return;
    }
    final Map<String, String> lastShown = Map<String, String>.of(
      await prefs.readAlertLastShown(),
    );
    final String today = _dayKey(now);
    bool changed = false;
    for (final OverBudgetCandidate candidate in candidates) {
      if (lastShown[candidate.key] == today) {
        continue; // уже показывали сегодня — не чаще раза в сутки
      }
      final String body = overBudgetBody(
        categoryName: candidate.categoryName,
        remainingMinor: candidate.remainingMinor,
        daysLeft: candidate.daysLeft,
      );
      try {
        final RemindersChannelError? error = await plugin.show(
          reminderNotificationId(candidate.key),
          title: title(),
          body: body,
          payload: candidate.key,
        );
        if (error != null) {
          continue; // канал недоступен — показ не отмечаем
        }
      } on Exception {
        continue;
      } catch (_) {
        // Error-иерархия (Linux): см. док-класс [FlNRemindersPlugin].
        continue;
      }
      lastShown[candidate.key] = today;
      changed = true;
    }
    if (changed) {
      await prefs.writeAlertLastShown(lastShown);
    }
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
          title: title(),
          body: entry.body,
          payload: entry.payload,
        );
      } on Exception {
        // «Напоминания недоступны»: не критично.
      }
    }
  }
}

/// Условие «близко к перерасходу» (D-118): факт >= 80% лимита/плана.
/// Сравнение целочисленное и точное — без double (порог 4/5).
bool isNearOverBudget({required int factMinor, required int limitMinor}) {
  if (limitMinor <= 0) {
    return false;
  }
  return factMinor * overBudgetThresholdDenominator >=
      limitMinor * overBudgetThresholdNumerator;
}

/// Ключ месяца UTC `YYYY-MM` (колонки-агрегаты и ключи дедупа).
String _monthKey(DateTime utc) =>
    '${utc.year.toString().padLeft(4, '0')}-'
    '${utc.month.toString().padLeft(2, '0')}';

/// Ключ календарного дня UTC `YYYY-MM-DD` — дата дедупа (D-118).
String _dayKey(DateTime utc) =>
    '${utc.year.toString().padLeft(4, '0')}-'
    '${utc.month.toString().padLeft(2, '0')}-'
    '${utc.day.toString().padLeft(2, '0')}';
