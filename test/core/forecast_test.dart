// Тесты чистого ядра прогноза (M7-шаг B, D-117): окна 1/3/6/9/12,
// короткая и пустая история, распределение плана по дням пересечения,
// half-up (D-22), знаки «доход + / расход −», окно «с первой операции».
// Drift и системное время не используются: now — параметр функции.
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/forecast.dart';

void main() {
  ForecastHistoryEntry expense(String categoryId, DateTime month, int minor) =>
      ForecastHistoryEntry(
        categoryId: categoryId,
        month: month,
        isIncome: false,
        amountMinor: minor,
      );

  ForecastHistoryEntry income(String categoryId, DateTime month, int minor) =>
      ForecastHistoryEntry(
        categoryId: categoryId,
        month: month,
        isIncome: true,
        amountMinor: minor,
      );

  group('окна и среднее нетто (D-117)', () {
    test('окно — последние 6 полных месяцев; доход +, расход −; точки '
        'на 1/3/6/9/12 месяцев', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 100000,
        history: <ForecastHistoryEntry>[
          for (int month = 4; month <= 9; month++)
            expense('food', DateTime.utc(2026, month, 1), 1000),
          income('salary', DateTime.utc(2026, 9, 1), 5000),
        ],
        plans: const <ForecastPlan>[],
      );

      // Еда: −6000 / 6 = −1000; зарплата: +5000 / 6 = 833,33 → 833 (half-up);
      // нетто месяца = −167.
      expect(points.map((ForecastPoint p) => p.month).toList(), <DateTime>[
        DateTime.utc(2026, 11, 1),
        DateTime.utc(2027, 1, 1),
        DateTime.utc(2027, 4, 1),
        DateTime.utc(2027, 7, 1),
        DateTime.utc(2027, 10, 1),
      ]);
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        99833,
        99499,
        98998,
        98497,
        97996,
      ]);
    });

    test('короткая история: окно — с первой операции, число месяцев меньше '
        'шести', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 10000,
        history: <ForecastHistoryEntry>[
          expense('food', DateTime.utc(2026, 8, 1), 300),
          expense('food', DateTime.utc(2026, 9, 1), 600),
        ],
        plans: const <ForecastPlan>[],
      );

      // Окно — август и сентябрь (2 месяца): среднее −450.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        9550,
        8650,
        7300,
        5950,
        4600,
      ]);
    });

    test('пустая история и планы — линия плоская: все точки равны балансу', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 5555,
        history: const <ForecastHistoryEntry>[],
        plans: const <ForecastPlan>[],
      );

      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        5555,
        5555,
        5555,
        5555,
        5555,
      ]);
      expect(points, hasLength(5));
    });

    test('знаки: доход идёт в плюс, расход в минус, чужая история — 0', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 1000,
        history: <ForecastHistoryEntry>[
          income('salary', DateTime.utc(2026, 9, 1), 1000),
          expense('food', DateTime.utc(2026, 9, 1), 300),
        ],
        plans: const <ForecastPlan>[],
      );

      // Окно — только сентябрь: средние +1000 и −300, нетто +700.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        1700,
        3100,
        5200,
        7300,
        9400,
      ]);
    });

    test('текущий неполный и будущие месяцы в окно не входят', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 1000,
        history: <ForecastHistoryEntry>[
          expense('food', DateTime.utc(2026, 9, 1), 100),
          expense('food', DateTime.utc(2026, 10, 2), 9999),
          income('salary', DateTime.utc(2026, 11, 1), 5000),
        ],
        plans: const <ForecastPlan>[],
      );

      // История — только сентябрь: среднее −100; октябрь и ноябрь — не окно.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        900,
        700,
        400,
        100,
        -200,
      ]);
    });

    test('среднее округляется half-up (10 / 4 = 2,5 → 3)', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 11, 15),
        currentBalanceMinor: 0,
        history: <ForecastHistoryEntry>[
          income('salary', DateTime.utc(2026, 7, 1), 10),
        ],
        plans: const <ForecastPlan>[],
      );

      // Окно — июль..октябрь (4 месяца): +10/4 = 2,5 → 3.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        3,
        9,
        18,
        27,
        36,
      ]);
    });
  });

  group('планы: распределение по дням пересечения (D-117)', () {
    test(
      'план на месяцы заменяет среднее категории только в своих месяцах',
      () {
        final List<ForecastPoint> points = forecastBalance(
          now: DateTime.utc(2026, 10, 15),
          currentBalanceMinor: 0,
          history: <ForecastHistoryEntry>[
            expense('food', DateTime.utc(2026, 8, 1), 3100),
          ],
          plans: <ForecastPlan>[
            ForecastPlan(
              categoryId: 'food',
              isIncome: false,
              periodStart: DateTime.utc(2026, 11, 15),
              periodEnd: DateTime.utc(2026, 12, 15),
              amountMinor: 3100,
            ),
          ],
        );

        // Среднее — −3100 / 2 = −1550. План 30 дней: ноябрь 16 дней →
        // 1653,33 → 1653; декабрь 14 дней → 1446,67 → 1447; январь и далее —
        // снова среднее (−1550).
        expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
          -1653,
          -4650,
          -9300,
          -13950,
          -18600,
        ]);
      },
    );

    test('доля плана округляется half-up по модулю (5 × 1 / 2 = 2,5 → 3)', () {
      final List<ForecastPoint> points = forecastBalance(
        // now — декабрь: план целиком в будущем.
        now: DateTime.utc(2026, 12, 15),
        currentBalanceMinor: 0,
        history: const <ForecastHistoryEntry>[],
        plans: <ForecastPlan>[
          ForecastPlan(
            categoryId: 'bonus',
            isIncome: true,
            periodStart: DateTime.utc(2027, 1, 31),
            periodEnd: DateTime.utc(2027, 2, 2),
            amountMinor: 5,
          ),
        ],
      );

      // План 2 дня: январь — 1 день (+3), февраль — 1 день (+3), далее 0.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        3,
        6,
        6,
        6,
        6,
      ]);
    });

    test('план доходной категории идёт в плюс, расходной — в минус', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 0,
        history: const <ForecastHistoryEntry>[],
        plans: <ForecastPlan>[
          ForecastPlan(
            categoryId: 'salary',
            isIncome: true,
            periodStart: DateTime.utc(2026, 11, 1),
            periodEnd: DateTime.utc(2026, 12, 1),
            amountMinor: 1000,
          ),
          ForecastPlan(
            categoryId: 'food',
            isIncome: false,
            periodStart: DateTime.utc(2026, 11, 1),
            periodEnd: DateTime.utc(2026, 12, 1),
            amountMinor: 400,
          ),
        ],
      );

      // Ноябрь: +1000 − 400 = +600; далее план не пересекает месяцы.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        600,
        600,
        600,
        600,
        600,
      ]);
    });

    test('завершившийся план не влияет; без плана и истории — 0', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 700,
        history: const <ForecastHistoryEntry>[],
        plans: <ForecastPlan>[
          ForecastPlan(
            categoryId: 'food',
            isIncome: false,
            periodStart: DateTime.utc(2026, 8, 1),
            periodEnd: DateTime.utc(2026, 9, 1),
            amountMinor: 12345,
          ),
        ],
      );

      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        700,
        700,
        700,
        700,
        700,
      ]);
    });

    test('несколько непересекающихся планов одной категории делят месяцы', () {
      final List<ForecastPoint> points = forecastBalance(
        now: DateTime.utc(2026, 10, 15),
        currentBalanceMinor: 0,
        history: const <ForecastHistoryEntry>[],
        plans: <ForecastPlan>[
          ForecastPlan(
            categoryId: 'food',
            isIncome: false,
            periodStart: DateTime.utc(2026, 11, 1),
            periodEnd: DateTime.utc(2026, 12, 1),
            amountMinor: 300,
          ),
          ForecastPlan(
            categoryId: 'food',
            isIncome: false,
            periodStart: DateTime.utc(2026, 12, 1),
            periodEnd: DateTime.utc(2027, 1, 1),
            amountMinor: 500,
          ),
        ],
      );

      // Ноябрь −300, декабрь −500, далее 0.
      expect(points.map((ForecastPoint p) => p.balanceMinor).toList(), <int>[
        -300,
        -800,
        -800,
        -800,
        -800,
      ]);
    });
  });
}
