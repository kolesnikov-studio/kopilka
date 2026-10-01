/// Источник текущего времени для штампов `created_at` / `updated_at`.
///
/// Тип вынесен отдельно, чтобы тесты подменяли часы фиксированным временем
/// и проверяли отметки точно.
typedef Clock = DateTime Function();

/// Текущий момент в UTC: все штампы времени хранятся в UTC (§3).
DateTime utcNow() => DateTime.now().toUtc();

/// Часы формы быстрого ввода (§7, образец DAO `clock: utcNow`): тест
/// подменяет присвоением (`formClock = () => ...`), живой код не меняется.
/// Дата новой операции — UTC (D-78), замок месяца зависит от этого шва.
Clock formClock = utcNow;

/// Полночь UTC календарного дня даты (§3): сроки хранятся полуночью UTC,
/// календарные сравнения — общее ядро карточки % (D-93.2) и просрочки
/// долга (S3/D-101).
DateTime calendarDayUtc(DateTime date) =>
    DateTime.utc(date.year, date.month, date.day);

/// «День даты настал или уже прошёл» в UTC (D-93.2: напоминание живо весь
/// сегодняшний день UTC, уходит при переносе даты). Уточнение D-102:
/// сравнение календарных дат в UTC, не по локальному дню и не моментом.
bool isDueTodayOrEarlierUtc(DateTime date, DateTime nowUtc) =>
    !calendarDayUtc(date).isAfter(calendarDayUtc(nowUtc));

/// «День даты строго раньше дня now» — просрочка со следующего дня
/// (S3/D-101): срок «сегодня» не просрочен весь сегодняшний день UTC,
/// «вчера» — просрочен. Не путать с [isDueTodayOrEarlierUtc] (день
/// наступил/прошёл — включает сегодня).
bool isCalendarOverdueUtc(DateTime date, DateTime nowUtc) =>
    calendarDayUtc(date).isBefore(calendarDayUtc(nowUtc));
