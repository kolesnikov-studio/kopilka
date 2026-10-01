import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart' show DebtSummary;
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/debts/debt_form_dialog.dart';
import 'package:kopilka/features/debts/debts_controller.dart';
import 'package:kopilka/features/debts/debts_reminders.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Долги» (спека §1/§7): живой поток `watchAlive()`, две секции
/// they_owe_me/i_owe_them со сводками секций (мультивалютная строка),
/// MaterialBanner напоминаний (скрытие до конца сессии, без персиста
/// отказа, D-89). Конвенции состояний — `accounts_screen.dart`.
class DebtsScreen extends ConsumerWidget {
  const DebtsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<List<Debt>> debts = ref.watch(aliveDebtsProvider);

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.debtAddTooltip,
        onPressed: () => showDebtFormDialog(context),
        child: const Icon(Icons.add),
      ),
      body: debts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          // Поток DAO сам переподпишется при пересборке виджета.
          onRetry: () => ref.invalidate(aliveDebtsProvider),
        ),
        data: (List<Debt> rows) {
          final Widget list = rows.isEmpty
              ? EmptyState(
                  text: l10n.debtsEmpty,
                  ctaLabel: l10n.debtsEmptyCta,
                  onCta: () => showDebtFormDialog(context),
                )
              : _DebtsList(debts: rows);
          return Column(
            children: <Widget>[
              // Баннер-приглашение (§7): пока напоминания выключены и
              // пользователь не скрыл его в этой сессии.
              const RemindersBanner(),
              Expanded(child: list),
            ],
          );
        },
      ),
    );
  }
}

class _DebtsList extends ConsumerWidget {
  const _DebtsList({required this.debts});

  final List<Debt> debts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final Map<String, Currency> currencies =
        ref.watch(currenciesMapProvider).value ?? const <String, Currency>{};

    final List<Debt> theyOweMe = debts
        .where((Debt debt) => debt.direction == DebtDirection.theyOweMe.dbValue)
        .toList();
    final List<Debt> iOweThem = debts
        .where((Debt debt) => debt.direction == DebtDirection.iOweThem.dbValue)
        .toList();

    // Пустая секция не рисуется (§1); секции — группировка, не экраны.
    // Сводки секций (§1) — watch тех же провайдеров, что и плитки: один
    // поток на долг, повторных SQL нет.
    final List<Widget> sections = <Widget>[
      if (theyOweMe.isNotEmpty)
        _DebtSection(
          header: l10n.debtSectionTheyOweMe,
          totalLine: l10n.debtSectionTotalTheyOweMe(
            _sectionTotal(theyOweMe, currencies, locale, ref),
          ),
          debts: theyOweMe,
          currencies: currencies,
          locale: locale,
        ),
      if (iOweThem.isNotEmpty)
        _DebtSection(
          header: l10n.debtSectionIOweThem,
          totalLine: l10n.debtSectionTotalIOweThem(
            _sectionTotal(iOweThem, currencies, locale, ref),
          ),
          debts: iOweThem,
          currencies: currencies,
          locale: locale,
        ),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: sections,
    );
  }

  /// Сводка секции (§1): суммы `amount + extra - paid` по долгам секции;
  /// мультивалютность — по валютам (`2 300 ₽ · 50 $`), одна валюта —
  /// одна сумма. Неразрывные разделители — форматтер денег (§7).
  String _sectionTotal(
    List<Debt> debts,
    Map<String, Currency> currencies,
    String locale,
    WidgetRef ref,
  ) {
    final Map<String, int> byCurrency = <String, int>{};
    for (final Debt debt in debts) {
      final DebtSummary? summary =
          ref.watch(debtSummaryProvider(debt.id)).value;
      final int total = debt.amountMinor +
          debt.extraMinor -
          (summary?.paidMinor ?? 0);
      byCurrency[debt.currencyCode] =
          (byCurrency[debt.currencyCode] ?? 0) + total;
    }
    final List<String> parts = <String>[
      for (final MapEntry<String, int> entry in byCurrency.entries)
        formatMoneyMinor(
          entry.value,
          symbol: currencies[entry.key]?.symbol ?? entry.key,
          locale: locale,
          exponent: currencyExponentByCode(entry.key),
        ),
    ];
    return parts.join(' · ');
  }
}

class _DebtSection extends StatelessWidget {
  const _DebtSection({
    required this.header,
    required this.totalLine,
    required this.debts,
    required this.currencies,
    required this.locale,
  });

  final String header;
  final String totalLine;
  final List<Debt> debts;
  final Map<String, Currency> currencies;
  final String locale;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            header,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final Debt debt in debts) ...<Widget>[
          _DebtTile(
            debt: debt,
            currencies: currencies,
            locale: locale,
          ),
          const Divider(height: 1),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            totalLine,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      ],
    );
  }
}

/// Карточка долга в списке (§1): человек (bold), сумма к возврату
/// (= amount+extra), «Остаток: …», справа — срок (локальная дата,
/// просрочка красным). Тап — карточка долга. Долгое нажатие/контекстное
/// меню не вводим (правка/удаление в карточке долга, §1).
class _DebtTile extends ConsumerWidget {
  const _DebtTile({
    required this.debt,
    required this.currencies,
    required this.locale,
  });

  final Debt debt;
  final Map<String, Currency> currencies;
  final String locale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DebtSummary? summary = ref.watch(debtSummaryProvider(debt.id)).value;
    final String symbol =
        currencies[debt.currencyCode]?.symbol ?? debt.currencyCode;
    final int exponent = currencyExponentByCode(debt.currencyCode);

    final DateTime? due = _dueDateOf(debt);
    final bool overdue = due != null && due.isBefore(DateTime.now());
    final Color? dueColor = overdue ? Theme.of(context).colorScheme.error : null;

    return ListTile(
      title: Text(
        debt.person,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            formatMoneyMinor(
              debt.amountMinor + debt.extraMinor,
              symbol: symbol,
              locale: locale,
              exponent: exponent,
            ),
          ),
          Text(
            l10n.debtRemainingLine(
              formatMoneyMinor(
                summary?.remainingMinor ??
                    debt.amountMinor + debt.extraMinor,
                symbol: symbol,
                locale: locale,
                exponent: exponent,
              ),
            ),
            // Отрицательный остаток (платежей больше долга — возможен после
            // импорта) — красным и в списке, без чипа (§2, D-90).
            style: (summary?.remainingMinor ?? 0) < 0
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
        ],
      ),
      trailing: due == null
          ? null
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  DateFormat.yMd(locale).format(due),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: dueColor),
                ),
                if (overdue)
                  Text(
                    l10n.debtOverdueBadge,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
              ],
            ),
      onTap: () => context.push('/debts/${debt.id}'),
    );
  }

  DateTime? _dueDateOf(Debt debt) {
    final String? due = debt.dueDate;
    if (due == null || due.isEmpty) {
      return null;
    }
    return DateTime.tryParse(due)?.toLocal();
  }
}
