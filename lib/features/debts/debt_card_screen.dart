import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart' show DebtSummary;
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/debts/debt_form_dialog.dart';
import 'package:kopilka/features/debts/debt_payment_dialog.dart';
import 'package:kopilka/features/debts/debts_controller.dart';
import 'package:kopilka/features/transactions/attachment_section.dart';
import 'package:kopilka/data/attachments_service.dart'
    show AttachmentOwnerKind;
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Карточка долга (спека §2): сводка `watchSummary` (NULL → errorNotFound
/// + назад, D-87.1), платежи `watchPayments` (удаление с подтверждением,
/// без редактирования — D-89), вложение по каркасу D-67.а (§2).
class DebtCardScreen extends ConsumerWidget {
  const DebtCardScreen({super.key, required this.debtId});

  final String debtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<DebtSummary?> summary =
        ref.watch(debtSummaryProvider(debtId));

    return Scaffold(
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        // Поток умер (ошибка БД) — штатный ErrorState с повтором.
        error: (Object error, StackTrace stack) => ErrorState(
          onRetry: () => ref.invalidate(debtSummaryProvider(debtId)),
        ),
        data: (DebtSummary? data) {
          // D-87.1: долг удалён (гонка: soft delete из другого окна или
          // импорт) — не «ошибка», а штатный исход: errorNotFound и назад.
          if (data == null) {
            _scheduleNotFoundExit(context);
            return const ErrorState();
          }
          return _DebtCardBody(summary: data);
        },
      ),
    );
  }

  void _scheduleNotFoundExit(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) {
        showSnack(context, AppLocalizations.of(context).errorNotFound);
        if (context.canPop()) {
          context.pop();
        }
      }
    });
  }
}

/// Тело карточки: головка (человек/направление/валюта/срок/note + кнопки),
/// сводка текстом (M5-опыт: не disabled-поля), платежи, вложение.
class _DebtCardBody extends ConsumerWidget {
  const _DebtCardBody({required this.summary});

  final DebtSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Debt debt = summary.debt;
    final String locale = Localizations.localeOf(context).toString();
    final String symbol = ref.watch(currenciesMapProvider).value?[debt.currencyCode]?.symbol ??
        debt.currencyCode;
    final int exponent = currencyExponentByCode(debt.currencyCode);
    String money(int minor) => formatMoneyMinor(
          minor,
          symbol: symbol,
          locale: locale,
          exponent: exponent,
        );

    final DateTime? due = _dueDateOf(debt);
    final bool overdue = due != null && due.isBefore(DateTime.now());
    final bool paidOff = summary.remainingMinor == 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    debt.person,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    debt.direction == DebtDirection.theyOweMe.dbValue
                        ? l10n.debtDirectionTheyOweMe
                        : l10n.debtDirectionIOweThem,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            // Признак «погашен» (§2): remaining == 0 → зелёный чип;
            // отрицательный остаток показывается честно красным, без чипа.
            if (paidOff)
              Chip(
                avatar: Icon(
                  Icons.check_circle,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                label: Text(l10n.debtPaidOffBadge),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (due != null)
          Row(
            children: <Widget>[
              Text('${l10n.debtDueDateLabel}: '),
              Text(
                DateFormat.yMd(locale).format(due),
                style: overdue
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
              if (overdue) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  l10n.debtOverdueBadge,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        if (debt.note != null && debt.note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(debt.note!),
          ),
        const SizedBox(height: 12),
        // Кнопки головки (§2): «Изменить» (форма), «Удалить» (подтверждение).
        Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: () => showDebtFormDialog(context, debt: debt),
              icon: const Icon(Icons.edit_outlined),
              label: Text(l10n.debtEditTitle),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _confirmDelete(context, ref, l10n),
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.deleteAction),
            ),
          ],
        ),
        const Divider(height: 24),
        // Сводка текстом (§2, M5-опыт): к возврату / погашено / остаток,
        // переплата — отдельной строкой только когда есть.
        Text(
          '${l10n.debtAmountLabel}: ${money(summary.totalMinor)}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        // Погашено — сумма живых платежей отдельной строкой (§2, D-90).
        Text(l10n.debtPaidLine(money(summary.paidMinor))),
        // Отрицательный остаток (платежей больше долга — возможен после
        // импорта) — красным, честно, без чипа «Погашен» (§2).
        Text(
          l10n.debtRemainingLine(money(summary.remainingMinor)),
          style: summary.remainingMinor < 0
              ? TextStyle(color: Theme.of(context).colorScheme.error)
              : null,
        ),
        if (debt.extraMinor > 0)
          Text(
            l10n.debtExtraHelper,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => showDebtPaymentDialog(context, debt: debt),
          icon: const Icon(Icons.payments_outlined),
          label: Text(l10n.debtRecordPaymentAction),
        ),
        const Divider(height: 24),
        Text(
          l10n.debtPaymentsTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        _DebtPaymentsList(debt: debt),
        const Divider(height: 24),
        // Вложение чека (§2) — каркас D-67.а, владелец — долг (D-82):
        // секция читает/пишет вложение через обобщённый сервис.
        AttachmentSection(
          ownerKind: AttachmentOwnerKind.debt,
          ownerId: debt.id,
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.debtDeleteTitle,
      body: l10n.debtDeleteBody,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result =
        await ref.read(debtsControllerProvider.notifier).deleteDebt(
              summary.debt.id,
            );
    if (!context.mounted) {
      return;
    }
    if (result.isFailure) {
      await showDataFailureSnack(context, result.failure);
      return;
    }
    // После soft delete — назад к списку (§2): снек не нужен, карточка
    // исчезает из живого потока.
    if (context.canPop()) {
      context.pop();
    }
  }

  DateTime? _dueDateOf(Debt debt) {
    final String? due = debt.dueDate;
    if (due == null || due.isEmpty) {
      return null;
    }
    return DateTime.tryParse(due)?.toLocal();
  }
}

/// Платежи долга (§2): сумма, дата факта (локальная), значок «перевод»
/// при связи; удаление с подтверждением; свежие сверху (порядок DAO).
class _DebtPaymentsList extends ConsumerWidget {
  const _DebtPaymentsList({required this.debt});

  final Debt debt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final List<DebtPayment> payments = ref
        .watch(debtPaymentsProvider(debt.id))
        .value ?? const <DebtPayment>[];
    final String symbol = ref
            .watch(currenciesMapProvider)
            .value?[debt.currencyCode]?.symbol ??
        debt.currencyCode;
    final int exponent = currencyExponentByCode(debt.currencyCode);

    if (payments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(l10n.debtPaymentsEmpty),
      );
    }

    return Column(
      children: <Widget>[
        for (final DebtPayment payment in payments)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              formatMoneyMinor(
                payment.amountMinor,
                symbol: symbol,
                locale: locale,
                exponent: exponent,
              ),
            ),
            subtitle: Text(
              DateFormat.yMd(locale)
                  .format(_paidAtOf(payment) ?? DateTime.now()),
            ),
            trailing: payment.transactionId != null
                ? Tooltip(
                    message: l10n.debtPaymentLinkTransfer,
                    child: const Icon(Icons.swap_horiz),
                  )
                : null,
            // Удаление — со свайпа-меню: подтверждение (§2); редактирования
            // нет — delete+create покрывает правку (D-89).
            onLongPress: () => _confirmDeletePayment(
              context,
              ref,
              l10n,
              payment,
            ),
          ),
      ],
    );
  }

  DateTime? _paidAtOf(DebtPayment payment) {
    final String paidAt = payment.paidAt;
    if (paidAt.isEmpty) {
      return null;
    }
    return DateTime.tryParse(paidAt)?.toLocal();
  }

  Future<void> _confirmDeletePayment(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    DebtPayment payment,
  ) async {
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.debtPaymentDeleteTitle,
      body: l10n.debtPaymentDeleteBody,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result =
        await ref.read(debtsControllerProvider.notifier).deletePayment(
              payment.id,
            );
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}
