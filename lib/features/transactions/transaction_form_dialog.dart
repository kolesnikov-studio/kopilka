import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
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
import 'package:kopilka/features/planning/scheduled_transfers_controller.dart';
import 'package:kopilka/features/transactions/attachment_section.dart';
import 'package:kopilka/features/transactions/transactions_controller.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Форма быстрого ввода: тип задаётся кнопкой на списке операций
/// (расход/доход/перевод). Счёт по умолчанию — первый живой.
///
/// [existing] — режим правки отложенного перевода (спека D §4): форма
/// предзаполнена строкой списка «Планирование», секция «Отложить»
/// показана раскрытой без чекбокса, сохранение идёт через
/// `updateScheduledTransfer`; успех — закрытие без режима вложения.
Future<void> showTransactionFormDialog(
  BuildContext context, {
  required TransactionType type,
  ScheduledTransfer? existing,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _TransactionFormDialog(type: type, existing: existing),
  );
}

class _TransactionFormDialog extends ConsumerStatefulWidget {
  const _TransactionFormDialog({required this.type, this.existing});

  final TransactionType type;

  /// Правимый отложенный перевод; null — обычная форма ввода.
  final ScheduledTransfer? existing;

  @override
  ConsumerState<_TransactionFormDialog> createState() =>
      _TransactionFormDialogState();
}

class _TransactionFormDialogState
    extends ConsumerState<_TransactionFormDialog> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _targetAmount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _commissionAmount = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _accountId;
  String? _targetAccountId;
  String? _categoryId;
  // Время формы — через шов [formClock] (§7, образец DAO `clock: utcNow`):
  // дата новой операции — UTC (D-78). Локальный `DateTime.now()` записывал
  // бы локальные секунды: операция, созданная в 23:00 MSK, уезжала в чужой
  // месяц отчётов (месяцы считаются из UTC-секунд).
  DateTime _date = formClock();
  bool _busy = false;
  // 6в: после успешного сохранения диалог не закрывается, а переключается
  // в режим вложения (id операции появляется только после записи в БД).
  String? _savedTransactionId;
  // B4.1: вторая сумма была предзаполнена оценкой по текущему курсу —
  // до первой правки поля под ним видна подсказка transferPrefillNote.
  bool _targetPrefilled = false;
  // M7-шаг D (спека D §3): секция «Отложить» — только у перевода.
  // Галочка переводит форму в сценарий отложенного: дата формы становится
  // датой исполнения (execute_at, полночь UTC), заметка скрывается (в
  // scheduled_transfers её нет), раскрывается секция комиссии.
  bool _deferred = false;

  // Дата исполнения: по умолчанию — сегодняшний календарный день UTC
  // (минимум пикера — сегодня, спека D §3).
  DateTime _executeDate = calendarDayUtc(formClock());

  // Секция «Комиссия» (спека D §3): пара «обе или ни одной» — выключенное
  // состояние пишет NULL/NULL (D-115.г), включённое требует суммы > 0
  // и категории (валидаторы полей ниже).
  bool _commission = false;
  String? _commissionCategoryId;

  // Правка отложенного (спека D §4): суммы и комиссия проставляются в
  // build, когда подгрузились счета (нужен экспонент валюты счёта
  // списания, D-27) — до этого предзаполнение не начинается.
  bool _storePrefilled = false;

  @override
  void initState() {
    super.initState();
    final ScheduledTransfer? existing = widget.existing;
    if (existing != null) {
      // Правка отложенного (спека D §4): форма всегда в режиме отложения
      // (снять отложение = удалить строку — отдельного перевода «в
      // мгновенный» в механике нет), поэтому галочка не показывается.
      _deferred = true;
      _accountId = existing.accountId;
      _targetAccountId = existing.targetAccountId;
      _executeDate = DateTime.parse(existing.executeAt).toUtc();
      _commission = existing.commissionMinor != null;
      _commissionCategoryId = existing.commissionCategoryId;
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _targetAmount.dispose();
    _note.dispose();
    _commissionAmount.dispose();
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

  /// Пикер даты исполнения (спека D §3): минимум — сегодня UTC (прошлое
  /// в отложенных не откладываем; при правке нижняя граница — сохранённая
  /// дата, чтобы initialDate не оказался раньше firstDate), максимум — 2100.
  Future<void> _pickExecuteDate() async {
    final DateTime today = calendarDayUtc(formClock());
    final DateTime first = _executeDate.isBefore(today) ? _executeDate : today;
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _executeDate,
      firstDate: first,
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked != null) {
      setState(() => _executeDate = picked);
    }
  }

  String _formatDate(DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date);

  /// Умолчания при первом построении: первый живой счёт, без категории.
  String? _ensureDefaults(List<Account> accounts) {
    if (_accountId == null && accounts.isNotEmpty) {
      _accountId = accounts.first.id;
    }
    return _accountId;
  }

  Account? _accountOf(List<Account> accounts, String? id) =>
      accounts.where((Account account) => account.id == id).firstOrNull;

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
    final ScheduledTransfersController deferredController = ref.read(
      scheduledTransfersControllerProvider.notifier,
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
    // Суммы перевода (B4.1/D-17): у мультивалютного обе суммы обязательны
    // (валидация полей выше), у одно-валютного второй суммы нет —
    // DAO отвергнет значение при совпадающих валютах (D-17).
    final Account? target = _accountOf(accounts, _targetAccountId);
    final bool multiCurrency =
        target != null && target.currencyCode != account?.currencyCode;
    final int? targetAmountMinor = multiCurrency
        ? parseAmountToMinor(
            _targetAmount.text,
            exponent: currencyExponentByCode(target.currencyCode),
          )
        : null;
    if (widget.existing != null) {
      // Правка отложенного (спека D §4): сохранение через
      // updateScheduledTransfer; исполненная/удалённая строка — отказ
      // invalidInput/notFound снеком.
      final (int?, String?) commission = _commissionPair(account);
      result = await deferredController.updateScheduledTransfer(
        id: widget.existing!.id,
        accountId: _accountId!,
        targetAccountId: _targetAccountId!,
        amountMinor: amountMinor,
        targetAmountMinor: targetAmountMinor,
        executeAtUtc: calendarDayUtc(_executeDate),
        commissionMinor: commission.$1,
        commissionCategoryId: commission.$2,
      );
    } else if (_deferred) {
      // Отложенный перевод (спека D §3): execute_at — полночь UTC
      // выбранного дня (операция встанет в эту дату при исполнении,
      // D-119), заметка не сохраняется — в схеме её нет (D-115).
      final (int?, String?) commission = _commissionPair(account);
      result = await deferredController.createScheduledTransfer(
        accountId: _accountId!,
        targetAccountId: _targetAccountId!,
        amountMinor: amountMinor,
        targetAmountMinor: targetAmountMinor,
        executeAtUtc: calendarDayUtc(_executeDate),
        commissionMinor: commission.$1,
        commissionCategoryId: commission.$2,
      );
    } else {
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
            targetAmountMinor: targetAmountMinor,
            note: _note.text,
            date: _date,
          );
      }
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (result.isSuccess) {
      if (widget.existing != null) {
        // Правка: строка обновлена, диалог закрывается (образец формы
        // плана) — вложения не было и не появляется.
        Navigator.of(context).pop();
      } else if (_deferred) {
        // Успех отложения (спека D §3): закрытие без режима вложения
        // (операции ещё нет — крепить не к чему) + снек.
        Navigator.of(context).pop();
        await showSnack(
          context,
          AppLocalizations.of(context).transferDeferredSnack,
        );
      } else {
        // M5-шаг 6в: остаёмся в диалоге в режиме вложения — файл крепится
        // к живой операции, у только что созданной уже есть id.
        setState(() => _savedTransactionId = result.value.id);
      }
    } else {
      // Отказы DAO (invalidInput/notFound) — снеком по виду (спека D §3).
      await showDataFailureSnack(context, result.failure);
    }
  }

  /// Пара комиссии «обе или ни одной» (D-115.г, спека D §3): выключенное
  /// состояние пишет NULL/NULL; включённое — сумма > 0 и категория уже
  /// проверены валидаторами полей (порядок: существующие поля формы,
  /// затем комиссия). Сумма — в валюте счёта списания (D-27).
  (int?, String?) _commissionPair(Account? account) {
    if (!_commission) {
      return (null, null);
    }
    return (
      parseAmountToMinor(
        _commissionAmount.text,
        exponent: currencyExponentByCode(account?.currencyCode ?? ''),
      )!,
      _commissionCategoryId,
    );
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

    // Живые расходные категории — секция комиссии (спека D §3): у
    // перевода свой список, не фильтр типа операции.
    final List<Category> expenseCategories =
        ref.watch(categoriesByKindProvider(CategoryKind.expense)).value ??
        const <Category>[];
    if (_commissionCategoryId != null &&
        expenseCategories.isNotEmpty &&
        expenseCategories.every(
          (Category category) => category.id != _commissionCategoryId,
        )) {
      // Выбранная категория комиссии исчезла — выбор сбрасывается,
      // валидатор dropdown подсветит обязательность.
      _commissionCategoryId = null;
    }

    // Правка отложенного (спека D §4): предзаполнение сумм и комиссии —
    // когда счета подгрузились (экспонент валюты счёта списания, D-27).
    if (widget.existing != null && !_storePrefilled && accounts.isNotEmpty) {
      final ScheduledTransfer existing = widget.existing!;
      final Account? from = _accountOf(accounts, _accountId);
      final Account? to = _accountOf(accounts, _targetAccountId);
      _amount.text = minorToMajorString(
        existing.amountMinor,
        exponent: currencyExponentByCode(from?.currencyCode ?? ''),
      );
      final int? targetMinor = existing.targetAmountMinor;
      if (targetMinor != null) {
        _targetAmount.text = minorToMajorString(
          targetMinor,
          exponent: currencyExponentByCode(to?.currencyCode ?? ''),
        );
      }
      final int? commissionMinor = existing.commissionMinor;
      if (commissionMinor != null) {
        _commissionAmount.text = minorToMajorString(
          commissionMinor,
          exponent: currencyExponentByCode(from?.currencyCode ?? ''),
        );
      }
      _storePrefilled = true;
    }
    // B3: валюта выбранного счёта задаёт дробность и суффикс поля суммы;
    // код вне справочника — fallback на сам код.
    final Account? selected = _accountOf(accounts, _accountId);
    final int exponent = currencyExponentByCode(selected?.currencyCode ?? '');
    final String amountSuffix = _symbolOf(selected?.currencyCode);

    // B4.1: у перевода между валютами — два поля суммы с разными валютами.
    final Account? target = _accountOf(accounts, _targetAccountId);
    final bool multiCurrency =
        widget.type == TransactionType.transfer &&
        target != null &&
        target.currencyCode != selected?.currencyCode;
    final int targetExponent = currencyExponentByCode(
      target?.currencyCode ?? '',
    );
    final String targetAmountSuffix = _symbolOf(target?.currencyCode);

    // Расчётная строка курса (B4.1): производное отношение введённых сумм,
    // пересчитывается при вводе любой из них. Курс — до 6 значащих знаков
    // (D-26, formatRate шага 2); формат — «1 USD = 97,5 ₽» (спека B4.1).
    final int? fromMinor = multiCurrency
        ? parseAmountToMinor(_amount.text, exponent: exponent)
        : null;
    final int? toMinor = multiCurrency
        ? parseAmountToMinor(_targetAmount.text, exponent: targetExponent)
        : null;
    final String? rateLine = fromMinor != null && toMinor != null
        ? l10n.transferRateLine(
            selected?.currencyCode ?? '',
            formatRate(
              derivedRate(
                fromMinor,
                toMinor,
                fromExponent: exponent,
                toExponent: targetExponent,
              ),
            ),
            target?.currencyCode ?? '',
          )
        : null;

    final String title = widget.existing != null
        ? l10n.transferEditTitle
        : switch (widget.type) {
            TransactionType.expense => l10n.newExpenseTitle,
            TransactionType.income => l10n.newIncomeTitle,
            TransactionType.transfer => l10n.newTransferTitle,
          };

    // M5-шаг 6в: после сохранения показываем только секцию вложения
    // (сумму/счёт/категорию операции править нельзя — они уже записаны).
    final String? savedId = _savedTransactionId;
    if (savedId != null) {
      return AlertDialog(
        title: Text(title),
        content: AttachmentSection.forTransaction(savedId),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.doneAction),
          ),
        ],
      );
    }

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
                    DropdownMenuItem<String?>(child: Text(l10n.filterAll)),
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
              // Секция «Отложить» (спека D §3): чекбокс только у перевода
              // и только при создании — в правке форма всегда отложенная.
              if (widget.type == TransactionType.transfer &&
                  widget.existing == null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(l10n.transferDeferLabel),
                  value: _deferred,
                  // S1 (D-137): заметка, набранная до «Отложить», в
                  // scheduled_transfers не сохраняется (D-115), а поле
                  // скрывается — гасим её при включении, чтобы потеря
                  // была видна, а не молчаливой (минимальный вариант
                  // решения, новых l10n-ключей нет).
                  onChanged: (bool? value) => setState(() {
                    _deferred = value ?? false;
                    if (_deferred) {
                      _note.clear();
                    }
                  }),
                ),
              if (_deferred) ...<Widget>[
                // Дата исполнения заменяет дату операции: операция
                // создастся при исполнении с датой = execute_at (D-119),
                // поэтому обычный ряд даты ниже скрыт.
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${l10n.transferExecuteDateLabel}: '
                        '${_formatDate(_executeDate)}',
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.transferExecuteDateLabel,
                      onPressed: _pickExecuteDate,
                      icon: const Icon(Icons.calendar_month_outlined),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.transferDeferredFixNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Секция «Комиссия» (спека D §3): без живых расходных
                // категорий — чекбокс disabled и подсказка (переиспользование
                // planningNoCategoriesHint).
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(l10n.transferCommissionToggle),
                  value: _commission,
                  onChanged: expenseCategories.isEmpty
                      ? null
                      : (bool? value) =>
                            setState(() => _commission = value ?? false),
                ),
                if (expenseCategories.isEmpty)
                  Text(
                    l10n.planningNoCategoriesHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (_commission) ...<Widget>[
                  AmountField(
                    controller: _commissionAmount,
                    labelText: l10n.transferCommissionAmountLabel,
                    exponent: exponent,
                    suffixText: amountSuffix,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _commissionCategoryId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: l10n.transferCommissionCategoryLabel,
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final Category category in expenseCategories)
                        DropdownMenuItem<String>(
                          value: category.id,
                          child: Text(category.name),
                        ),
                    ],
                    // Порядок валидации (спека D §3): существующие поля
                    // формы, затем комиссия — сумма (валидатор AmountField,
                    // > 0) и эта категория.
                    validator: (String? value) => value == null
                        ? l10n.transferCommissionCategoryRequired
                        : null,
                    onChanged: (String? value) =>
                        setState(() => _commissionCategoryId = value),
                  ),
                ],
              ],
              if (!_deferred) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('${l10n.dateLabel}: ${_formatDate(_date)}'),
                    ),
                    IconButton(
                      tooltip: l10n.dateLabel,
                      onPressed: _pickDate,
                      icon: const Icon(Icons.calendar_month_outlined),
                    ),
                  ],
                ),
                // Заметка — только мгновенной операции: в схеме
                // scheduled_transfers заметки нет (D-115), отложенный
                // перевод её не хранит (спека D §3).
                TextFormField(
                  controller: _note,
                  decoration: InputDecoration(labelText: l10n.noteLabel),
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
