import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/category_icons.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/money_format.dart';
import 'package:kopilka/core/money_parse.dart' show defaultCurrencyExponent;
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/planning/plan_form_dialog.dart';
import 'package:kopilka/features/planning/planning_controller.dart';
import 'package:kopilka/features/planning/scheduled_transfers_controller.dart';
import 'package:kopilka/features/transactions/transaction_form_dialog.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/features/transactions/transactions_screen.dart'
    show transferLine;
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Планирование» (спека C §1/§2/§7, D-127): список всех живых
/// планов с фактом за собственный период каждого (окно 2000–2100 —
/// [planningListFrom]/[planningListTo]), две секции по направлению вида
/// категории (D-115.а), сводной суммы нет — планы на разные периоды в
/// одну сумму не складываются. FAB — форма плана, IconButton в AppBar —
/// автобюджет (виден всегда, в том числе в пустом разделе, D-54.17).
class PlanningScreen extends ConsumerWidget {
  const PlanningScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<List<PlanVsFact>> plans = ref.watch(planningProvider);
    // Отложенные переводы — свой поток; их состояния — общие состояния
    // экрана (спека D §4/§6): спиннер и ErrorState с retry, отдельной
    // секционной ошибки нет.
    final AsyncValue<List<ScheduledTransfer>> transfers = ref.watch(
      scheduledTransfersProvider,
    );

    Widget emptyState() => EmptyState(
      text: l10n.planningEmpty,
      ctaLabel: l10n.planningEmptyCta,
      onCta: () => showPlanFormDialog(context),
    );

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        // Уникальный hero-тег (M6-шаг D): FAB веток шелла живут в одном
        // поддереве корневого навигатора.
        heroTag: 'planning-fab',
        tooltip: l10n.planningAddTooltip,
        onPressed: () => showPlanFormDialog(context),
        child: const Icon(Icons.add),
      ),
      body: plans.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) =>
            ErrorState(onRetry: () => ref.invalidate(planningProvider)),
        data: (List<PlanVsFact> rows) {
          final List<ScheduledTransfer>? deferred = transfers.value;
          if (deferred == null) {
            // До первой выдачи — спиннер; ошибка без выдачи — ErrorState
            // с retry потока (общее состояние раздела, спека D §4).
            return transfers.hasError
                ? ErrorState(
                    onRetry: () => ref.invalidate(scheduledTransfersProvider),
                  )
                : const Center(child: CircularProgressIndicator());
          }
          final List<ScheduledTransfer> pending = <ScheduledTransfer>[
            for (final ScheduledTransfer row in deferred)
              if (row.executedAt == null) row,
          ];
          final List<ScheduledTransfer> executed = <ScheduledTransfer>[
            for (final ScheduledTransfer row in deferred)
              if (row.executedAt != null) row,
          ];
          final bool hasTransfers = pending.isNotEmpty || executed.isNotEmpty;

          final Map<String, Category> categories = <String, Category>{
            for (final Category category
                in ref.watch(allCategoriesProvider).value ?? const <Category>[])
              category.id: category,
          };
          // Строка без живой категории не показывается (JOIN-отсев D-122.в;
          // races потока категорий — та же семантика, появится следующей
          // выдачей).
          final List<PlanVsFact> visible = <PlanVsFact>[
            for (final PlanVsFact row in rows)
              if (categories.containsKey(row.plan.categoryId)) row,
          ];
          if (visible.isEmpty) {
            // Пустое состояние раздела остаётся про планы; секция
            // отложенных при своих строках рисуется рядом (спека D §4).
            if (!hasTransfers) {
              return emptyState();
            }
            return ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: <Widget>[
                emptyState(),
                _TransfersSection(pending: pending, executed: executed),
              ],
            );
          }
          final List<PlanVsFact> expense = <PlanVsFact>[];
          final List<PlanVsFact> income = <PlanVsFact>[];
          for (final PlanVsFact row in visible) {
            final Category category = categories[row.plan.categoryId]!;
            (CategoryKind.fromDb(category.kind) == CategoryKind.income
                    ? income
                    : expense)
                .add(row);
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: <Widget>[
              if (expense.isNotEmpty)
                _PlanningSection(
                  header: l10n.planningSectionExpense,
                  rows: expense,
                  categories: categories,
                ),
              if (income.isNotEmpty)
                _PlanningSection(
                  header: l10n.planningSectionIncome,
                  rows: income,
                  categories: categories,
                ),
              if (hasTransfers)
                _TransfersSection(pending: pending, executed: executed),
            ],
          );
        },
      ),
    );
  }
}

/// Секция направления (спека C §2): неизменный заголовок, порядок — DAO
/// (по началу периода, ранние сверху). Пустая секция не рисуется.
class _PlanningSection extends StatelessWidget {
  const _PlanningSection({
    required this.header,
    required this.rows,
    required this.categories,
  });

  final String header;
  final List<PlanVsFact> rows;
  final Map<String, Category> categories;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(header, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final PlanVsFact row in rows) ...<Widget>[
          _PlanningTile(row: row, category: categories[row.plan.categoryId]!),
          const Divider(height: 1),
        ],
      ],
    );
  }
}

/// Строка плана (спека C §2): иконка и имя категории с бейджем «Идёт»,
/// включительный период локальными датами, прогресс по [PlanVsFact.ratio],
/// план/факт/остаток; перерасход — красным и 100% заливки, достигнутая
/// цель доходного плана — «Цель достигнута: +N». Завершённые планы —
/// приглушены (opacity 0.6): это выполненный/не выполненный план, а не
/// ошибка. Тап — форма, долгий тап — подтверждение удаления.
class _PlanningTile extends ConsumerWidget {
  const _PlanningTile({required this.row, required this.category});

  final PlanVsFact row;
  final Category category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final Currency? base = ref.watch(baseCurrencyStreamProvider).value;
    final int exponent = base == null
        ? defaultCurrencyExponent
        : currencyExponentByCode(base.code);
    final String symbol = base?.symbol ?? '';
    String money(int minor) => base == null
        ? '…'
        : formatMoneyMinor(
            minor,
            symbol: symbol,
            locale: locale,
            exponent: exponent,
          );

    final bool isIncome =
        CategoryKind.fromDb(category.kind) == CategoryKind.income;
    final DateTime now = utcNow();
    final DateTime start = DateTime.parse(row.plan.periodStart).toUtc();
    final DateTime end = DateTime.parse(row.plan.periodEnd).toUtc();
    // Период показывается как введённый — включительно (спека C §2/§3);
    // хранение — полуинтервал [start, end).
    final String periodLine = l10n.planningPeriodRange(
      DateFormat.yMd(locale).format(start.toLocal()),
      DateFormat.yMd(locale)
          .format(end.subtract(const Duration(days: 1)).toLocal()),
    );
    final bool active = !start.isAfter(now) && now.isBefore(end);
    final bool finished = !end.isAfter(now);
    final bool over = !isIncome && row.factMinor > row.amountMinor;
    final bool goalReached = isIncome && row.factMinor >= row.amountMinor;

    // Больше 100% не показываем: превышение видно по цвету и тексту
    // (образец бюджета).
    final double percent = row.ratio.clamp(0.0, 1.0);
    final Color barColor = over
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final String remainingLine = over
        ? l10n.planningOverByLine(money(row.factMinor - row.amountMinor))
        : goalReached
        ? l10n.planningGoalReachedLine(money(row.factMinor - row.amountMinor))
        : l10n.planningRemainingLine(money(row.remainingMinor));

    return Opacity(
      // Завершённые планы приглушены, числа остаются (спека C §2).
      opacity: finished ? 0.6 : 1.0,
      child: InkWell(
        onTap: () => showPlanFormDialog(context, existing: row),
        onLongPress: () => _confirmDelete(context, ref, l10n),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    categoryIconFor(category.iconCode).icon,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      row.categoryName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (active)
                    Text(
                      l10n.planningActiveBadge,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                periodLine,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(l10n.planningPlanLine(money(row.amountMinor))),
              Text(l10n.planningFactLine(money(row.factMinor))),
              Text(
                remainingLine,
                style: over ? TextStyle(color: theme.colorScheme.error) : null,
              ),
              const SizedBox(height: 4),
              // Прогресс по доле исполнения; перерасход — цвет ошибки и
              // 100% заливки (образец бюджета, спека C §2).
              LinearProgressIndicator(
                value: over || goalReached ? 1.0 : percent,
                color: barColor,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
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
      title: l10n.planningDeleteTitle,
      body: l10n.planningDeleteBody(row.categoryName),
    );
    if (!confirmed) {
      return;
    }
    // После soft delete строка исчезает из потока; снек не нужен
    // (образец бюджетов, спека C §3).
    await ref.read(planningControllerProvider.notifier).deletePlan(row.plan.id);
  }
}

/// Секция «Отложенные переводы» (спека D §4): под секциями планов, две
/// подсекции по статусам — «Ожидают»/«Исполнены»; пустая подсекция не
/// рисуется. Строка: суммы «списание → зачисление» (одна сумма у
/// одно-валютного), имена счетов хелпером `transferLine`, дата
/// исполнения (medium) и комиссия. Действия только у ожидающих: тап —
/// форма перевода в режиме правки, долгий тап — подтверждение удаления;
/// исполненные — без действий (спека D §4).
class _TransfersSection extends ConsumerWidget {
  const _TransfersSection({required this.pending, required this.executed});

  final List<ScheduledTransfer> pending;
  final List<ScheduledTransfer> executed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final Map<String, Account> accounts = <String, Account>{
      for (final Account account
          in ref.watch(accountsProvider).value ?? const <Account>[])
        account.id: account,
    };
    final Map<String, Currency> currencies =
        ref.watch(currenciesMapProvider).value ?? const <String, Currency>{};

    Widget subsection(
      String header,
      List<ScheduledTransfer> rows, {
      required bool interactive,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
          child: Text(
            header,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final ScheduledTransfer row in rows)
          _ScheduledTransferTile(
            row: row,
            accounts: accounts,
            currencies: currencies,
            interactive: interactive,
          ),
        const Divider(height: 1),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            l10n.planningTransfersSection,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (pending.isNotEmpty)
          subsection(
            l10n.planningTransfersPendingSection,
            pending,
            interactive: true,
          ),
        if (executed.isNotEmpty)
          subsection(
            l10n.planningTransfersExecutedSection,
            executed,
            interactive: false,
          ),
      ],
    );
  }
}

/// Строка отложенного перевода (спека D §4): суммы в валютах счетов
/// (символы и экспоненты — по справочнику, образец `_symbolOf`), имена
/// счетов, дата исполнения и комиссия. [interactive] — только у строки,
/// ожидающей исполнения: тап — правка, долгий тап — удаление.
class _ScheduledTransferTile extends ConsumerWidget {
  const _ScheduledTransferTile({
    required this.row,
    required this.accounts,
    required this.currencies,
    required this.interactive,
  });

  final ScheduledTransfer row;
  final Map<String, Account> accounts;
  final Map<String, Currency> currencies;
  final bool interactive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final Account? from = accounts[row.accountId];
    final Account? to = accounts[row.targetAccountId];
    String money(int minor, String? code) => formatMoneyMinor(
      minor,
      symbol: currencies[code]?.symbol ?? (code ?? ''),
      locale: locale,
      exponent: currencyExponentByCode(code ?? ''),
    );

    // У мультивалютного — обе суммы со стрелкой, у одно-валютного — одна
    // (спека D §4). Счёт удалён (исполненная строка) — без символа валюты.
    final bool multiCurrency =
        from != null && to != null && from.currencyCode != to.currencyCode;
    final String amounts = multiCurrency
        ? '${money(row.amountMinor, from.currencyCode)} → '
              '${money(row.targetAmountMinor ?? row.amountMinor, to.currencyCode)}'
        : money(row.amountMinor, from?.currencyCode);
    final DateTime executeAt = DateTime.parse(row.executeAt).toUtc();
    final int? commission = row.commissionMinor;

    return InkWell(
      onTap: interactive
          ? () => showTransactionFormDialog(
              context,
              type: TransactionType.transfer,
              existing: row,
            )
          : null,
      onLongPress: interactive
          ? () => _confirmDelete(context, ref, l10n)
          : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(amounts, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(
              transferLine(
                from?.name ?? l10n.transactionTileAccountGone,
                to?.name,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              MaterialLocalizations.of(context).formatMediumDate(executeAt),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (commission != null)
              Text(
                l10n.transferCommissionLine(
                  money(commission, from?.currencyCode),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
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
      title: l10n.planningTransfersDeleteTitle,
      body: l10n.planningTransfersDeleteBody,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    // Подтверждение — soft delete: строка уходит из потока (D-115.г);
    // отказ (гонка с исполнением) — снеком по виду (спека D §4).
    final Result<void> result = await ref
        .read(scheduledTransfersControllerProvider.notifier)
        .deleteScheduledTransfer(row.id);
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}
