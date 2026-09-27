// Тесты границ календарного месяца (UTC): основа расчёта бюджетов и
// отчётов — одна и та же операция попадает в один месяц при любой зоне
// устройства.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/months.dart';

void main() {
  test('начало месяца по UTC: время отбрасывается, зона не влияет', () {
    expect(
      monthStart(DateTime.utc(2026, 9, 25, 18, 30)),
      DateTime.utc(2026, 9),
    );
    expect(
      monthStart(DateTime(2026, 9, 26, 2).toUtc()),
      DateTime.utc(2026, 9),
    );
  });

  test('локальное время внутри месяца даёт тот же месяц в UTC', () {
    // Момент собирается от смещения ЭТОЙ машины (H1): 1 октября 02:00 UTC
    // минус местное смещение — в зоне UTC+6 это «30 сентября 20:00, месяц
    // ещё сентябрь». Ожидания выводятся из самого мгновения, поэтому тест
    // истинный в любой зоне (в UTC±0 разницы зон нет — проверка вырождается
    // честно, без ложной ветки, как было раньше).
    final DateTime instantUtc =
        DateTime.utc(2026, 10, 1, 2).subtract(DateTime.now().timeZoneOffset);
    final DateTime local = instantUtc.toLocal();

    // Мгновение одно, зоны разные; monthStart обязан дать один месяц.
    expect(local.toUtc(), instantUtc);
    expect(
      monthStart(local),
      DateTime.utc(instantUtc.year, instantUtc.month),
    );
    expect(monthStart(local), monthStart(instantUtc));
  });

  test('переход через год: декабрь → январь следующего года', () {
    expect(
      nextMonthStart(DateTime.utc(2026, 12, 15)),
      DateTime.utc(2027, 1),
    );
    expect(monthStart(DateTime.utc(2027, 1, 1)), DateTime.utc(2027, 1));
  });

  test('границы месяца не пересекаются: [start, nextStart)', () {
    final DateTime start = monthStart(DateTime.utc(2026, 9, 15));
    final DateTime next = nextMonthStart(start);
    expect(next.isAfter(start), isTrue);
    expect(start.isAtSameMomentAs(DateTime.utc(2026, 9, 1)), isTrue);
    expect(next, DateTime.utc(2026, 10, 1));
  });
}
