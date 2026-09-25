import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/transactions/transaction_form_dialog.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

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
    final AsyncValue<List<Transaction>> transactions = ref.watch(
      filteredTransactionsProvider,
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
              error: (Object error, StackTrace stack) =>
                  Center(child: Text(l10n.errorUnknown)),
              data: (List<Transaction> rows) {
                if (rows.isEmpty) {
                  return Center(
                    child: Text(
                      filtered
                          ? l10n.transactionsEmptyFiltered
                          : l10n.transactionsEmpty,
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (BuildContext context, int index) =>
                      const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) =>
                      _TransactionTile(transaction: rows[index]),
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
    return FloatingActionButton.extended(
      onPressed: () => showTransactionFormDialog(
        context,
        type: filter.type ?? TransactionType.expense,
      ),
      label: Text(l10n.expenseAction),
      icon: const Icon(Icons.add),
    );
  }
}

class _TransactionTile extends ConsumerWidget {
  const _TransactionTile({required this.transaction});

  final Transaction transaction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final List<Account> accounts =
        ref.watch(accountsProvider).value ?? const <Account>[];
    final List<Category> categories =
        ref.watch(allCategoriesProvider).value ?? const <Category>[];

    final TransactionType type = TransactionType.fromDb(transaction.type);
    final Account? account = _byId(accounts, transaction.accountId);
    final Account? target = transaction.targetAccountId == null
        ? null
        : _byId(accounts, transaction.targetAccountId!);
    final Category? category = transaction.categoryId == null
        ? null
        : _byId(categories, transaction.categoryId!);

    final String accountName = account?.name ?? '—';
    final String line = switch (type) {
      TransactionType.transfer =>
        '$accountName → ${target?.name ?? '—'}',
      TransactionType.income ||
      TransactionType.expense =>
        category?.name ?? accountName,
    };

    final String sign = switch (type) {
      TransactionType.income => '+',
      TransactionType.expense => '−',
      TransactionType.transfer => '⇄',
    };
    final Color amountColor = switch (type) {
      TransactionType.income => Colors.green.shade700,
      TransactionType.expense =>
        Theme.of(context).colorScheme.onSurface,
      TransactionType.transfer =>
        Theme.of(context).colorScheme.onSurfaceVariant,
    };

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
            (transaction.note == null ? '' : ' · ${transaction.note}'),
      ),
      trailing: Text(
        '$sign ${formatMoneyMinor(transaction.amountMinor, symbol: '₽', locale: locale)}',
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(color: amountColor),
      ),
      onLongPress: () => _confirmDelete(context, ref, l10n),
    );
  }

  T? _byId<T>(List<T> items, String id) => items
      .where((T item) => (item as dynamic).id == id)
      .firstOrNull;

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
        .deleteTransaction(transaction.id);
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}
