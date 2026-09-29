import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/transactions/transaction_form_dialog.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Лист выбора типа операции: расход / доход / перевод. Нейтральная точка
/// входа для FAB без активного фильтра типа и пустого состояния списка —
/// доход не должен прятаться за фильтром (замечание оператора 2026-09-28).
Future<void> showTransactionTypePicker(BuildContext context) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  const List<(TransactionType, IconData)> options = <(
    TransactionType,
    IconData
  )>[
    (TransactionType.expense, Icons.south_west),
    (TransactionType.income, Icons.north_east),
    (TransactionType.transfer, Icons.swap_horiz),
  ];
  final TransactionType? picked = await showModalBottomSheet<TransactionType>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final (TransactionType type, IconData icon) in options)
            ListTile(
              leading: Icon(icon),
              title: Text(switch (type) {
                TransactionType.expense => l10n.expenseAction,
                TransactionType.income => l10n.incomeAction,
                TransactionType.transfer => l10n.transferAction,
              }),
              onTap: () => Navigator.of(sheetContext).pop(type),
            ),
        ],
      ),
    ),
  );
  if (picked != null && context.mounted) {
    await showTransactionFormDialog(context, type: picked);
  }
}

/// Экран «Транзакции»: поиск по заметке, фильтры (тип, счёт), список живых
/// операций, быстрый ввод расхода/дохода/перевода.
class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TransactionsFilterState filter = ref.watch(
      transactionsFilterProvider,
    );
    final AsyncValue<List<TransactionView>> transactions = ref.watch(
      filteredTransactionViewsProvider,
    );
    final bool filtered = filter.type != null ||
        filter.accountId != null ||
        filter.search.isNotEmpty;

    return Scaffold(
      floatingActionButton: _QuickEntryFab(filter: filter),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              decoration: InputDecoration(
                hintText: l10n.searchHint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
              ),
              onChanged: ref
                  .read(transactionsFilterProvider.notifier)
                  .setSearch,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: <Widget>[
                _typeChip(context, ref, filter, l10n, TransactionType.income,
                    l10n.filterIncomes),
                _typeChip(context, ref, filter, l10n, TransactionType.expense,
                    l10n.filterExpenses),
                _typeChip(context, ref, filter, l10n, TransactionType.transfer,
                    l10n.filterTransfers),
                const SizedBox(width: 8),
                _accountChip(context, ref, filter, l10n),
              ],
            ),
          ),
          Expanded(
            child: transactions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object error, StackTrace stack) => ErrorState(
                onRetry: () => ref.invalidate(filteredTransactionViewsProvider),
              ),
              data: (List<TransactionView> rows) {
                if (rows.isEmpty) {
                  if (filtered) {
                    return Center(
                      child: Text(l10n.transactionsEmptyFiltered),
                    );
                  }
                  // U1: CTA на пустом списке — тот же выбор типа, что у FAB.
                  return EmptyState(
                    text: l10n.transactionsEmpty,
                    ctaLabel: l10n.transactionsEmptyCta,
                    onCta: () => showTransactionTypePicker(context),
                  );
                }
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) =>
                      _TransactionTile(row: rows[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeChip(
    BuildContext context,
    WidgetRef ref,
    TransactionsFilterState filter,
    AppLocalizations l10n,
    TransactionType type,
    String label,
  ) {
    final bool selected = filter.type == type;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: selected,
        label: Text(label),
        onSelected: (bool value) => ref
            .read(transactionsFilterProvider.notifier)
            .setType(value ? type : null),
      ),
    );
  }

  Widget _accountChip(
    BuildContext context,
    WidgetRef ref,
    TransactionsFilterState filter,
    AppLocalizations l10n,
  ) {
    final List<Account> accounts =
        ref.watch(accountsProvider).value ?? const <Account>[];
    final String label = filter.accountId == null
        ? l10n.filterAllAccounts
        : (accounts
                .where((Account account) => account.id == filter.accountId)
                .map((Account account) => account.name)
                .toList()
                .firstOrNull ??
            l10n.filterAllAccounts);
    return PopupMenuButton<String>(
      initialValue: filter.accountId,
      onSelected: (String? accountId) => ref
          .read(transactionsFilterProvider.notifier)
          .setAccount(accountId),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          child: Text(l10n.filterAllAccounts),
        ),
        for (final Account account in accounts)
          PopupMenuItem<String>(value: account.id, child: Text(account.name)),
      ],
      child: Chip(
        avatar: const Icon(Icons.filter_list, size: 18),
        label: Text(label),
        backgroundColor: filter.accountId == null
            ? null
            : Theme.of(context).colorScheme.secondaryContainer,
      ),
    );
  }
}

class _QuickEntryFab extends ConsumerWidget {

  const _QuickEntryFab({required this.filter});

  final TransactionsFilterState filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    // U10: с активным фильтром типа FAB открывает форму этого типа и
    // подписывается его типом — обещает ровно то, что откроется.
    // Без фильтра — нейтральная кнопка «Добавить»: выбор типа в листе,
    // иначе доход не находится (замечание оператора 2026-09-28).
    final TransactionType? type = filter.type;
    if (type == null) {
      return FloatingActionButton.extended(
        onPressed: () => unawaited(showTransactionTypePicker(context)),
        label: Text(l10n.addAction),
        icon: const Icon(Icons.add),
      );
    }
    final String label = switch (type) {
      TransactionType.expense => l10n.expenseAction,
      TransactionType.income => l10n.incomeAction,
      TransactionType.transfer => l10n.transferAction,
    };
    return FloatingActionButton.extended(
      onPressed: () => showTransactionFormDialog(context, type: type),
      label: Text(label),
      icon: const Icon(Icons.add),
    );
  }
}

class _TransactionTile extends ConsumerWidget {
  const _TransactionTile({required this.row});

  final TransactionView row;

  /// Строка перевода (R8): единое место формирования «Счёт А → Счёт Б» —
  /// на M3-шаге 4 здесь появятся две суммы и две валюты.
  static String transferLine(String fromName, String? toName) =>
      '$fromName → ${toName ?? '…'}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final Transaction transaction = row.transaction;
    final TransactionType type = TransactionType.fromDb(transaction.type);

    // U4: вместо «—» — локализованные тексты; имена приходят из DAO (R7).
    final String line = switch (type) {
      TransactionType.transfer => transferLine(
          row.accountName,
          row.targetAccountName,
        ),
      TransactionType.income ||
      TransactionType.expense =>
        row.categoryName ??
            (row.accountName.isNotEmpty
                ? row.accountName
                : l10n.transactionTileAccountGone),
    };
    // Категории у операции может не быть (не задана) — «Без категории» (U4).
    final String subtitleCategoryName = row.categoryName ??
        (type == TransactionType.transfer ? '' : l10n.transactionTileNoCategory);

    final Color amountColor = switch (type) {
      TransactionType.income => Colors.green.shade700,
      TransactionType.expense =>
        Theme.of(context).colorScheme.onSurface,
      TransactionType.transfer =>
        Theme.of(context).colorScheme.onSurfaceVariant,
    };
    final TextStyle amountStyle = Theme.of(context)
        .textTheme
        .titleMedium!
        .copyWith(color: amountColor);

    // Символ валюты из справочника (R4/A7); код вне справочника — fallback
    // на код. Формат — по экспоненту валюты (B3/D-27).
    final Map<String, Currency> currencies =
        ref.watch(currenciesMapProvider).value ?? const <String, Currency>{};
    String amountText(int amountMinor, String? code) => formatMoneyMinor(
          amountMinor,
          symbol: currencies[code]?.symbol ?? (code ?? ''),
          locale: locale,
          exponent: currencyExponentByCode(code ?? ''),
        );

    // B4.3: сумма справа. У мультивалютного перевода — обе суммы в
    // компактном формате «− 100,00 ₽ → 1,00 $», каждая по экспоненту
    // своей валюты; строка не помещается — перенос на вторую (Wrap),
    // сокращать группировку и округлять нельзя. Курс в список не выводим.
    final bool multiCurrencyTransfer = type == TransactionType.transfer &&
        row.targetCurrencyCode != null &&
        row.targetCurrencyCode != row.accountCurrencyCode &&
        transaction.targetAmountMinor != null;
    final Widget amount = multiCurrencyTransfer
        ? Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: <Widget>[
              Text(amountText(transaction.amountMinor, row.accountCurrencyCode),
                  style: amountStyle),
              Text('→', style: amountStyle),
              Text(
                amountText(
                  transaction.targetAmountMinor!,
                  row.targetCurrencyCode,
                ),
                style: amountStyle,
              ),
            ],
          )
        : Text(
            switch (type) {
              TransactionType.income => '+ ${amountText(transaction.amountMinor, transaction.currencyCode)}',
              TransactionType.expense => '− ${amountText(transaction.amountMinor, transaction.currencyCode)}',
              // U5: «⇄» читается хуже «→»; направление совпадает со строкой.
              TransactionType.transfer => '→ ${amountText(transaction.amountMinor, transaction.currencyCode)}',
            },
            style: amountStyle,
          );

    return ListTile(
      leading: Icon(
        switch (type) {
          TransactionType.income => Icons.north_east,
          TransactionType.expense => Icons.south_west,
          TransactionType.transfer => Icons.swap_horiz,
        },
      ),
      title: Text(line),
      subtitle: Text(
        MaterialLocalizations.of(context).formatMediumDate(transaction.date) +
            (transaction.note == null
                ? (subtitleCategoryName.isEmpty
                    ? ''
                    : ' · $subtitleCategoryName')
                : ' · ${transaction.note}'),
      ),
      // Маркер вложения (M5-шаг 6в): у операции живой файл — иконка
      // скрепки перед суммой; файл может и не существовать на диске
      // (восстановленный бэкап, D-64) — список смотрит только метаданные.
      // Иконка вплетена в trailing через FittedBox-безопасный Row: у Wrap
      // мультивалютного перевода и так длинный trailing — маркер только
      // когда он есть, иначе trailing не меняется (B4.3-регресс).
      trailing: row.hasAttachment
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.attach_file,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                amount,
              ],
            )
          : amount,
      onLongPress: () => _confirmDelete(context, ref, l10n),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.transactionDeleteTitle,
      body: l10n.transactionDeleteBody,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result = await ref
        .read(transactionsControllerProvider.notifier)
        .deleteTransaction(row.transaction.id);
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}
