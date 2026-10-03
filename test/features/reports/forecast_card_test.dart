// Виджет-замки карточки прогноза (M7-шаг D, P2-1 аудита, D-133):
// спека D-130 §1 — 5 точек окон 1/3/6/9/12 с подписями значений и месяцев,
// «нет данных» — плоская линия + подпись forecastNoData, загрузка/ошибка —
// карточка не рисуется (SizedBox.shrink).
//
// Харнесс точечный: карточка под ProviderScope с подменёнными провайдерами
// (D-117) — состояния loading/error в живом приложении мимолётны, замок
// требует их детерминированно. Механика прогноза (ядро D-117 и провайдеры)
// замкнута своими тестами (test/core/forecast_test.dart,
// test/features/forecast/forecast_providers_test.dart) — сюда подаётся
// фиксированная выдача.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/forecast.dart';
import 'package:kopilka/core/money_format.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/forecast/forecast_providers.dart';
import 'package:kopilka/features/reports/forecast_card.dart';
import 'package:kopilka/features/reports/reports_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Точка «сейчас» + 5 точек окон — значения и месяцы, как строит карточка.
const int _balance = 10000;

Currency _rub() {
  final DateTime stamp = DateTime.utc(2026, 1, 1);
  return Currency(
    code: 'RUB',
    symbol: '₽',
    isBase: true,
    rateToBase: 1,
    createdAt: stamp,
    updatedAt: stamp,
  );
}

String _money(int minor) =>
    formatMoneyMinor(minor, symbol: '₽', locale: 'ru', exponent: 2);

/// Подпись месяца, как в карточке: короткое имя + год вне текущего.
String _monthLabel(DateTime month, DateTime now) {
  final String short = reportsMonthShortLabel(month, 'ru');
  return month.year == now.year ? short : '$short ${month.year}';
}

List<ForecastPoint> _points(List<int> balances) {
  final DateTime now = monthStart(utcNow());
  return <ForecastPoint>[
    for (int i = 0; i < balances.length; i++)
      ForecastPoint(
        month: DateTime.utc(now.year, now.month + forecastWindows[i]),
        balanceMinor: balances[i],
      ),
  ];
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required Future<List<ForecastPoint>> Function() forecast,
  int balance = _balance,
  List<CategoryNetBase> history = const <CategoryNetBase>[],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        forecastProvider.overrideWith((ref) => forecast()),
        totalBalanceProvider.overrideWith((ref) => Stream<int>.value(balance)),
        forecastHistoryProvider.overrideWith((ref) => Stream.value(history)),
        forecastPlansProvider.overrideWith(
          (ref) => Stream<List<PlanVsFact>>.value(const <PlanVsFact>[]),
        ),
        baseCurrencyStreamProvider.overrideWith(
          (ref) => Stream<Currency>.value(_rub()),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: const Scaffold(body: ForecastCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<AppLocalizations> _l10n() =>
    AppLocalizations.delegate.load(const Locale('ru'));

void main() {
  testWidgets('D-133: загрузка — карточка не рисуется (SizedBox.shrink)', (
    WidgetTester tester,
  ) async {
    final AppLocalizations l10n = await _l10n();
    // Никогда не завершающийся расчёт — детерминированный loading.
    await _pumpCard(
      tester,
      forecast: () => Completer<List<ForecastPoint>>().future,
    );

    expect(find.byType(ForecastCard), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.text(l10n.forecastCardTitle), findsNothing);
  });

  testWidgets('D-133: ошибка расчёта — карточка не рисуется', (
    WidgetTester tester,
  ) async {
    final AppLocalizations l10n = await _l10n();
    await _pumpCard(
      tester,
      forecast: () =>
          Future<List<ForecastPoint>>.error(StateError('расчёт упал')),
    );

    expect(find.byType(ForecastCard), findsOneWidget);
    expect(find.byType(Card), findsNothing);
    expect(find.text(l10n.forecastCardTitle), findsNothing);
  });

  testWidgets(
    'D-133: «нет данных» — плоская линия уровня баланса, подпись forecastNoData',
    (WidgetTester tester) async {
      final AppLocalizations l10n = await _l10n();
      // История и планы пусты — механика D-117 даёт текущий баланс на всех
      // окнах: все 6 подписей значений равны, линия плоская.
      await _pumpCard(
        tester,
        forecast: () => Future.value(
          _points(const <int>[
            _balance,
            _balance,
            _balance,
            _balance,
            _balance,
          ]),
        ),
      );

      expect(find.text(l10n.forecastCardTitle), findsOneWidget);
      expect(find.text(l10n.forecastNoData), findsOneWidget);
      // Плоская линия: точка «сейчас» + 5 окон — одинаковые подписи.
      expect(find.text(_money(_balance)), findsNWidgets(6));
    },
  );

  testWidgets(
    'D-133: данные — точка «сейчас» + 5 точек окон с подписями значений и месяцев',
    (WidgetTester tester) async {
      final AppLocalizations l10n = await _l10n();
      await _pumpCard(
        tester,
        forecast: () =>
            Future.value(_points(const <int>[9500, 9000, 8500, 8000, 7500])),
        // История непуста — признак «нет данных» ложный.
        history: <CategoryNetBase>[
          const CategoryNetBase(
            categoryId: 'c1',
            categoryName: 'Еда',
            monthKey: '2026-09',
            type: TransactionType.expense,
            amountMinor: 5000,
          ),
        ],
      );

      expect(find.text(l10n.forecastCardTitle), findsOneWidget);
      expect(find.text(l10n.forecastNoData), findsNothing);

      // Подписи значений: «сейчас» + 5 окон — каждая ровно один раз.
      expect(find.text(_money(_balance)), findsOneWidget);
      for (final int value in const <int>[9500, 9000, 8500, 8000, 7500]) {
        expect(find.text(_money(value)), findsOneWidget);
      }

      // Подписи месяцев: текущий + окна 1/3/6/9/12 (год — вне текущего).
      final DateTime now = monthStart(utcNow());
      expect(find.text(_monthLabel(now, now)), findsOneWidget);
      for (final int window in forecastWindows) {
        expect(
          find.text(
            _monthLabel(DateTime.utc(now.year, now.month + window), now),
          ),
          findsOneWidget,
        );
      }
    },
  );
}
