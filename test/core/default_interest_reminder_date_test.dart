// Замки дефолта даты напоминания (находка 8/D-102): кламп к последнему
// дню следующего месяца вместо авто-нормализации DateTime.utc(y, m+1, d),
// переполнявшей день в месяц+2 (31.03 → 01.05). Канон D-14 в границах
// обычных месяцев не меняется (сегодня + 1 календарный месяц).
//
// defaultInterestReminderDate — публичный API формы счёта (D-92.3);
// день берётся из utcNow — тестируются фиксированные календарные даты.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/features/accounts/account_form_dialog.dart';

void main() {
  test('кламп конца месяца: 31-е число уходит в последний день следующего', () {
    // Март → апрель (30 дней): 31.03 → 30.04.
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2026, 3, 31)),
      DateTime.utc(2026, 4, 30),
    );
  });

  test('кламп конца месяца: 31.01 → 28.02, в високосный год — 29.02', () {
    // Январь → февраль 2027 (невисокосный): 28 дней.
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2027, 1, 31)),
      DateTime.utc(2027, 2, 28),
    );
    // Январь → февраль 2028 (високосный): 29 дней.
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2028, 1, 31)),
      DateTime.utc(2028, 2, 29),
    );
  });

  test('30.01 → 28.02 (кламп бьёт раньше переполнения, D-14 не соблюдаем)', () {
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2027, 1, 30)),
      DateTime.utc(2027, 2, 28),
    );
  });

  test('обычные месяцы: день сохраняется (канон D-14 не тронут)', () {
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2026, 5, 15)),
      DateTime.utc(2026, 6, 15),
    );
    // Декабрь → январь следующего года.
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2026, 12, 7)),
      DateTime.utc(2027, 1, 7),
    );
    // 31.12 → 31.01: в январе 31 день есть.
    expect(
      defaultInterestReminderDateAt(DateTime.utc(2026, 12, 31)),
      DateTime.utc(2027, 1, 31),
    );
  });
}
