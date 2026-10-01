import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/accounts/accounts_controller.dart'
    show currenciesProvider;
import 'package:kopilka/features/debts/debts_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог формы долга (спека §3): при `debt == null` создаёт долг, иначе
/// редактирует. Поля — D-82 дословно: человек (непустой), направление
/// (сегменты), валюта (живой справочник), тело долга (> 0), переплата
/// (>= 0, необязательное), срок (необязательная дата), примечание.
///
/// Отказы DAO объясняются снекбаром с локализованным текстом отказа; при
/// отказе диалог не закрывается (§3).
Future<void> showDebtFormDialog(
  BuildContext context, {
  Debt? debt,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => _DebtFormDialog(initial: debt),
  );
}

class _DebtFormDialog extends ConsumerStatefulWidget {
  const _DebtFormDialog({this.initial});

  final Debt? initial;

  @override
  ConsumerState<_DebtFormDialog> createState() => _DebtFormDialogState();
}

class _DebtFormDialogState extends ConsumerState<_DebtFormDialog> {
  final TextEditingController _person = TextEditingController();
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _extra = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  DebtDirection _direction = DebtDirection.theyOweMe;
  String? _currencyCode;
  DateTime? _dueDate;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final Debt? initial = widget.initial;
    if (initial != null) {
      _person.text = initial.person;
      _direction = DebtDirection.fromDb(initial.direction);
      _amount.text = minorToMajorString(
        initial.amountMinor,
        exponent: currencyExponentByCode(initial.currencyCode),
      );
      if (initial.extraMinor > 0) {
        _extra.text = minorToMajorString(
          initial.extraMinor,
          exponent: currencyExponentByCode(initial.currencyCode),
        );
      }
      _currencyCode = initial.currencyCode;
      // Хранение — UTC-строка (§3); выборка/показ — локальная дата.
      final String? due = initial.dueDate;
      if (due != null && due.isNotEmpty) {
        _dueDate = DateTime.tryParse(due)?.toLocal();
      }
      _note.text = initial.note ?? '';
    }
  }

  @override
  void dispose() {
    _person.dispose();
    _amount.dispose();
    _extra.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? formClock().toLocal(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _dueDate = picked);
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String currencyCode = _currencyCode ?? '';
    final int exponent = currencyExponentByCode(currencyCode);
    final int? amountMinor = parseAmountToMinor(
      _amount.text,
      exponent: exponent,
    );
    // Переплата необязательна: пустое поле = 0; заполненное обязано
    // парситься (>= 0, D-82) — валидатор поля и здесь страхуют.
    final int? extraMinor = _extra.text.trim().isEmpty
        ? 0
        : parseAmountToMinor(_extra.text, exponent: exponent);
    if (amountMinor == null || extraMinor == null) {
      await showSnack(context, l10n.errorInvalidInput);
      return;
    }
    setState(() => _busy = true);
    final DebtsController controller = ref.read(
      debtsControllerProvider.notifier,
    );
    final Result<dynamic> result;
    try {
      if (widget.initial == null) {
        result = await controller.createDebt(
          person: _person.text,
          direction: _direction,
          amountMinor: amountMinor,
          currencyCode: currencyCode,
          extraMinor: extraMinor,
          dueDate: _dueDate,
          note: _note.text.trim().isEmpty ? null : _note.text,
        );
      } else {
        result = await controller.updateDebt(
          widget.initial!.id,
          person: Value<String>(_person.text),
          direction: Value<DebtDirection>(_direction),
          amountMinor: Value<int>(amountMinor),
          extraMinor: Value<int>(extraMinor),
          currencyCode: Value<String>(currencyCode),
          dueDate: Value<DateTime?>(_dueDate),
          note: Value<String?>(_note.text.trim().isEmpty ? null : _note.text),
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
      // Отказ DAO (в т.ч. notFound при гонке) — снек, диалог не закрывается
      // (§3); повторное открытие после импорта/удаления — штатно.
      await showDataFailureSnack(context, result.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Currency> currencies =
        ref.watch(currenciesProvider).value ?? const <Currency>[];
    final bool editing = widget.initial != null;

    // Дефолт валюты нового долга — базовая (образец B2.1). При правке
    // код не трогаем.
    if (!editing && _currencyCode == null) {
      final String? baseCode = baseCurrencyOf(currencies)?.code;
      if (baseCode != null) {
        _currencyCode = baseCode;
      }
    }
    final int exponent = currencyExponentByCode(_currencyCode ?? '');
    final String amountSuffix = ref
        .watch(currenciesMapProvider)
        .value?[_currencyCode]
        ?.symbol ??
        (_currencyCode ?? '');

    return AlertDialog(
      title: Text(editing ? l10n.debtEditTitle : l10n.debtAddTitle),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              TextFormField(
                controller: _person,
                decoration: InputDecoration(labelText: l10n.debtPersonLabel),
                validator: (String? value) =>
                    (value == null || value.trim().isEmpty)
                        ? l10n.debtPersonRequired
                        : null,
              ),
              const SizedBox(height: 12),
              // Направление — SegmentedButton (§3): направление — суть
              // долга, два значения D-81.
              SegmentedButton<DebtDirection>(
                segments: <ButtonSegment<DebtDirection>>[
                  ButtonSegment<DebtDirection>(
                    value: DebtDirection.theyOweMe,
                    label: Text(l10n.debtDirectionTheyOweMe),
                  ),
                  ButtonSegment<DebtDirection>(
                    value: DebtDirection.iOweThem,
                    label: Text(l10n.debtDirectionIOweThem),
                  ),
                ],
                selected: <DebtDirection>{_direction},
                onSelectionChanged: (Set<DebtDirection> selection) {
                  if (selection.isNotEmpty) {
                    setState(() => _direction = selection.first);
                  }
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _currencyCode,
                isExpanded: true,
                decoration:
                    InputDecoration(labelText: l10n.debtCurrencyLabel),
                // Без валюты DAO отклонит создание — валидируем до отправки.
                validator: (String? code) =>
                    code == null ? l10n.errorInvalidInput : null,
                items: currencies
                    .map(
                      (Currency currency) => DropdownMenuItem<String>(
                        value: currency.code,
                        child: Text(
                          '${currency.symbol} ${currency.code} — '
                          '${currencyNamesRu[currency.code] ?? currency.code}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (String? code) =>
                    setState(() => _currencyCode = code),
              ),
              const SizedBox(height: 12),
              AmountField(
                key: ValueKey<int>(exponent),
                controller: _amount,
                labelText: l10n.debtAmountLabel,
                exponent: exponent,
                hintText: '0,00',
                suffixText: amountSuffix,
                // Спеченный текст ошибки (§3/D-90): не общий amountInvalid.
                invalidText: l10n.debtAmountInvalid,
              ),
              const SizedBox(height: 12),
              // Переплата необязательна («пустое = 0», §3/D-82): пустое
              // поле и ноль — корректные значения.
              AmountField(
                key: ValueKey<String>('extra-$exponent'),
                controller: _extra,
                labelText: l10n.debtExtraLabel,
                allowZero: true,
                allowEmpty: true,
                exponent: exponent,
                hintText: '0,00',
                suffixText: amountSuffix,
                // Спеченный текст ошибки переплаты (§3/D-90).
                invalidText: l10n.debtExtraInvalid,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.debtExtraHelper,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const SizedBox(height: 12),
              // Срок — необязательная дата (§3): пусто = нет срока.
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _dueDate == null
                          ? l10n.debtDueDateOptional
                          : '${l10n.debtDueDateLabel}: '
                              '${MaterialLocalizations.of(context).formatMediumDate(_dueDate!)}',
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.debtDueDateLabel,
                    onPressed: _busy ? null : _pickDueDate,
                    icon: const Icon(Icons.calendar_month_outlined),
                  ),
                  if (_dueDate != null)
                    IconButton(
                      tooltip: l10n.deleteAction,
                      onPressed: _busy
                          ? null
                          : () => setState(() => _dueDate = null),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              TextFormField(
                controller: _note,
                decoration: InputDecoration(labelText: l10n.debtNoteLabel),
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
