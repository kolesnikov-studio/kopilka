import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/rate.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/debts/debts_controller.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог гашения долга (спека §4): платёж без перевода (по умолчанию,
/// D-81.в) или связка «перевод + платёж одним потоком» — выбор счёта
/// списания, счёта зачисления (валюта долга), сумм по D-17 (одна — при
/// равных валютах, обе — при разных, строка курса), примечание.
///
/// Конвертация валют — UX-решение пользователя (D-81/D-17): вторая сумма
/// предзаполняется по текущему курсу с подсказкой `transferPrefillNote`,
/// авто-пересчётов «на лету» нет. Отказ DAO на переводе откатывает весь
/// поток («ни перевода, ни платежа», §4), гонка «долг удалён» — notFound.
Future<void> showDebtPaymentDialog(BuildContext context, {required Debt debt}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => _DebtPaymentDialog(debt: debt),
  );
}

class _DebtPaymentDialog extends ConsumerStatefulWidget {
  const _DebtPaymentDialog({required this.debt});

  final Debt debt;

  @override
  ConsumerState<_DebtPaymentDialog> createState() => _DebtPaymentDialogState();
}

class _DebtPaymentDialogState extends ConsumerState<_DebtPaymentDialog> {
  // Сумма гашения — в валюте долга (§4): из неё создаётся платёж.
  final TextEditingController _amount = TextEditingController();
  // Сумма списания связанного перевода — в валюте счёта списания (D-17);
  // с D-90 — отдельный контроллер: у платежа и списания свои экспоненты.
  final TextEditingController _transferOut = TextEditingController();
  final TextEditingController _targetAmount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _outAccountId;
  String? _inAccountId;
  // Время формы — через шов [formClock] (§7, D-78): дата факта — UTC
  // в хранении, локально при показе.
  DateTime _date = formClock();
  bool _linkTransfer = false;
  // B4.1: сумма зачисления была предзаполнена оценкой по текущему курсу —
  // до первой правки поля видна подсказка transferPrefillNote.
  bool _targetPrefilled = false;
  bool _busy = false;

  Debt get _debt => widget.debt;

  @override
  void dispose() {
    _amount.dispose();
    _transferOut.dispose();
    _targetAmount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _date.toLocal(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _date = picked);
    }
  }

  String _formatDate(BuildContext context) =>
      MaterialLocalizations.of(context).formatMediumDate(_date.toLocal());

  Account? _accountOf(List<Account> accounts, String? id) =>
      accounts.where((Account account) => account.id == id).firstOrNull;

  String _symbolOf(String? code) =>
      ref.watch(currenciesMapProvider).value?[code]?.symbol ?? (code ?? '');

  /// Оценка суммы зачисления по текущим курсам справочника (образец
  /// `_prefillTargetMinor` формы перевода, B4.1): обе валюты в
  /// справочнике — cross-конвертация; суммы нет — NULL (поле пустое).
  int? _prefillTargetMinor(List<Account> accounts) {
    final Account? from = _accountOf(accounts, _outAccountId);
    final Account? to = _accountOf(accounts, _inAccountId);
    if (from == null || to == null) {
      return null;
    }
    // Сумма списания живёт в поле перевода и парсится экспонентом
    // счёта списания (D-90) — не экспонентом долга.
    final int? amountMinor = parseAmountToMinor(
      _transferOut.text,
      exponent: currencyExponentByCode(from.currencyCode),
    );
    if (amountMinor == null) {
      return null;
    }
    final Map<String, Currency> currencies =
        ref.read(currenciesMapProvider).value ?? const <String, Currency>{};
    final Currency? fromCurrency = currencies[from.currencyCode];
    final Currency? toCurrency = currencies[to.currencyCode];
    if (fromCurrency == null || toCurrency == null) {
      return null;
    }
    return convertMinorCross(
      amountMinor,
      fromCurrency.rateToBase,
      toCurrency.rateToBase,
      fromExponent: currencyExponentByCode(fromCurrency.code),
      toExponent: currencyExponentByCode(toCurrency.code),
    );
  }

  /// Обновляет предзаполнение суммы зачисления оценкой по текущему курсу
  /// (образец B4.1, спека §4: «Предзаполнено по текущему курсу»).
  void _updatePrefill(List<Account> accounts) {
    final Account? to = _accountOf(accounts, _inAccountId);
    final int? prefillMinor = _prefillTargetMinor(accounts);
    if (prefillMinor != null) {
      _targetAmount.text = minorToMajorString(
        prefillMinor,
        exponent: currencyExponentByCode(to?.currencyCode ?? ''),
      ).replaceAll('.', ',');
      _targetPrefilled = true;
    } else {
      _targetAmount.clear();
      _targetPrefilled = false;
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    // Платёж — из поля платежа, экспонентом валюты долга (§4, D-81.в);
    // поле списания связки в платёж не попадает (D-90).
    final int exponent = currencyExponentByCode(_debt.currencyCode);
    final int? amountMinor = parseAmountToMinor(
      _amount.text,
      exponent: exponent,
    );
    // Спеченный текст суммы гашения (§4/D-101): валидатор поля перехватывает
    // пустоту — сюда доходит только непарсабельная сумма.
    if (amountMinor == null) {
      await showSnack(context, l10n.amountInvalid);
      return;
    }
    setState(() => _busy = true);
    final DebtsController controller = ref.read(
      debtsControllerProvider.notifier,
    );
    final Result<dynamic> result;
    try {
      if (_linkTransfer) {
        final List<Account> accounts =
            ref.read(accountsProvider).value ?? const <Account>[];
        final Account? from = _accountOf(accounts, _outAccountId);
        final Account? to = _accountOf(accounts, _inAccountId);
        // Валидаторы полей не пускают сюда без счетов и с равными
        // счетами; guard против будущих правок формы.
        if (from == null || to == null || from.id == to.id) {
          await showSnack(context, l10n.errorInvalidInput);
          return;
        }
        final bool multiCurrency = from.currencyCode != to.currencyCode;
        // Списание — из поля перевода, экспонентом счёта списания (D-17);
        // платёж (в валюте долга) и списание — независимые суммы (D-90).
        // При равных валютах поле списания одно с платежом (D-17) — та же
        // сумма, своего поля нет.
        final int outExponent = currencyExponentByCode(from.currencyCode);
        final int? outAmountMinor = multiCurrency
            ? parseAmountToMinor(_transferOut.text, exponent: outExponent)
            : amountMinor;
        if (outAmountMinor == null) {
          // Спеченный текст суммы списания (§4/D-101): поле списания —
          // та же сумма гашения, канон — amountInvalid.
          await showSnack(context, l10n.amountInvalid);
          return;
        }
        final int? targetAmountMinor = multiCurrency
            ? parseAmountToMinor(
                _targetAmount.text,
                exponent: currencyExponentByCode(to.currencyCode),
              )
            : null;
        if (multiCurrency && targetAmountMinor == null) {
          // Спеченный текст суммы зачисления (§4/D-101, D-102): у третьей
          // суммы связки — своё указание.
          await showSnack(context, l10n.transferAmountInvalid);
          return;
        }
        result = await controller.recordPaymentWithTransfer(
          debtId: _debt.id,
          amountMinor: amountMinor,
          paidAt: _date,
          transfer: DebtTransferData(
            outAccountId: from.id,
            inAccountId: to.id,
            amountMinor: outAmountMinor,
            targetAmountMinor: targetAmountMinor,
            note: _note.text.trim().isEmpty ? null : _note.text,
            date: _date,
          ),
        );
      } else {
        result = await controller.recordPayment(
          debtId: _debt.id,
          amountMinor: amountMinor,
          paidAt: _date,
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
      // Отказ DAO (в т.ч. notFound при гонке «долг удалён») — снек;
      // связка откатилась целиком («ни перевода, ни платежа», §4).
      await showDataFailureSnack(context, result.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Account> accounts =
        ref.watch(accountsProvider).value ?? const <Account>[];

    // Умолчания при первом построении: списание — первый живой счёт,
    // зачисление — первый счёт в валюте долга (§4: валюта зачисления —
    // валюта долга). Счёт списания = зачислению быть не должно.
    if (_outAccountId == null && accounts.isNotEmpty) {
      _outAccountId = accounts.first.id;
    }
    if (_inAccountId == null) {
      final Account? match = accounts
          .where(
            (Account account) =>
                account.currencyCode == _debt.currencyCode &&
                account.id != _outAccountId,
          )
          .firstOrNull;
      _inAccountId = match?.id;
    }

    final Account? out = _accountOf(accounts, _outAccountId);
    final Account? into = _accountOf(accounts, _inAccountId);
    final int debtExponent = currencyExponentByCode(_debt.currencyCode);
    final bool multiCurrency =
        _linkTransfer &&
        out != null &&
        into != null &&
        out.currencyCode != into.currencyCode;
    final int outExponent = currencyExponentByCode(out?.currencyCode ?? '');
    final int intoExponent = currencyExponentByCode(into?.currencyCode ?? '');

    // Расчётная строка курса (образец формы перевода, B4.1/§4).
    final int? fromMinor = multiCurrency
        ? parseAmountToMinor(_transferOut.text, exponent: outExponent)
        : null;
    final int? toMinor = multiCurrency
        ? parseAmountToMinor(_targetAmount.text, exponent: intoExponent)
        : null;
    final String? rateLine = fromMinor != null && toMinor != null
        ? l10n.transferRateLine(
            out?.currencyCode ?? '',
            formatRate(
              derivedRate(
                fromMinor,
                toMinor,
                fromExponent: outExponent,
                toExponent: intoExponent,
              ),
            ),
            into?.currencyCode ?? '',
          )
        : null;

    return AlertDialog(
      title: Text(l10n.debtPaymentFormTitle),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              // Сумма гашения — в валюте долга (§4): суффикс — валюта долга,
              // не счёта (у связанного перевода суммы свои, ниже).
              AmountField(
                key: ValueKey<String>('payment-$debtExponent'),
                controller: _amount,
                labelText: l10n.debtPaymentAmountLabel,
                exponent: debtExponent,
                hintText: '0,00',
                suffixText: _symbolOf(_debt.currencyCode),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${l10n.debtPaymentDateLabel}: ${_formatDate(context)}',
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.dateLabel,
                    onPressed: _busy ? null : _pickDate,
                    icon: const Icon(Icons.calendar_month_outlined),
                  ),
                ],
              ),
              // Переключатель «Связать с переводом» (§4): выкл — платёж
              // без перевода (по умолчанию), вкл — связка одним потоком.
              SwitchListTile(
                value: _linkTransfer,
                onChanged: _busy
                    ? null
                    : (bool value) {
                        setState(() {
                          _linkTransfer = value;
                          if (value) {
                            _updatePrefill(accounts);
                          } else {
                            _targetAmount.clear();
                            // Поле списания живёт только со связкой (D-90):
                            // выключили — очистить.
                            _transferOut.clear();
                            _targetPrefilled = false;
                          }
                        });
                      },
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.debtPaymentLinkTransfer),
              ),
              if (_linkTransfer) ...<Widget>[
                DropdownButtonFormField<String>(
                  initialValue: _outAccountId,
                  decoration: InputDecoration(
                    labelText: l10n.debtTransferOutAccount,
                  ),
                  validator: (String? value) =>
                      value == null ? l10n.selectAccountValidator : null,
                  items: accounts
                      .map(
                        (Account account) => DropdownMenuItem<String>(
                          value: account.id,
                          child: Text(account.name),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) {
                    setState(() {
                      if (value != _outAccountId) {
                        _outAccountId = value;
                        // Совпадение с зачислением сбрасывает зачисление
                        // (образец формы перевода, D-28.г).
                        if (_inAccountId == value) {
                          _inAccountId = null;
                        }
                        // Равные валюты — поле списания исчезает (D-17):
                        // невидимый текст не должен стать суммой перевода.
                        final Account? nextOut = _accountOf(accounts, value);
                        final Account? nextIn = _accountOf(
                          accounts,
                          _inAccountId,
                        );
                        if (nextIn == null ||
                            nextOut?.currencyCode == nextIn.currencyCode) {
                          _transferOut.clear();
                        }
                        _updatePrefill(accounts);
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _inAccountId,
                  decoration: InputDecoration(
                    labelText: l10n.debtTransferInAccount,
                  ),
                  validator: (String? value) =>
                      value == null ? l10n.selectAccountValidator : null,
                  items: accounts
                      .where((Account account) => account.id != _outAccountId)
                      .map(
                        (Account account) => DropdownMenuItem<String>(
                          value: account.id,
                          child: Text(account.name),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) {
                    setState(() {
                      if (value != _inAccountId) {
                        _inAccountId = value;
                        _updatePrefill(accounts);
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                if (multiCurrency) ...<Widget>[
                  // Две суммы по D-17 (образец B4.1): «Списано» — валюта
                  // счёта списания, «Зачислено» — валюта долга. У списания
                  // свой контроллер (D-90): платёж и списание независимы.
                  AmountField(
                    key: ValueKey<String>('out-$outExponent'),
                    controller: _transferOut,
                    labelText: l10n.transferAmountOut,
                    onChanged: (String value) {
                      if (!_targetPrefilled && _targetAmount.text.isNotEmpty) {
                        return;
                      }
                      setState(() => _updatePrefill(accounts));
                    },
                    exponent: outExponent,
                    suffixText: _symbolOf(out.currencyCode),
                  ),
                  const SizedBox(height: 12),
                  AmountField(
                    key: ValueKey<String>('target-$intoExponent'),
                    controller: _targetAmount,
                    labelText: l10n.transferAmountIn,
                    onChanged: (String value) {
                      if (_targetPrefilled) {
                        setState(() => _targetPrefilled = false);
                      }
                    },
                    exponent: intoExponent,
                    suffixText: _symbolOf(into.currencyCode),
                  ),
                  if (_targetPrefilled)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.transferPrefillNote,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (rateLine != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        rateLine,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _note,
                  decoration: InputDecoration(labelText: l10n.debtTransferNote),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        // §4: при связке кнопка «Записать» (одним потоком), без связки —
        // тоже запись гашения (диалог один, подпись подтверждает действие).
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(
            _linkTransfer
                ? l10n.debtTransferRecordAction
                : l10n.debtRecordPaymentAction,
          ),
        ),
      ],
    );
  }
}
