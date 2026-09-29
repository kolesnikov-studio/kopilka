import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
// Глиф в пунктах выбора категории (M5-шаг 2): categories_screen — экран,
// но categoryIcon — единственный рендер глифа с заглушкой NULL (D-55);
// категории при этом по-прежнему приходят через categoriesByKindProvider.
import 'package:kopilka/features/categories/categories_screen.dart'
    show categoryIcon;
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/rate.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/data/providers.dart';
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
  final TextEditingController _targetAmount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _accountId;
  String? _targetAccountId;
  String? _categoryId;
  DateTime _date = DateTime.now();
  bool _busy = false;
  // B4.1: вторая сумма была предзаполнена оценкой по текущему курсу —
  // до первой правки поля под ним видна подсказка transferPrefillNote.
  bool _targetPrefilled = false;

  @override
  void dispose() {
    _amount.dispose();
    _targetAmount.dispose();
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

  /// Умолчания при первом построении: первый живой счёт, без категории.
  String? _ensureDefaults(List<Account> accounts) {
    if (_accountId == null && accounts.isNotEmpty) {
      _accountId = accounts.first.id;
    }
    return _accountId;
  }

  Account? _accountOf(List<Account> accounts, String? id) => accounts
      .where((Account account) => account.id == id)
      .firstOrNull;

  /// Символ валюты счёта из справочника (R5); код вне справочника —
  /// fallback на сам код. Watch: держит подписку на карту валют живой —
  /// read до первой эмиссии потока давал бы вечный fallback (нашлось
  /// виджет-тестом B4.1).
  String _symbolOf(String? code) =>
      ref.watch(currenciesMapProvider).value?[code]?.symbol ?? (code ?? '');

  /// Оценка суммы зачисления по текущим курсам справочника (B4.1):
  /// обе валюты в справочнике — cross-конвертация по rate_to_base;
  /// хотя бы одной валюты нет — null (поле остаётся пустым, без ошибки).
  int? _prefillTargetMinor(List<Account> accounts) {
    final Account? from = _accountOf(accounts, _accountId);
    final Account? to = _accountOf(accounts, _targetAccountId);
    if (from == null || to == null) {
      return null;
    }
    final int? amountMinor = parseAmountToMinor(
      _amount.text,
      exponent: currencyExponentByCode(from.currencyCode),
    );
    if (amountMinor == null) {
      return null;
    }
    // Карта валют уже подписана в build (_symbolOf); здесь достаточно
    // разового чтения — форма перестраивается при каждой правке полей.
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
      fromExponent: currencyExponentByCode(from.currencyCode),
      toExponent: currencyExponentByCode(to.currencyCode),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    // U9: тихий выход при пустом счёте заменён подсветкой dropdown
    // (валидатор ниже); здесь guard остаётся на случай будущих правок —
    // исключение после `_busy = true` заморозило бы кнопки диалога.
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
    // Дробность — по экспоненту валюты счёта (B3/D-27), той же, по которой
    // валидирует поле. Форма до вызова проверила суммы на > 0, поэтому
    // `!` здесь безопасен; null после валидной формы означает, что парсер
    // согласован с валидатором поля.
    final List<Account> accounts =
        ref.read(accountsProvider).value ?? const <Account>[];
    final Account? account = _accountOf(accounts, _accountId);
    final int amountMinor = parseAmountToMinor(
      _amount.text,
      exponent: currencyExponentByCode(account?.currencyCode ?? ''),
    )!;
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
        // B4.1/D-17: у мультивалютного перевода обе суммы обязательны
        // (валидация полей выше), у одно-валютного второй суммы нет —
        // DAO отвергнет значение при совпадающих валютах (D-17).
        final Account? target = _accountOf(accounts, _targetAccountId);
        final bool multiCurrency = target != null &&
            target.currencyCode != account?.currencyCode;
        final int? targetAmountMinor = multiCurrency
            ? parseAmountToMinor(
                _targetAmount.text,
                exponent: currencyExponentByCode(target.currencyCode),
              )
            : null;
        result = await controller.createTransfer(
          accountId: _accountId!,
          targetAccountId: _targetAccountId!,
          amountMinor: amountMinor,
          targetAmountMinor: targetAmountMinor,
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
    _ensureDefaults(accounts);
    // B3: валюта выбранного счёта задаёт дробность и суффикс поля суммы;
    // код вне справочника — fallback на сам код.
    final Account? selected = _accountOf(accounts, _accountId);
    final int exponent =
        currencyExponentByCode(selected?.currencyCode ?? '');
    final String amountSuffix = _symbolOf(selected?.currencyCode);

    // B4.1: у перевода между валютами — два поля суммы с разными валютами.
    final Account? target = _accountOf(accounts, _targetAccountId);
    final bool multiCurrency = widget.type == TransactionType.transfer &&
        target != null &&
        target.currencyCode != selected?.currencyCode;
    final int targetExponent =
        currencyExponentByCode(target?.currencyCode ?? '');
    final String targetAmountSuffix = _symbolOf(target?.currencyCode);

    // Расчётная строка курса (B4.1): производное отношение введённых сумм,
    // пересчитывается при вводе любой из них. Курс — до 6 значащих знаков
    // (D-26, formatRate шага 2); формат — «1 USD = 97,5 ₽» (спека B4.1).
    final int? fromMinor = multiCurrency
        ? parseAmountToMinor(
            _amount.text,
            exponent: exponent,
          )
        : null;
    final int? toMinor = multiCurrency
        ? parseAmountToMinor(
            _targetAmount.text,
            exponent: targetExponent,
          )
        : null;
    final String? rateLine = fromMinor != null && toMinor != null
        ? l10n.transferRateLine(
            selected?.currencyCode ?? '',
            formatRate(derivedRate(
              fromMinor,
              toMinor,
              fromExponent: exponent,
              toExponent: targetExponent,
            )),
            target?.currencyCode ?? '',
          )
        : null;

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
                  // U8: у поля свой ключ («Счёт»), navAccounts — навигация.
                  labelText: widget.type == TransactionType.transfer
                      ? l10n.accountFrom
                      : l10n.accountLabel,
                ),
                // U9: без выбранного счёта — подсветка текстом валидатора
                // вместо тихого невызова _submit.
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
                    if (value != _accountId) {
                      _accountId = value;
                      // Dropdown зачисления исключает счёт списания, но
                      // списание выбирается из полного списка: совпадение
                      // сбрасывает зачисление (иначе value dropdown'а
                      // остаётся вне его items — падение на assert).
                      if (_targetAccountId == value) {
                        _targetAccountId = null;
                      }
                      // Валюта счёта сменилась — поле суммы очищается
                      // (B3: просто и предсказуемо, без
                      // пересчёта введённого текста). Вторая сумма
                      // пересчитывается под новую валюту (очистится,
                      // если оценки ещё нет — первая сумма пуста).
                      _amount.clear();
                      if (widget.type == TransactionType.transfer) {
                        _updatePrefill(accounts);
                      }
                    }
                  });
                },
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
                  onChanged: (String? value) {
                    setState(() {
                      if (value != _targetAccountId) {
                        _targetAccountId = value;
                        // B4.1: умное предзаполнение оценки зачисления по
                        // текущему курсу справочника; правка счёта — новая
                        // оценка, прежнее значение пользователя не переживает
                        // (валюта поля сменилась — D-27).
                        _updatePrefill(accounts);
                      }
                    });
                  },
                ),
              ],
              const SizedBox(height: 12),
              if (widget.type != TransactionType.transfer) ...<Widget>[
                DropdownButtonFormField<String?>(
                  initialValue: _categoryId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.categoryLabel),
                  items: <DropdownMenuItem<String?>>[
                    DropdownMenuItem<String?>(
                      child: Text(l10n.filterAll),
                    ),
                    for (final Category category in categories)
                      DropdownMenuItem<String?>(
                        value: category.id,
                        child: Row(
                          children: <Widget>[
                            categoryIcon(category),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                category.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (String? value) =>
                      setState(() => _categoryId = value),
                ),
                const SizedBox(height: 12),
              ],
              if (multiCurrency) ...<Widget>[
                // B4.1: две суммы — «Списано» (валюта счёта списания) и
                // «Зачислено» (валюта счёта зачисления), каждая по экспоненту
                // своей валюты (D-27). Обе обязательны (> 0).
                AmountField(
                  key: ValueKey<int>(exponent),
                  controller: _amount,
                  labelText: l10n.transferAmountOut,
                  onChanged: (String value) {
                    // Умное предзаполнение следует за вводом суммы
                    // списания (B4.1), пока пользователь не начал править
                    // сумму зачисления сам.
                    if (!_targetPrefilled && _targetAmount.text.isNotEmpty) {
                      return;
                    }
                    setState(() => _updatePrefill(accounts));
                  },
                  exponent: exponent,
                  suffixText: amountSuffix,
                ),
                const SizedBox(height: 12),
                AmountField(
                  key: ValueKey<String>('target-$targetExponent'),
                  controller: _targetAmount,
                  labelText: l10n.transferAmountIn,
                  onChanged: (String value) {
                    if (_targetPrefilled) {
                      setState(() => _targetPrefilled = false);
                    }
                  },
                  exponent: targetExponent,
                  suffixText: targetAmountSuffix,
                ),
                if (_targetPrefilled)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.transferPrefillNote,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                if (rateLine != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      rateLine,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
              ] else ...<Widget>[
                // Одна сумма: у не-перевода — валюта счёта; у перевода
                // между счетами одной валюты — тоже одна сумма (B4.1),
                // вторая не показывается вовсе (не disabled).
                AmountField(
                  key: ValueKey<int>(exponent),
                  controller: _amount,
                  exponent: exponent,
                  suffixText: amountSuffix,
                ),
              ],
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

  /// Обновляет предзаполнение суммы зачисления оценкой по текущему курсу
  /// (B4.1): обе валюты в справочнике и сумма списания введена — поле
  /// заполняется оценкой и помечается подсказкой transferPrefillNote;
  /// иначе поле очищается — пользователь вводит сумму сам, без ошибки
  /// (B4.1: «поле пустое, без ошибки»).
  void _updatePrefill(List<Account> accounts) {
    final int? prefillMinor = _prefillTargetMinor(accounts);
    if (prefillMinor != null) {
      final Account? to = _accountOf(accounts, _targetAccountId);
      // minorToMajorString отдаёт канонический разделитель «.» (CSV, A14);
      // поле ввода принимает и запятую, но подсказываем в конвенции ввода
      // приложения (parseAmountToMinor: запятая — десятичный разделитель).
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
}
