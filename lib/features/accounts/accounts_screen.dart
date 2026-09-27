import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/accounts/account_form_dialog.dart';
import 'package:kopilka/features/accounts/accounts_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Счета»: живой список с балансами, CRUD через контроллер.
class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<List<AccountBalance>> balances = ref.watch(
      accountsWithBalancesProvider,
    );

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.accountAdd,
        onPressed: () => showAccountFormDialog(context),
        child: const Icon(Icons.add),
      ),
      body: balances.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          // Поток DAO сам переподпишется при пересборке виджета.
          onRetry: () => ref.invalidate(accountsWithBalancesProvider),
        ),
        data: (List<AccountBalance> rows) {
          if (rows.isEmpty) {
            return EmptyState(
              text: l10n.accountsEmpty,
              ctaLabel: l10n.accountsEmptyCta,
              onCta: () => showAccountFormDialog(context),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: rows.length,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final AccountBalance row = rows[index];
              return _AccountTile(row: row);
            },
          );
        },
      ),
    );
  }
}

class _AccountTile extends ConsumerWidget {
  const _AccountTile({required this.row});

  final AccountBalance row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final IconData icon = switch (AccountKind.fromDb(row.account.kind)) {
      AccountKind.cash => Icons.payments_outlined,
      AccountKind.bank => Icons.account_balance_outlined,
      AccountKind.card => Icons.credit_card,
      AccountKind.other => Icons.wallet_outlined,
    };

    return ListTile(
      leading: Icon(icon),
      title: Text(row.account.name),
      subtitle: Text(
        '${l10n.kindLabel}: ${switch (AccountKind.fromDb(row.account.kind)) {
          AccountKind.cash => l10n.accountKindCash,
          AccountKind.bank => l10n.accountKindBank,
          AccountKind.card => l10n.accountKindCard,
          AccountKind.other => l10n.accountKindOther,
        }}',
      ),
      trailing: Text(
        formatMoneyMinor(
          row.balanceMinor,
          // R5: символ по карте справочника (уходит линейный поиск);
          // код вне справочника — fallback на сам код.
          symbol: ref.watch(currenciesMapProvider).value?[row.account.currencyCode]
                  ?.symbol ??
              row.account.currencyCode,
          locale: locale,
          // B3: формат по экспоненту валюты счёта (JPY без копеек,
          // KWD с тремя знаками).
          exponent: currencyExponentByCode(row.account.currencyCode),
        ),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      onTap: () => showAccountFormDialog(context, account: row),
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
      title: l10n.accountDeleteTitle,
      body: l10n.accountDeleteBody(row.account.name),
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result = await ref
        .read(accountsControllerProvider.notifier)
        .deleteAccount(row.account.id);
    if (result.isFailure && context.mounted) {
      // Отказ DAO объясняется пользователю (счёт с живыми операциями).
      await showDataFailureSnack(context, result.failure);
    }
  }
}
