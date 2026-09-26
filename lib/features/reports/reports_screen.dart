import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/features/budgets/budget_form_dialog.dart';
import 'package:kopilka/features/budgets/budgets_controller.dart';
import 'package:kopilka/features/reports/reports_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Отчёты» (M2): общий баланс, расходы по категориям за выбранный
/// месяц с донат-диаграммой, динамика доход/расход за полгода.
///
/// Все данные — живые потоки DAO через [ReportsController]; месяц выбирается
/// стрелками, без ограничения прошлым или будущим.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);

    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _BalanceCard(),
            const SizedBox(height: 12),
            const _MonthSwitcher(),
            const SizedBox(height: 12),
            _CategoryBreakdownCard(
              title: l10n.reportsCategoryBreakdownTitle,
              emptyText: l10n.reportsCategoryBreakdownEmpty,
            ),
            const SizedBox(height: 12),
            const _MonthDynamicsCard(),
            const SizedBox(height: 12),
            _BudgetsCard(
              title: l10n.budgetsTitle,
              emptyText: l10n.budgetsEmpty,
            ),
          ],
        ),
      ),
    );
  }
}

/// Карточка суммарного баланса всех счетов.
class _BalanceCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final String symbol = ref.watch(baseCurrencySymbolProvider).value ?? '';
    final int? balance = ref.watch(totalBalanceProvider).value;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              l10n.reportsTotalBalance,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              balance == null
                  ? '…'
                  : formatMoneyMinor(balance, symbol: symbol, locale: locale),
              style: theme.textTheme.headlineMedium,
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка-переключатель месяца: стрелки и заголовок «сентябрь 2026 г.».
class _MonthSwitcher extends ConsumerWidget {
  const _MonthSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime moment = ref.watch(reportsMonthProvider);
    final String locale = Localizations.localeOf(context).toString();

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        IconButton(
          tooltip: MaterialLocalizations.of(context).previousMonthTooltip,
          onPressed: () =>
              ref.read(reportsMonthProvider.notifier).shiftMonths(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        const SizedBox(width: 8),
        Text(
          reportsMonthLabel(moment, locale),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: MaterialLocalizations.of(context).nextMonthTooltip,
          onPressed: () =>
              ref.read(reportsMonthProvider.notifier).shiftMonths(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// Карточка «Расходы по категориям»: донат-диаграмма слева, легенда-список
/// справа с долями и суммами. Под диаграммой — строка суммы месяца.
class _CategoryBreakdownCard extends ConsumerWidget {
  const _CategoryBreakdownCard({
    required this.title,
    required this.emptyText,
  });

  final String title;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final String symbol = ref.watch(baseCurrencySymbolProvider).value ?? '';
    final AsyncValue<List<CategoryExpense>> expenses =
        ref.watch(expensesByCategoryProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            expenses.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace stack) => Center(
                child: Text(l10n.errorUnknown),
              ),
              data: (List<CategoryExpense> rows) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text(emptyText)),
                  );
                }
                final int total =
                    rows.fold<int>(0, (int s, CategoryExpense r) => s + r.amountMinor);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _CategoryDonut(rows: rows),
                    const SizedBox(height: 12),
                    Text(
                      '${l10n.reportsTotalLabel}: '
                      '${formatMoneyMinor(total, symbol: symbol, locale: locale)}',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    ...<Widget>[
                      for (final CategoryExpense row in rows)
                        _CategoryLegendTile(
                          row: row,
                          total: total,
                          symbol: symbol,
                          locale: locale,
                        ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Отдельные цвета секторов доната: оттенки по кругу, чтобы соседние
/// категории не сливались. Палитра Material — primary/tertiary + оттенки.
Color categoryChartColor(ColorScheme colors, int index) {
  final List<Color Function(Color)> palette = <Color Function(Color)>[
    _shade(.0),
    _shade(-.25),
    _shade(.35),
    _shade(-.5),
    _shade(.6),
    _shade(-.15),
  ];
  final Color base = index.isEven ? colors.primary : colors.tertiary;
  return palette[index % palette.length](base);
}

Color Function(Color) _shade(double amount) =>
    (Color color) => Color.lerp(color, amount >= 0 ? Colors.white : Colors.black, amount.abs())!;

/// Донат-диаграмма расходов по категориям. Сектора в порядке списка DAO —
/// от большей суммы к меньшей; цвета назначаются палитрой по индексу.
class _CategoryDonut extends StatelessWidget {
  const _CategoryDonut({required this.rows});

  final List<CategoryExpense> rows;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int total =
        rows.fold<int>(0, (int s, CategoryExpense r) => s + r.amountMinor);
    final ColorScheme colors = theme.colorScheme;

    return SizedBox(
      height: 180,
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: PieChart(
              PieChartData(
                sectionsSpace: 2,
                centerSpaceRadius: 44,
                startDegreeOffset: -90,
                sections: <PieChartSectionData>[
                  for (final (int index, CategoryExpense row)
                      in rows.indexed)
                    PieChartSectionData(
                      value: row.amountMinor.toDouble(),
                      color: categoryChartColor(colors, index),
                      radius: 40,
                      title: total <= 0
                          ? null
                          : '${(row.amountMinor * 100 / total).round()}%',
                      titleStyle: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onPrimary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final (int index, CategoryExpense row) in rows.indexed)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: categoryChartColor(colors, index),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            row.categoryName,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка легенды: имя категории, доля и сумма.
class _CategoryLegendTile extends StatelessWidget {
  const _CategoryLegendTile({
    required this.row,
    required this.total,
    required this.symbol,
    required this.locale,
  });

  final CategoryExpense row;
  final int total;
  final String symbol;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String share =
        total <= 0 ? '' : '${(row.amountMinor * 100 / total).round()}%';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(row.categoryName, overflow: TextOverflow.ellipsis),
          ),
          Text(
            share,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: Text(
              formatMoneyMinor(row.amountMinor, symbol: symbol, locale: locale),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

/// Карточка динамики: столбцы доход/расход по месяцам, выбранный —
/// последний. Месяцы без операций показываются нулевыми столбцами.
class _MonthDynamicsCard extends ConsumerWidget {
  const _MonthDynamicsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final String symbol = ref.watch(baseCurrencySymbolProvider).value ?? '';
    final AsyncValue<List<MonthTotals>> totals =
        ref.watch(monthTotalsProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(l10n.reportsMonthDynamicsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            totals.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace stack) =>
                  Center(child: Text(l10n.errorUnknown)),
              data: (List<MonthTotals> rows) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _MonthBars(rows: rows, locale: locale),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        _LegendDot(
                          color: Theme.of(context).colorScheme.primary,
                          label: l10n.filterIncomes,
                        ),
                        const SizedBox(width: 16),
                        _LegendDot(
                          color: Theme.of(context).colorScheme.tertiary,
                          label: l10n.filterExpenses,
                        ),
                        const Spacer(),
                        Text(
                          symbol,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Столбчатая диаграмма доход/расход по месяцам из живого потока DAO.
class _MonthBars extends StatelessWidget {
  const _MonthBars({required this.rows, required this.locale});

  final List<MonthTotals> rows;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return SizedBox(
      height: 180,
      child: BarChart(
        BarChartData(
          maxY: _maxY(rows),
          barTouchData: const BarTouchData(enabled: false),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                getTitlesWidget: (double value, TitleMeta meta) {
                  final int index = value.toInt();
                  if (index < 0 || index >= rows.length) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      reportsMonthShortLabel(
                        DateTime.utc(
                          int.parse(rows[index].monthKey.substring(0, 4)),
                          int.parse(rows[index].monthKey.substring(5, 7)),
                        ),
                        locale,
                      ),
                      style: theme.textTheme.labelSmall,
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: <BarChartGroupData>[
            for (final (int index, MonthTotals row) in rows.indexed)
              BarChartGroupData(
                x: index,
                barRods: <BarChartRodData>[
                  BarChartRodData(
                    toY: row.incomeMinor.toDouble(),
                    color: colors.primary,
                    width: 12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  BarChartRodData(
                    toY: row.expenseMinor.toDouble(),
                    color: colors.tertiary,
                    width: 12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
                barsSpace: 4,
              ),
          ],
        ),
      ),
    );
  }

  double _maxY(List<MonthTotals> rows) {
    double max = 0;
    for (final MonthTotals row in rows) {
      if (row.incomeMinor > max) {
        max = row.incomeMinor.toDouble();
      }
      if (row.expenseMinor > max) {
        max = row.expenseMinor.toDouble();
      }
    }
    // +10% запаса сверху, чтобы столбцы не упирались в край.
    return max <= 0 ? 100 : max * 1.1;
  }
}

/// Точка легенды диаграммы.
class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// Карточка бюджетов месяца: прогресс-бары категорий, превышение выделяется
/// цветом ошибки. Создание — кнопкой в заголовке, правка — тапом, удаление
/// — долгим тапом.
class _BudgetsCard extends ConsumerWidget {
  const _BudgetsCard({required this.title, required this.emptyText});

  final String title;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final String symbol = ref.watch(baseCurrencySymbolProvider).value ?? '';
    final AsyncValue<List<BudgetProgress>> progress =
        ref.watch(budgetProgressProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                IconButton(
                  tooltip: l10n.budgetAdd,
                  onPressed: () => showBudgetFormDialog(context),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            progress.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace stack) =>
                  Center(child: Text(l10n.errorUnknown)),
              data: (List<BudgetProgress> rows) {
                if (rows.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text(emptyText)),
                  );
                }
                return Column(
                  children: <Widget>[
                    for (final BudgetProgress row in rows)
                      _BudgetTile(
                        row: row,
                        symbol: symbol,
                        locale: locale,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка бюджета: имя категории, «потрачено из лимита», прогресс-бар.
/// Превышение лимита — цвет ошибки и 100% заливки.
class _BudgetTile extends ConsumerWidget {
  const _BudgetTile({
    required this.row,
    required this.symbol,
    required this.locale,
  });

  final BudgetProgress row;
  final String symbol;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);

    // Больше 100% не показываем: превышение видно по цвету и тексту.
    final double percent = row.ratio.clamp(0.0, 1.0);
    final Color barColor = row.isOver
        ? theme.colorScheme.error
        : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: () => showBudgetFormDialog(context, existing: row),
        onLongPress: () => _confirmDelete(context, ref, l10n),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(row.categoryName, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    '${formatMoneyMinor(row.spentMinor, symbol: symbol, locale: locale)} / '
                    '${formatMoneyMinor(row.limitMinor, symbol: symbol, locale: locale)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: row.isOver
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: percent,
                  minHeight: 8,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.budgetDeleteTitle,
      body: l10n.budgetDeleteBody(row.categoryName),
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result = await ref
        .read(budgetsControllerProvider.notifier)
        .deleteBudget(row.budget.id);
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}
