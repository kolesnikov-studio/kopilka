import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/planning/planning_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог автобюджета (D-54 идея 17, спека C §4): средний доход —
/// существующим агрегатом [autoBudgetTotalsProvider], срок 1/3/6/12 мес.,
/// сумма предзаполнена «средний доход × срок» и редактируема. Один план
/// за диалог: пачка созданий дала бы частичные отказы пересечения
/// (D-115.в) и размытое согласие — явное согласие названо словами в
/// интро и кнопкой «Создать план» (D-121). Никаких новых таблиц и
/// фоновой автоматики: после закрытия диалога ничего не отслеживается.
Future<void> showAutoBudgetDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => const _AutoBudgetDialog(),
  );
}

class _AutoBudgetDialog extends ConsumerStatefulWidget {
  const _AutoBudgetDialog();

  @override
  ConsumerState<_AutoBudgetDialog> createState() => _AutoBudgetDialogState();
}

class _AutoBudgetDialogState extends ConsumerState<_AutoBudgetDialog> {
  final TextEditingController _amount = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  int _termMonths = 6;
  String? _categoryId;
  bool _amountEdited = false;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final String locale = Localizations.localeOf(context).toString();
    final Currency? base = ref.watch(baseCurrencyStreamProvider).value;
    final int exponent = base == null
        ? defaultCurrencyExponent
        : currencyExponentByCode(base.code);
    final String symbol = base?.symbol ?? '';
    String money(int minor) => base == null
        ? '…'
        : formatMoneyMinor(
            minor,
            symbol: symbol,
            locale: locale,
            exponent: exponent,
          );

    final AsyncValue<List<MonthTotalsBase>> totals = ref.watch(
      autoBudgetTotalsProvider,
    );
    final AutoBudgetSuggestion? suggestion = totals.value == null
        ? null
        : computeAutoBudget(totals.value!);
    final bool loading = totals.isLoading;
    final bool noData = !loading && suggestion == null;

    // Предзаполнение «средний доход × срок»: пересчитывается при смене
    // срока, пока пользователь не правил сумму вручную. Разделитель —
    // каноническая запятая приложения (S2, D-137), как в префилле
    // перевода (B4.1): minorToMajorString отдаёт точку (CSV, A14).
    if (suggestion != null && !_amountEdited && !_busy) {
      final String prefilled = minorToMajorString(
        suggestion.suggestedMinor(_termMonths),
      ).replaceAll('.', ',');
      if (_amount.text != prefilled) {
        _amount.text = prefilled;
      }
    }

    final List<Category> categories =
        ref.watch(allCategoriesProvider).value ?? const <Category>[];
    if (_categoryId != null &&
        categories.every((Category category) => category.id != _categoryId)) {
      _categoryId = null;
    }

    return AlertDialog(
      title: Text(l10n.planningAutoTitle),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              // Явное согласие названо словами (D-121): «ничего не
              // создаётся без подтверждения».
              Text(l10n.planningAutoIntro),
              const SizedBox(height: 12),
              if (loading)
                const Center(child: CircularProgressIndicator())
              else if (noData)
                Text(
                  l10n.planningAutoNoData,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              else ...<Widget>[
                Text(
                  l10n.planningAutoAverage(
                    money(suggestion!.averageIncomeMinor),
                    suggestion.monthsWithIncome,
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.planningAutoTermLabel,
                  style: theme.textTheme.bodySmall,
                ),
                SegmentedButton<int>(
                  segments: <ButtonSegment<int>>[
                    for (final int months in const <int>[1, 3, 6, 12])
                      ButtonSegment<int>(
                        value: months,
                        label: Text(l10n.planningAutoMonths(months)),
                      ),
                  ],
                  selected: <int>{_termMonths},
                  onSelectionChanged: (Set<int> selection) =>
                      setState(() => _termMonths = selection.first),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _categoryId,
                  decoration: InputDecoration(labelText: l10n.categoryLabel),
                  items: <DropdownMenuItem<String>>[
                    for (final Category category in categories)
                      DropdownMenuItem<String>(
                        value: category.id,
                        child: Text(
                          '${CategoryKind.fromDb(category.kind) == CategoryKind.income ? l10n.kindIncome : l10n.kindExpense} · ${category.name}',
                        ),
                      ),
                  ],
                  onChanged: (String? value) =>
                      setState(() => _categoryId = value),
                ),
                // Направление плана — производная вида категории (D-115.а).
                Text(
                  l10n.planningKindHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                AmountField(
                  controller: _amount,
                  suffixText: base?.symbol,
                  onChanged: (String value) => _amountEdited = true,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.planningAutoAmountHelper(
                      money(suggestion.averageIncomeMinor),
                      _termMonths,
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
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
          onPressed: loading || noData || _categoryId == null || _busy
              ? null
              : _submit,
          child: Text(l10n.planningAutoCreateAction),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false) || _categoryId == null) {
      return;
    }
    setState(() => _busy = true);
    final PlanningController controller = ref.read(
      planningControllerProvider.notifier,
    );
    // План на срок с начала текущего календарного месяца (спека C §4):
    // полуинтервал [месяц старта, месяц старта + срок) в UTC.
    final DateTime nowLocal = DateTime.now();
    final DateTime startUtc = calendarDayUtc(
      DateTime(nowLocal.year, nowLocal.month),
    );
    final DateTime endUtc = DateTime.utc(
      startUtc.year,
      startUtc.month + _termMonths,
    );

    // Превентивная проверка пересечения (спека C §6.3): пользователь
    // меняет категорию/срок/сумму, диалог открыт; DAO-отказ — страховка.
    final bool overlap = controller.hasOverlap(
      categoryId: _categoryId!,
      periodStartUtc: startUtc,
      periodEndUtc: endUtc,
    );
    if (overlap) {
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      await showSnack(context, AppLocalizations.of(context).errorPlanOverlap);
      return;
    }

    final int amountMinor = parseAmountToMinor(_amount.text)!;
    final Result<dynamic> result = await controller.createPlan(
      categoryId: _categoryId!,
      periodStartUtc: startUtc,
      periodEndUtc: endUtc,
      amountMinor: amountMinor,
    );
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (result.isSuccess) {
      Navigator.of(context).pop();
      await showSnack(
        context,
        AppLocalizations.of(context).planningAutoCreatedSnack,
      );
      return;
    }
    if (result.failure == DataFailure.invalidInput) {
      // Сумма валидирована формой: invalidInput от DAO — только пересечение
      // живых планов (D-115.в, спека C §6.3).
      await showSnack(context, AppLocalizations.of(context).errorPlanOverlap);
      return;
    }
    // notFound (категория исчезла во время правки) и прочее — снек по виду.
    await showDataFailureSnack(context, result.failure);
  }
}
