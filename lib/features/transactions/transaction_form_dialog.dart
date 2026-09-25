import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Форма быстрого ввода: тип задаётся кнопкой на списке операций
/// (расход/доход/перевод). Счёт по умолчанию — первый живой.
Future<void> showTransactionFormDialog(
  BuildContext context, {
  required TransactionType type,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => _TransactionFormDialog(type: type),
  );
}

class _TransactionFormDialog extends ConsumerStatefulWidget {
  const _TransactionFormDialog({required this.type});

  final TransactionType type;

  @override
  ConsumerState<_TransactionFormDialog> createState() =>
      _TransactionFormDialogState();
}

class _TransactionFormDialogState
    extends ConsumerState<_TransactionFormDialog> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _accountId;
  String? _targetAccountId;
  String? _categoryId;
  DateTime _date = DateTime.now();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  String _formatDate(AppLocalizations l10n) =>
      MaterialLocalizations.of(context).formatMediumDate(_date);

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    if (_accountId == null ||
        (widget.type == TransactionType.transfer && _targetAccountId == null)) {
      return;
    }
    setState(() => _busy = true);
    final TransactionsController controller = ref.read(
      transactionsControllerProvider.notifier,
    );
    // Деньги парсятся только общим парсером (§3, «Грабли»): «25000» — это
    // 25 000,00, а не 250,00 — int.parse без множителя ×100 давал занижение.
    final int amountMinor = parseAmountToMinor(_amount.text)!;
    final Result<dynamic> result;
    switch (widget.type) {
      case TransactionType.expense || TransactionType.income:
        result = await controller.createIncomeOrExpense(
          type: widget.type,
          accountId: _accountId!,
          amountMinor: amountMinor,
          categoryId: _categoryId,
          note: _note.text,
          date: _date,
        );
      case TransactionType.transfer:
        result = await controller.createTransfer(
          accountId: _accountId!,
          targetAccountId: _targetAccountId!,
          amountMinor: amountMinor,
          note: _note.text,
          date: _date,
        );
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (result.isSuccess) {
      Navigator.of(context).pop();
    } else {
      await showDataFailureSnack(context, result.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Account> accounts =
        ref.watch(accountsProvider).value ?? const <Account>[];
    final List<Category> categories = widget.type == TransactionType.transfer
        ? const <Category>[]
        : ref
              .watch(
                categoriesByKindProvider(
                  widget.type == TransactionType.income
                      ? CategoryKind.income
                      : CategoryKind.expense,
                ),
              )
              .value ??
            const <Category>[];

    // Умолчания при первом построении: первый живой счёт, без категории.
    _accountId ??= accounts.isNotEmpty ? accounts.first.id : null;

    final String title = switch (widget.type) {
      TransactionType.expense => l10n.newExpenseTitle,
      TransactionType.income => l10n.newIncomeTitle,
      TransactionType.transfer => l10n.newTransferTitle,
    };

    return AlertDialog(
      title: Text(title),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              DropdownButtonFormField<String>(
                initialValue: _accountId,
                decoration: InputDecoration(
                  labelText: widget.type == TransactionType.transfer
                      ? l10n.accountFrom
                      : l10n.navAccounts,
                ),
                items: accounts
                    .map(
                      (Account account) => DropdownMenuItem<String>(
                        value: account.id,
                        child: Text(account.name),
                      ),
                    )
                    .toList(),
                onChanged: (String? value) => setState(() => _accountId = value),
              ),
              if (widget.type == TransactionType.transfer) ...<Widget>[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _targetAccountId,
                  decoration: InputDecoration(labelText: l10n.accountTo),
                  items: accounts
                      .where((Account account) => account.id != _accountId)
                      .map(
                        (Account account) => DropdownMenuItem<String>(
                          value: account.id,
                          child: Text(account.name),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) =>
                      setState(() => _targetAccountId = value),
                ),
              ],
              const SizedBox(height: 12),
              if (widget.type != TransactionType.transfer) ...<Widget>[
                DropdownButtonFormField<String?>(
                  initialValue: _categoryId,
                  decoration: InputDecoration(labelText: l10n.categoryLabel),
                  items: <DropdownMenuItem<String?>>[
                    DropdownMenuItem<String?>(
                      child: Text(l10n.filterAll),
                    ),
                    for (final Category category in categories)
                      DropdownMenuItem<String?>(
                        value: category.id,
                        child: Text(category.name),
                      ),
                  ],
                  onChanged: (String? value) =>
                      setState(() => _categoryId = value),
                ),
                const SizedBox(height: 12),
              ],
              AmountField(controller: _amount),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(child: Text('${l10n.dateLabel}: ${_formatDate(l10n)}')),
                  IconButton(
                    tooltip: l10n.dateLabel,
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_month_outlined),
                  ),
                ],
              ),
              TextFormField(
                controller: _note,
                decoration: InputDecoration(labelText: l10n.noteLabel),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.saveAction),
        ),
      ],
    );
  }
}
