/// Границы календарного месяца для группировки операций и расчёта бюджетов.
///
/// Все даты в БД хранятся в UTC (§3), поэтому и месяцы считаются в UTC:
/// одна и та же операция попадает в один и тот же месяц независимо от
/// часового пояса устройства. Смена таймзоны пользователя не меняет историю.
library;

/// Начало календарного месяца (UTC), в который попадает [moment].
DateTime monthStart(DateTime moment) {
  final DateTime utc = moment.toUtc();
  return DateTime.utc(utc.year, utc.month);
}

/// Начало следующего месяца (UTC) — верхняя (не включаемая) граница месяца.
DateTime nextMonthStart(DateTime moment) {
  final DateTime utc = moment.toUtc();
  return DateTime.utc(utc.year, utc.month + 1);
}
