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
        // Уникальный hero-тег (M6-шаг D): FAB всех веток шелла живут в одном
        // поддереве корневого навигатора, дефолтный тег ломает Hero-полёт при
        // пуще fullscreen-маршрута (просмотр вложения из плитки операций).
        heroTag: 'accounts-fab',
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

    // M5/D-54: счёт с флагом «не учитывать в балансе» помечается в
    // подзаголовке сдержанной подписью (малый значок + текст);
    // персональный баланс плитки считается как раньше.
    final String subtitle =
        '${l10n.kindLabel}: ${switch (AccountKind.fromDb(row.account.kind)) {
          AccountKind.cash => l10n.accountKindCash,
          AccountKind.bank => l10n.accountKindBank,
          AccountKind.card => l10n.accountKindCard,
          AccountKind.other => l10n.accountKindOther,
        }}';

    // M6-шаг D (спека §2): признак накопительного — бейдж в том же
    // стиле (значок savings_outlined + подпись); при обоих флагах —
    // обе подписи. Дату в плитку не выносим (шум; дата — в форме).
    final bool isSavings = row.account.interestReminderDate != null;
    final bool isExcluded = row.account.excludeFromBalance == true;

    return ListTile(
      leading: Icon(icon),
      title: Text(row.account.name),
      // Wrap, а не Row: подзаголовок получает узкие ограничения, и только
      // Wrap не переполняется — длинные строки переносятся на новую строку.
      // Значок и подпись — отдельные дети: подпись «не в балансе»
      // самодостаточна (прецедент D-56 — tooltip без интерфейсного смысла).
      subtitle: !isSavings && !isExcluded
          ? Text(subtitle)
          : Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text(subtitle),
                if (isSavings) ...<Widget>[
                  Icon(
                    Icons.savings_outlined,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  Text(
                    l10n.accountSavingsBadge,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (isExcluded) ...<Widget>[
                  Icon(
                    Icons.visibility_off_outlined,
                    size: 14,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  Text(
                    l10n.accountExcludedBadge,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
      trailing: Text(
        formatMoneyMinor(
          row.balanceMinor,
          // R5: символ по карте справочника (уходит линейный поиск);
          // код вне справочника — fallback на сам код.
          symbol:
              ref
                  .watch(currenciesMapProvider)
                  .value?[row.account.currencyCode]
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
