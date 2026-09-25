import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/accounts/accounts_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог формы счёта. При `account == null` создаёт счёт, иначе редактирует.
///
/// Отказы DAO объясняются пользователю снекбаром с локализованным текстом
/// по машиночитаемому виду отказа.
Future<void> showAccountFormDialog(
  BuildContext context, {
  AccountBalance? account,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _AccountFormDialog(initial: account),
  );
}

class _AccountFormDialog extends ConsumerStatefulWidget {
  const _AccountFormDialog({this.initial});

  final AccountBalance? initial;

  @override
  ConsumerState<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends ConsumerState<_AccountFormDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _balance = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  AccountKind _kind = AccountKind.cash;
  String? _currencyCode;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final AccountBalance? initial = widget.initial;
    if (initial != null) {
      _name.text = initial.account.name;
      _kind = AccountKind.fromDb(initial.account.kind);
      _currencyCode = initial.account.currencyCode;
      // Поле «Сумма» при редактировании означает НОВЫЙ начальный баланс:
      // предзаполняем его initial_balance_minor, не вычисленным балансом
      // (§3: баланс считается из истории, полями его не правят).
      _balance.text = (initial.account.initialBalanceMinor / minorUnitsPerMajor)
          .toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _balance.dispose();
    super.dispose();
  }

  String _kindLabel(AppLocalizations l10n, AccountKind kind) => switch (kind) {
    AccountKind.cash => l10n.accountKindCash,
    AccountKind.bank => l10n.accountKindBank,
    AccountKind.card => l10n.accountKindCard,
    AccountKind.other => l10n.accountKindOther,
  };

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final bool editing = widget.initial != null;
    final AppLocalizations l10n = AppLocalizations.of(context);
    // При редактировании поле «Сумма» — НОВЫЙ начальный баланс: ноль
    // корректен (allowZero), пустое поле — отказ валидации. При создании
    // пустое поле означает «баланс 0», а введённый ноль — отказ (парсер
    // принимает только суммы строго больше нуля).
    final int? parsedMinor =
        parseAmountToMinor(_balance.text, allowZero: editing);
    final bool invalidAmount = editing
        ? parsedMinor == null
        : parsedMinor == null && _balance.text.trim().isNotEmpty;
    if (invalidAmount) {
      await showSnack(context, l10n.amountInvalid);
      return;
    }
    final int initialMinor = parsedMinor ?? 0;
    // Валюта проверена валидатором формы; guard на случай будущих правок:
    // исключение после `_busy = true` заморозило бы кнопки диалога.
    final String? currencyCode = _currencyCode;
    if (!editing && currencyCode == null) {
      await showSnack(context, l10n.selectCurrencyValidator);
      return;
    }
    setState(() => _busy = true);
    final AccountsController controller = ref.read(
      accountsControllerProvider.notifier,
    );
    final Result<dynamic> result;
    try {
      if (!editing) {
        result = await controller.createAccount(
          name: _name.text,
          kind: _kind,
          currencyCode: currencyCode!,
          initialBalanceMinor: initialMinor,
        );
      } else {
        result = await controller.updateAccount(
          widget.initial!.account.id,
          name: Value<String>(_name.text),
          kind: Value<AccountKind>(_kind),
          initialBalanceMinor: Value<int>(initialMinor),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
    if (!mounted) {
      return;
    }
    if (result.isSuccess) {
      Navigator.of(context).pop();
    } else {
      await showDataFailureSnack(context, result.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Currency> currencies =
        ref.watch(currenciesProvider).value ?? const <Currency>[];
    final bool editing = widget.initial != null;

    return AlertDialog(
      title: Text(editing ? l10n.accountEdit : l10n.accountAdd),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              TextFormField(
                controller: _name,
                decoration: InputDecoration(labelText: l10n.nameLabel),
                validator: (String? value) => (value == null ||
                        value.trim().isEmpty)
                    ? l10n.errorInvalidInput
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AccountKind>(
                initialValue: _kind,
                decoration: InputDecoration(labelText: l10n.kindLabel),
                items: <AccountKind>[
                  AccountKind.cash,
                  AccountKind.bank,
                  AccountKind.card,
                  AccountKind.other,
                ]
                    .map(
                      (AccountKind kind) => DropdownMenuItem<AccountKind>(
                        value: kind,
                        child: Text(_kindLabel(l10n, kind)),
                      ),
                    )
                    .toList(),
                onChanged: (AccountKind? kind) =>
                    setState(() => _kind = kind ?? AccountKind.cash),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _currencyCode,
                decoration: InputDecoration(labelText: l10n.currencyLabel),
                // Без валюты DAO отклонит создание — валидируем до отправки.
                validator: editing
                    ? null
                    : (String? code) =>
                          code == null ? l10n.selectCurrencyValidator : null,
                items: currencies
                    .map(
                      (Currency currency) => DropdownMenuItem<String>(
                        value: currency.code,
                        child: Text('${currency.code} (${currency.symbol})'),
                      ),
                    )
                    .toList(),
                onChanged: editing
                    ? null
                    : (String? code) => setState(() => _currencyCode = code),
              ),
              const SizedBox(height: 12),
              // При редактировании поле — новый начальный баланс: ноль
              // корректен, поэтому и поле формы, и парсер в _submit
              // допускают его (allowZero).
              AmountField(controller: _balance, allowZero: editing),
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
