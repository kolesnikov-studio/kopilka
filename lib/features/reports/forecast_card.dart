// Карточка прогноза баланса на дашборде (M7-шаг D, D-117/спека D §1):
// секция под `_BalanceCard`, выше переключателя месяца — прогноз не
// зависит от выбора месяца. Состав: линия от точки «сейчас» (текущий
// баланс) по 5 точек окон 1/3/6/9/12, подпись значения у каждой точки,
// ось X — краткое имя месяца по локали (год — если точка не в текущем),
// иконка info с тултипом `forecastHint`.
//
// Состояния (спека D §1): загрузка/ошибка — карточка не рисуется
// (прецедент insight-карточек M6, ErrorState/retry не заводим); «нет
// данных» (история пуста и планов нет) — плоская линия уровня текущего
// баланса + подпись forecastNoData, в том числе на свежей установке.
//
// Рендер линии — собственный painter: точки стоят в равных ячейках
// ширины, центры ячеек совпадают с центрами подписных рядов — привязка
// подписей к точкам точная и не зависит от резервов осей fl_chart.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/forecast.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/money_format.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/forecast/forecast_providers.dart';
import 'package:kopilka/features/reports/reports_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Карточка прогноза баланса (спека D §1): линза просмотра без хранения —
/// пересчёт приходит новой выдачей [forecastProvider] (D-117).
class ForecastCard extends ConsumerWidget {
  const ForecastCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String locale = Localizations.localeOf(context).toString();

    // Загрузка/ошибка — не рисуется: при пересчёте Riverpod сохраняет
    // прошлые данные (миганий нет), линза пересоберётся на следующем
    // изменении источников.
    final List<ForecastPoint>? points = ref.watch(forecastProvider).value;
    final int? balance = ref.watch(totalBalanceProvider).value;
    if (points == null || balance == null) {
      return const SizedBox.shrink();
    }

    // «Нет данных» — UI-признак из тех же потоков (спека D §1): история
    // пуста и планов нет — линия плоская (механика D-117) + подпись.
    final bool noData =
        (ref.watch(forecastHistoryProvider).value?.isEmpty ?? true) &&
        (ref.watch(forecastPlansProvider).value?.isEmpty ?? true);

    // Валюта — базовая (D-27); пометка «по текущему курсу» не дублируется
    // — она уже на `_BalanceCard` выше.
    final Currency? base = ref.watch(baseCurrencyStreamProvider).value;
    String money(int minor) => base == null
        ? '…' // до загрузки справочника — как на карточке баланса
        : formatMoneyMinor(
            minor,
            symbol: base.symbol,
            locale: locale,
            exponent: currencyExponentByCode(base.code),
          );

    // Точка «сейчас» (текущий баланс, читает _BalanceCard) + 5 точек окон;
    // месяц оси точки «сейчас» — текущий календарный.
    final DateTime now = monthStart(utcNow());
    final List<int> values = <int>[
      balance,
      for (final ForecastPoint point in points) point.balanceMinor,
    ];
    final List<DateTime> months = <DateTime>[
      now,
      for (final ForecastPoint point in points) monthStart(point.month),
    ];
    String monthLabel(DateTime month) {
      final String short = reportsMonthShortLabel(month, locale);
      // Год добавляется, только когда точка не в текущем году.
      return month.year == now.year ? short : '$short ${month.year}';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.forecastCardTitle,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                // Тапов/тултипов по точкам нет; механика — одним строковым
                // тултипом иконки info (спека D §1).
                IconButton(
                  onPressed: () {},
                  tooltip: l10n.forecastHint,
                  iconSize: 20,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.info_outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 110,
              child: CustomPaint(
                painter: _ForecastLinePainter(values: values, color: theme.colorScheme.primary),
              ),
            ),
            // Подписи значений в тех же ячейках, что и точки линии;
            // узкий экран — сжатие FittedBox (разрешённое спекой
            // «сокращение» — только размером шрифта, без обрезки).
            Row(
              children: <Widget>[
                for (final int value in values)
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          money(value),
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                for (final DateTime month in months)
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          monthLabel(month),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (noData) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                l10n.forecastNoData,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Линия прогноза: точки в равных ячейках ширины, значения растянуты по
/// min/max с запасом (плоская линия не вырождается в нулевую высоту).
class _ForecastLinePainter extends CustomPainter {
  const _ForecastLinePainter({required this.values, required this.color});

  final List<int> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.isEmpty) {
      return;
    }
    final int minValue = values.reduce((int a, int b) => a < b ? a : b);
    final int maxValue = values.reduce((int a, int b) => a > b ? a : b);
    final double range = (maxValue - minValue).toDouble();
    final double pad = range > 0
        ? range * 0.15
        : math.max(maxValue.abs() * 0.1, 1.0);
    final double minY = minValue - pad;
    final double maxY = maxValue + pad;
    double x(int index) => size.width * (index + 0.5) / values.length;
    double y(int value) =>
        size.height * (1 - (value - minY) / (maxY - minY));

    final Path path = Path();
    for (int i = 0; i < values.length; i++) {
      final Offset point = Offset(x(i), y(values[i]));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    final Paint dot = Paint()..color = color;
    for (int i = 0; i < values.length; i++) {
      canvas.drawCircle(Offset(x(i), y(values[i])), 3.5, dot);
    }
  }

  @override
  bool shouldRepaint(_ForecastLinePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.values.length != values.length ||
      !List<int>.generate(
        values.length,
        (int i) => values[i] == oldDelegate.values[i] ? 1 : 0,
      ).every((int flag) => flag == 1);
}
