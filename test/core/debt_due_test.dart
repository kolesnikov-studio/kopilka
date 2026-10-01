// Замки календарной семантики дат (S3 D-101 + находка 1/D-102):
// просрочка срока долга — календарными датами в UTC, семантика общая
// с карточкой % (D-93.2). Фиксированные даты — полночь UTC (§3);
// часы в замки не заходят: чистые функции от аргументов.
//
// Обязательный край тестировщика (D-102): «сегодня» не просрочена,
// «вчера» просрочена — просрочка со следующего дня.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/features/debts/debt_due.dart';

void main() {
  group(
    'isDueTodayOrEarlierUtc: календарная дата ≤ конец сегодняшнего дня UTC',
    () {
      final DateTime nowUtc = DateTime.utc(2026, 10, 2, 15, 30);

      test('вчера — настала, сегодня — настала, завтра — нет', () {
        expect(
          isDueTodayOrEarlierUtc(DateTime.utc(2026, 10, 1), nowUtc),
          isTrue,
        );
        expect(
          isDueTodayOrEarlierUtc(DateTime.utc(2026, 10, 2), nowUtc),
          isTrue,
        );
        expect(
          isDueTodayOrEarlierUtc(DateTime.utc(2026, 10, 3), nowUtc),
          isFalse,
        );
      });

      test('поздний вечер: дата сегодняшнего дня всё ещё не в будущем', () {
        final DateTime lateEvening = DateTime.utc(2026, 10, 2, 23, 59, 59, 500);
        expect(
          isDueTodayOrEarlierUtc(DateTime.utc(2026, 10, 2), lateEvening),
          isTrue,
        );
        expect(
          isDueTodayOrEarlierUtc(DateTime.utc(2026, 10, 3), lateEvening),
          isFalse,
        );
      });
    },
  );

  group('isDebtOverdue: просрочка срока долга календарными датами в UTC', () {
    final DateTime nowUtc = DateTime.utc(2026, 10, 2, 15, 30);

    Debt debtWithDue(String? iso) => Debt.fromJson(<String, Object?>{
      'id': 'debt-1',
      'person': 'Аня',
      'direction': 'they_owe_me',
      'amountMinor': 100000,
      'extraMinor': 0,
      'currencyCode': 'RUB',
      'dueDate': iso,
      'note': null,
      'deletedAt': null,
      'createdAt': DateTime.utc(2026, 9, 1),
      'updatedAt': DateTime.utc(2026, 9, 1),
    });

    test('обязательный край D-102: «сегодня» не красная, «вчера» красная', () {
      expect(
        isDebtOverdue(debtWithDue('2026-10-02T00:00:00.000Z'), nowUtc),
        isFalse,
        reason: 'срок «сегодня» — не просрочен весь сегодняшний день UTC',
      );
      expect(
        isDebtOverdue(debtWithDue('2026-10-01T00:00:00.000Z'), nowUtc),
        isTrue,
      );
      expect(
        isDebtOverdue(debtWithDue('2026-10-03T00:00:00.000Z'), nowUtc),
        isFalse,
      );
    });

    test('без срока или с битой строкой просрочки нет (терпимость схемы)', () {
      expect(isDebtOverdue(debtWithDue(null), nowUtc), isFalse);
      expect(isDebtOverdue(debtWithDue(''), nowUtc), isFalse);
      expect(isDebtOverdue(debtWithDue('не дата'), nowUtc), isFalse);
    });
  });

  group('dueDateOf: единственный парсер срока долга (дедупликация D-102)', () {
    Debt debtWithDue(String? iso) => Debt.fromJson(<String, Object?>{
      'id': 'debt-1',
      'person': 'Аня',
      'direction': 'they_owe_me',
      'amountMinor': 100000,
      'extraMinor': 0,
      'currencyCode': 'RUB',
      'dueDate': iso,
      'note': null,
      'deletedAt': null,
      'createdAt': DateTime.utc(2026, 9, 1),
      'updatedAt': DateTime.utc(2026, 9, 1),
    });

    final Debt debt = debtWithDue('2026-11-01T00:00:00.000Z');

    test('UTC-строка парсится, показ — локальная зона', () {
      expect(
        dueDateOf(debt),
        DateTime.parse('2026-11-01T00:00:00.000Z').toLocal(),
      );
    });

    test('пустая и битая строка — срока нет', () {
      expect(dueDateOf(debtWithDue('')), isNull);
      expect(dueDateOf(debtWithDue('мусор')), isNull);
      expect(dueDateOf(debtWithDue(null)), isNull);
    });
  });
}
