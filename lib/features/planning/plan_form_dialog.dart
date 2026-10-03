import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/plans_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/planning/planning_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог плана (спека C §3): один виджет на создание и правку. Вид —
/// сегмент-фильтр списка категорий, направление плана — производная вида
/// категории (D-115.а); категорию при правке менять можно (DAO переносит
/// план и проверит пересечение). Период в UI включительный; в хранение
/// уходит полуинтервал [start, end + 1 день) через [calendarDayUtc].
/// Удаление в форму не встроено — долгий тап по строке списка.
Future<void> showPlanFormDialog(BuildContext context, {PlanVsFact? existing}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _PlanFormDialog(existing: existing),
  );
}

/// Начало периода в хранении из включительной даты формы: полночь UTC
/// календарного дня (§3).
DateTime planPeriodStartUtc(DateTime inclusiveStart) =>
    calendarDayUtc(inclusiveStart);

/// Конец периода в хранении (не включается) из включительной даты формы:
/// полуночь UTC следующего дня (спека C §3).
DateTime planPeriodEndUtcExclusive(DateTime inclusiveEnd) =>
    calendarDayUtc(inclusiveEnd).add(const Duration(days: 1));

/// Включительная дата начала для показа (спека C §2: даты показываются
/// как введённые — локально).
DateTime planPeriodStartLocal(String periodStartIso) =>
    DateTime.parse(periodStartIso).toUtc().toLocal();

/// Включительная дата конца для показа: из полуинтервала хранения вычитается
/// день — расхождений «на день» пользователь не видит (спека C §2/§3).
DateTime planPeriodEndInclusiveLocal(String periodEndIso) =>
    DateTime.parse(periodEndIso)
        .toUtc()
        .subtract(const Duration(days: 1))
        .toLocal();

class _PlanFormDialog extends ConsumerStatefulWidget {
  const _PlanFormDialog({this.existing});

  final PlanVsFact? existing;

  @override
  ConsumerState<_PlanFormDialog> createState() => _PlanFormDialogState();
}

class _PlanFormDialogState extends ConsumerState<_PlanFormDialog> {
  final TextEditingController _amount = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  CategoryKind _kind = CategoryKind.expense;
  String? _categoryId;
  DateTime? _periodStart;
  DateTime? _periodEnd;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final PlanVsFact? existing = widget.existing;
    if (existing != null) {
      _categoryId = existing.plan.categoryId;
      // Сумма показывается в мажорных единицах: int только для хранения (§3).
      _amount.text = minorToMajorString(existing.plan.amountMinor);
      _periodStart = planPeriodStartLocal(existing.plan.periodStart);
      _periodEnd = planPeriodEndInclusiveLocal(existing.plan.periodEnd);
    } else {
      // Дефолт периода — текущий календарный месяц по локальной дате
      // (спека C §3): 1-е число … последнее число.
      final DateTime now = DateTime.now();
      _periodStart = DateTime(now.year, now.month);
      _periodEnd = DateTime(now.year, now.month + 1, 0);
    }
  }

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

    // Вид по умолчанию: вид категории правимого плана; при создании —
    // расход (первый пункт сегмента). Направление плана — производная
    // вида категории (D-115.а), отдельного атрибута у плана нет.
    final List<Category> all =
        ref.watch(allCategoriesProvider).value ?? const <Category>[];
    if (_categoryId != null) {
      for (final Category category in all) {
        if (category.id == _categoryId) {
          _kind = CategoryKind.fromDb(category.kind);
          break;
        }
      }
    }

    final List<Category> categories =
        ref.watch(categoriesByKindProvider(_kind)).value ?? const <Category>[];
    if (_categoryId != null &&
        categories.every((Category category) => category.id != _categoryId)) {
      // Категория выбранного вида исчезла (вид переключён в пустом виде) —
      // выбор сбрасывается, «Сохранить» блокируется.
      _categoryId = null;
    }

    final bool periodInvalid =
        _periodStart != null &&
        _periodEnd != null &&
        _periodEnd!.isBefore(_periodStart!);

    return AlertDialog(
      title: Text(
        widget.existing == null
            ? l10n.planningAddTitle
            : l10n.planningEditTitle,
      ),
      content: Form(
        key: _formKey,
        // ListBody требует неограниченной высоты по главной оси — как в
        // форме операций/бюджета, оборачиваем в SingleChildScrollView.
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
              SegmentedButton<CategoryKind>(
                segments: <ButtonSegment<CategoryKind>>[
                  ButtonSegment<CategoryKind>(
                    value: CategoryKind.expense,
                    label: Text(l10n.kindExpense),
                  ),
                  ButtonSegment<CategoryKind>(
                    value: CategoryKind.income,
                    label: Text(l10n.kindIncome),
                  ),
                ],
                selected: <CategoryKind>{_kind},
                onSelectionChanged: (Set<CategoryKind> selection) =>
                    setState(() {
                      _kind = selection.first;
                      _categoryId = null;
                    }),
              ),
              // Сегмент — фильтр списка категорий, не атрибут плана (§3).
              Text(
                l10n.planningKindHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                decoration: InputDecoration(
                  labelText: l10n.categoryLabel,
                  helperText: categories.isEmpty
                      ? l10n.planningNoCategoriesHint
                      : null,
                ),
                items: <DropdownMenuItem<String>>[
                  for (final Category category in categories)
                    DropdownMenuItem<String>(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (String? value) =>
                    setState(() => _categoryId = value),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.planningPeriodStartLabel,
                style: theme.textTheme.bodySmall,
              ),
              InkWell(
                onTap: () => _pickDate(isStart: true),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.calendar_today, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _periodStart == null
                            ? '—'
                            : DateFormat.yMd(locale).format(_periodStart!),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                l10n.planningPeriodEndLabel,
                style: theme.textTheme.bodySmall,
              ),
              InkWell(
                onTap: () => _pickDate(isStart: false),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.calendar_today, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        _periodEnd == null
                            ? '—'
                            : DateFormat.yMd(locale).format(_periodEnd!),
                      ),
                    ],
                  ),
                ),
              ),
              if (periodInvalid)
                Text(
                  l10n.planningPeriodInvalid,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              const SizedBox(height: 8),
              AmountField(controller: _amount, suffixText: base?.symbol),
              const SizedBox(height: 8),
              if (base != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.planningBaseCurrencyHint(base.code),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
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
          onPressed:
              _busy ||
                  _categoryId == null ||
                  categories.isEmpty ||
                  periodInvalid
              ? null
              : _submit,
          child: Text(l10n.saveAction),
        ),
      ],
    );
  }

  Future<void> _pickDate({required bool isStart}) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _periodStart : _periodEnd) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _periodStart = picked;
        } else {
          _periodEnd = picked;
        }
      });
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false) ||
        _categoryId == null ||
        _periodStart == null ||
        _periodEnd == null ||
        _periodEnd!.isBefore(_periodStart!)) {
      return;
    }
    setState(() => _busy = true);
    final PlanningController controller = ref.read(
      planningControllerProvider.notifier,
    );
    // Период включительный в UI, полуинтервал в хранении (спека C §3).
    final DateTime startUtc = planPeriodStartUtc(_periodStart!);
    final DateTime endUtc = planPeriodEndUtcExclusive(_periodEnd!);

    // Превентивная проверка пересечения (спека C §6.3): пересечение живых
    // планов категории приходит из DAO как invalidInput без подвида —
    // различаем его контекстом формы до обращения к DAO; DAO-отказ —
    // страховка. Показ errorPlanOverlap, диалог открыт.
    final bool overlap = controller.hasOverlap(
      categoryId: _categoryId!,
      periodStartUtc: startUtc,
      periodEndUtc: endUtc,
      excludePlanId: widget.existing?.plan.id,
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
    final Result<dynamic> result = widget.existing == null
        ? await controller.createPlan(
            categoryId: _categoryId!,
            periodStartUtc: startUtc,
            periodEndUtc: endUtc,
            amountMinor: amountMinor,
          )
        : await controller.updatePlan(
            id: widget.existing!.plan.id,
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
      return;
    }
    if (result.failure == DataFailure.invalidInput) {
      // В форме сумма и порядок дат уже валидированы: invalidInput от DAO —
      // только пересечение живых планов (D-115.в, спека C §6.3/§3).
      await showSnack(context, AppLocalizations.of(context).errorPlanOverlap);
      return;
    }
    // notFound (план удалён во время правки) и прочее — снек по виду
    // отказа, диалог открыт (образец M6).
    await showDataFailureSnack(context, result.failure);
  }
}
