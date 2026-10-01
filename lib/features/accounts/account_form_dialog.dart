import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/accounts/accounts_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог формы счёта. При `account == null` создаёт счёт, иначе редактирует.
///
/// [savingsPreset] (M6-шаг D, D-92.3): преселект тумблера «Накопительный»
/// и дефолтной даты напоминания (сегодня + 1 календарный месяц UTC) —
/// для CTA совета дашборда; без параметра форма как раньше (нулевые
/// отличия для существующих вызовов).
///
/// Валюта (B2.1/B2.2, D-24): при создании — dropdown по живым валютам
/// справочника с дефолтом «базовая»; при правке валюта показывается строкой
/// без правки, и только у счёта без операций есть кнопка «Сменить валюту»
/// (DAO-отказ `accountHasTransactions` остаётся последней линией).
///
/// Отказы DAO объясняются пользователю снекбаром с локализованным текстом
/// по машиночитаемому виду отказа.
Future<void> showAccountFormDialog(
  BuildContext context, {
  AccountBalance? account,
  bool savingsPreset = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _AccountFormDialog(initial: account, savingsPreset: savingsPreset),
  );
}

class _AccountFormDialog extends ConsumerStatefulWidget {
  const _AccountFormDialog({this.initial, this.savingsPreset = false});

  final AccountBalance? initial;

  /// CTA совета (D-92.3): тумблер «Накопительный» включён и дата —
  /// дефолт «сегодня + 1 месяц»; применяется только при создании.
  final bool savingsPreset;

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

  /// Флаг «не учитывать в балансе» (M5/D-54): при создании выключен,
  /// при правке — текущее значение счёта.
  bool _excludeFromBalance = false;

  /// Накопительный счёт (M6-шаг D, D-81): при создании выключен (или
  /// преселект CTA совета), при правке — есть дата напоминания.
  bool _savings = false;

  /// Дата напоминания о процентах (v7/D-81): локальная зона в UI,
  /// хранение — полуночный UTC (§3). Видна только при включённом
  /// тумблере; выключение тумблера обнуляет дату.
  DateTime? _interestDate;

  /// Дата в сабмит входит, только если пользователь её менял или
  /// тумблер менял состояние (см. _submit): иначе `Value.absent()`
  /// (конвенция A1 — поле БД не трогается).
  bool _interestDateChanged = false;

  /// Состояние тумблера на момент открытия формы: для правки — было ли
  /// поле даты изменено (сабмит Companion-параметром, спека §1).
  late final bool _initialSavings;

  /// Б2.2: виден ли у счёта в режиме правки выбор валюты (счёт без операций).
  bool _canChangeCurrency = false;

  @override
  void initState() {
    super.initState();
    final AccountBalance? initial = widget.initial;
    _initialSavings = initial?.account.interestReminderDate != null;
    if (initial != null) {
      _name.text = initial.account.name;
      _kind = AccountKind.fromDb(initial.account.kind);
      _currencyCode = initial.account.currencyCode;
      _excludeFromBalance = initial.account.excludeFromBalance ?? false;
      // M6-шаг D: предзаполнение из interestReminderDate (D-81/D-82);
      // строка UTC парсится в локальную зону для показа. Битая строка
      // (терпимость схемы D-81) — дефолт, форма не падает.
      final String? interest = initial.account.interestReminderDate;
      if (interest != null && interest.isNotEmpty) {
        _savings = true;
        _interestDate =
            DateTime.tryParse(interest)?.toLocal() ??
            defaultInterestReminderDate();
      }
      // Поле «Сумма» при редактировании означает НОВЫЙ начальный баланс:
      // предзаполняем его initial_balance_minor, не вычисленным балансом
      // (§3: баланс считается из истории, полями его не правят). Масштаб —
      // по экспоненту валюты счёта (R2: minorToMajorString).
      _balance.text = minorToMajorString(
        initial.account.initialBalanceMinor,
        exponent: currencyExponentByCode(initial.account.currencyCode),
      );
      // Б2.2: кнопка «Сменить валюту» — только пока операций нет; признак
      // читается один раз при открытии, DAO-отказ остаётся последней линией.
      _canChangeCurrency = false;
      _refreshCanChangeCurrency();
    } else if (widget.savingsPreset) {
      // CTA совета (D-92.3): тумблер включён, дата — дефолт
      // «сегодня + 1 календарный месяц» UTC (D-81/D-14).
      _savings = true;
      _interestDate = defaultInterestReminderDate();
    }
  }

  Future<void> _refreshCanChangeCurrency() async {
    final String id = widget.initial!.account.id;
    final bool hasTransactions = await ref
        .read(accountsControllerProvider.notifier)
        .hasAliveTransactions(id);
    if (mounted && widget.initial?.account.id == id) {
      setState(() => _canChangeCurrency = !hasTransactions);
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

  /// Меняет валюту счёта при редактировании. Доступна только для счёта
  /// без операций (B2.2/D-24); DAO-отказ `accountHasTransactions` остаётся
  /// последней линией: между открытием формы и записью могла появиться
  /// операция (гонка) — объясняем снеком и закрываем выбор.
  Future<void> _showCurrencyPicker() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Currency> currencies =
        ref.read(currenciesProvider).value ?? const <Currency>[];
    final String current = _currencyCode ?? '';
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: Text(l10n.currencyLabel),
        children: <Widget>[
          for (final Currency currency in currencies)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(currency.code),
              child: Text(
                '${currency.symbol} ${currency.code} — '
                '${currencyNamesRu[currency.code] ?? currency.code}',
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == current || picked == _currencyCode) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _currencyCode = picked);
    // Смена валюты — поле суммы очищается (B3): пересчёт
    // введённого текста не делаем.
    _balance.clear();
  }

  /// Дефолтная дата напоминания (D-81/D-92): сегодня (utcNow) + 1
  /// календарный месяц, тот же день следующего месяца (D-14),
  /// полночь UTC (§3).
  DateTime defaultInterestReminderDate() {
    final DateTime now = utcNow();
    return DateTime.utc(now.year, now.month + 1, now.day);
  }

  Future<void> _pickInterestDate() async {
    // Пикер стартует с текущего значения строки (спека §1); прошедшая
    // дата не блокируется — просрочка напоминания штатна (D-81/D-92).
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _interestDate ?? defaultInterestReminderDate().toLocal(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _interestDate = picked;
        _interestDateChanged = true;
      });
    }
  }

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
    //
    // Дробность — по экспоненту выбранной валюты (B3): в форме счёта это
    // валюта в dropdown'е (при правке — существующая валюта счёта).
    // Дробность — по экспоненту выбранной валюты (B3): в форме счёта это
    // валюта в dropdown'е, при правке — текущая (_currencyCode, который
    // меняется кнопкой «Сменить валюту» у пустого счёта).
    final String exponentCode = editing
        ? (_currencyCode ?? widget.initial!.account.currencyCode)
        : (_currencyCode ?? '');
    final int exponent = currencyExponentByCode(exponentCode);
    final int? parsedMinor = parseAmountToMinor(
      _balance.text,
      allowZero: editing,
      exponent: exponent,
    );
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
    // Дата напоминания (M6-шаг D, спека §1): сабмит Companion-параметром
    // (конвенция A1). Дата входит в запрос, только если тумблер или дата
    // менялись: включение тумблера — Value(дата) (при выключенном даты
    // нет), выключение — Value(null) (счёт снова обычный, D-81); правка
    // без касания тумблера/даты — Value.absent() (поле БД не трогается).
    final bool savingsTouched = !editing || _savings != _initialSavings;
    final DateTime? interestDate = _savings && _interestDate != null
        ? DateTime.utc(
            _interestDate!.year,
            _interestDate!.month,
            _interestDate!.day,
          )
        : null;
    final Value<DateTime?> interestPatch =
        savingsTouched || _interestDateChanged
        ? Value<DateTime?>(interestDate)
        : const Value<DateTime?>.absent();
    final Result<dynamic> result;
    try {
      if (!editing) {
        result = await controller.createAccount(
          name: _name.text,
          kind: _kind,
          currencyCode: currencyCode!,
          initialBalanceMinor: initialMinor,
          excludeFromBalance: _excludeFromBalance,
          // При создании форма всегда пишет дату целиком: включённый
          // тумблер несёт дату (преселект или дефолт), выключенный — NULL.
          interestReminderDate: interestDate,
        );
      } else {
        // Б2.2/D-24: смена валюты счёта в UI — только для счёта без операций
        // (и только явной кнопкой). В обычной правке валютное поле в запрос
        // не входит вовсе (Value.absent()).
        final Value<String> currencyPatch =
            (_canChangeCurrency &&
                currencyCode != null &&
                currencyCode != widget.initial!.account.currencyCode)
            ? Value<String>(currencyCode)
            : const Value<String>.absent();
        result = await controller.updateAccount(
          widget.initial!.account.id,
          name: Value<String>(_name.text),
          kind: Value<AccountKind>(_kind),
          currencyCode: currencyPatch,
          initialBalanceMinor: Value<int>(initialMinor),
          excludeFromBalance: Value<bool>(_excludeFromBalance),
          interestReminderDate: interestPatch,
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
      // Гонка B2.2: кнопка была показана (операций не было), но к моменту
      // сохранения операция появилась и DAO отказал — отказ объясняется
      // снеком (accountHasTransactions), поле остаётся в прежнем значении.
      await showDataFailureSnack(context, result.failure);
      if (result.failure == DataFailure.accountHasTransactions) {
        setState(() => _canChangeCurrency = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Currency> currencies =
        ref.watch(currenciesProvider).value ?? const <Currency>[];
    final bool editing = widget.initial != null;

    // B2.1: дефолт валюты нового счёта — базовая (учёт в одной валюте —
    // в один тап), а не первая по алфавиту. При правке код не трогаем.
    if (!editing && _currencyCode == null) {
      final String? baseCode = baseCurrencyOf(currencies)?.code;
      if (baseCode != null) {
        _currencyCode = baseCode;
      }
    }
    final int buildExponent = currencyExponentByCode(
      editing
          ? (_currencyCode ?? widget.initial!.account.currencyCode)
          : (_currencyCode ?? ''),
    );
    // Символ выбранной валюты — суффикс поля суммы (B3); карта R5 реактивна:
    // код вне справочника — fallback на сам код.
    final String amountSuffix =
        ref.watch(currenciesMapProvider).value?[_currencyCode]?.symbol ??
        (_currencyCode ?? '');

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
                validator: (String? value) =>
                    (value == null || value.trim().isEmpty)
                    ? l10n.errorInvalidInput
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<AccountKind>(
                initialValue: _kind,
                decoration: InputDecoration(labelText: l10n.kindLabel),
                items:
                    <AccountKind>[
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
              // B2.1: dropdown по живым валютам справочника («Символ Код —
              // Название»); B2.2/D-24: в правке вместо отключённого
              // dropdown'а — строка без правки, смена — только явной кнопкой
              // у счёта без операций.
              if (!editing)
                DropdownButtonFormField<String>(
                  initialValue: _currencyCode,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l10n.currencyLabel),
                  // Без валюты DAO отклонит создание — валидируем до отправки.
                  validator: (String? code) =>
                      code == null ? l10n.selectCurrencyValidator : null,
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
                  onChanged: (String? code) {
                    setState(() {
                      _currencyCode = code;
                      // Смена валюты — поле суммы очищается (B3):
                      // пересчёт введённого текста не делаем.
                      _balance.clear();
                    });
                  },
                )
              else ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.accountCurrencyRow(
                          _symbolOf(_currencyCode),
                          _currencyCode ?? '',
                        ),
                      ),
                    ),
                    // Кнопка — только пока у счёта нет операций (B2.2);
                    // у счёта с операциями — только строка.
                    if (_canChangeCurrency)
                      TextButton(
                        onPressed: _busy ? null : _showCurrencyPicker,
                        child: Text(l10n.accountCurrencyChangeAction),
                      ),
                  ],
                ),
                if (_canChangeCurrency)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.accountCurrencyLockedHint,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              // При редактировании поле — новый начальный баланс: ноль
              // корректен, поэтому и поле формы, и парсер в _submit
              // допускают его (allowZero). U12: placeholder подсказывает,
              // что поле можно оставить пустым. B3: дробность поля — по
              // экспоненту валюты (экспонент 0 не даёт ввести разделитель).
              AmountField(
                key: ValueKey<int>(buildExponent),
                controller: _balance,
                allowZero: editing,
                exponent: buildExponent,
                hintText: '0,00',
                suffixText: amountSuffix,
              ),
              // M5/D-54: флаг «не учитывать в балансе» — под ним
              // подсказка о последствии (по образцу hint Dz-1/D-48):
              // счёт выпадает из общего баланса отчётов, персональный
              // баланс не меняется.
              SwitchListTile(
                value: _excludeFromBalance,
                onChanged: _busy
                    ? null
                    : (bool value) =>
                          setState(() => _excludeFromBalance = value),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.excludeFromBalanceLabel),
                subtitle: Text(
                  l10n.excludeFromBalanceHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // M6-шаг D (спека §1, D-81): тумблер «Накопительный» —
              // после флага «не учитывать в балансе», в том же стиле.
              // Проценты пользователь начисляет сам, переводом —
              // UI «начислить» не проектируется (D-81).
              SwitchListTile(
                key: const ValueKey<String>('accountSavingsTile'),
                value: _savings,
                onChanged: _busy
                    ? null
                    : (bool value) => setState(() {
                        _savings = value;
                        // Выключение тумблера — дата NULL (спека §1):
                        // строка скрыта, счёт снова обычный (D-81).
                        if (!value) {
                          _interestDate = null;
                        } else {
                          _interestDate ??= defaultInterestReminderDate();
                        }
                        _interestDateChanged = true;
                      }),
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.accountSavingsLabel),
                subtitle: Text(
                  l10n.accountSavingsHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // Строка даты — только при включённом тумблере (спека §1):
              // показ — локальная дата (§3), правка — пикером; прошедшая
              // дата не блокируется (просрочка штатна, D-81).
              if (_savings)
                Row(
                  key: const ValueKey<String>('accountInterestDateRow'),
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${l10n.accountInterestDateLabel}: '
                        '${MaterialLocalizations.of(context).formatMediumDate(_interestDate!)}',
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _pickInterestDate,
                      child: Text(l10n.accountInterestDateEditAction),
                    ),
                  ],
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

  /// Символ по карте справочника (R5); код вне справочника — fallback на код.
  String _symbolOf(String? code) =>
      ref.read(currenciesMapProvider).value?[code]?.symbol ?? (code ?? '');
}
