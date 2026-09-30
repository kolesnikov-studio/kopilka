/// День даты напоминания в локальной зоне устройства (D-83).
///
/// Источники хранят даты в UTC (§3): интересен именно локальный
/// календарный день (day/month/year в зоне устройства), а не UTC-день —
/// иначе пользователю западнее UTC напоминание «упало» бы на день позже.
DateTime scheduledDateDay(DateTime utcDate) {
  final DateTime local = utcDate.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// Момент показа напоминания (D-83): 09:00 локального времени устройства
/// на дату [utcDate]. Час — константа D-83; финальное время может уточнить
/// спека дизайнера шага D — шов оставлен (меняется только здесь).
///
/// Возвращается как UTC-момент (§3): из него плагин собирает локальный
/// TZDateTime (data/reminders/reminders_plugin.dart).
DateTime reminderMoment(DateTime utcDate) {
  final DateTime localDay = scheduledDateDay(utcDate);
  return DateTime(localDay.year, localDay.month, localDay.day, 9, 0).toUtc();
}

/// Просрочено ли напоминание к моменту [nowUtc] (D-83): момент показа
/// уже в прошлом. Просроченное показывается при ближайшем запуске
/// однократно — решает [RemindersService].
bool isReminderOverdue(DateTime utcDate, DateTime nowUtc) =>
    reminderMoment(utcDate).isBefore(nowUtc);
