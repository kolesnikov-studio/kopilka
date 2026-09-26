import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/budgets/budgets_controller.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог бюджета: создание (выбор категории + лимит) или редактирование
/// (категория зафиксирована, меняется только лимит).
Future<void> showBudgetFormDialog(
  BuildContext context, {
  BudgetProgress? existing,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _BudgetFormDialog(existing: existing),
  );
}

class _BudgetFormDialog extends ConsumerStatefulWidget {
  const _BudgetFormDialog({this.existing});

  final BudgetProgress? existing;

  @override
  ConsumerState<_BudgetFormDialog> createState() => _BudgetFormDialogState();
}

class _BudgetFormDialogState extends ConsumerState<_BudgetFormDialog> {
  final TextEditingController _limit = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  String? _categoryId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final BudgetProgress? existing = widget.existing;
    if (existing != null) {
      _categoryId = existing.budget.categoryId;
      // Показываем в мажорных единицах: int только для хранения (§3).
      _limit.text = (existing.budget.limitMinor / minorUnitsPerMajor)
          .toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false) || _categoryId == null) {
      return;
    }
    setState(() => _busy = true);
    final BudgetsController controller = ref.read(
      budgetsControllerProvider.notifier,
    );
    final int limitMinor = parseAmountToMinor(_limit.text)!;
    final Result<dynamic> result = widget.existing == null
        ? await controller.createBudget(
            categoryId: _categoryId!,
            limitMinor: limitMinor,
          )
        : await controller.updateLimit(
            id: widget.existing!.budget.id,
            limitMinor: limitMinor,
          );
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (result.isSuccess) {
      Navigator.of(context).pop();
    } else {
      // Отказы DAO («уже есть бюджет», «категория не расход») объясняются
      // снеком по машиночитаемому виду.
      await showDataFailureSnack(context, result.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Category> categories =
        ref.watch(categoriesByKindProvider(CategoryKind.expense)).value ??
            const <Category>[];
    // Категории с живым бюджетом показываем отключёнными: уникальность
    // живых бюджетов на категорию держит DAO (D-14), отказ объяснит снек.
    // Важно: занятые категории НЕ выбрасываются из items, иначе после
    // создания бюджета открытый диалог теряет выбранное значение.
    final Set<String> taken = <String>{
      for (final BudgetProgress progress
          in ref.watch(budgetProgressProvider).value ??
          const <BudgetProgress>[])
        progress.budget.categoryId,
    };

    // Умолчание: первая свободная категория (если свободных нет — первая).
    if (widget.existing == null) {
      _categoryId ??= categories.isEmpty
          ? null
          : categories
              .firstWhere(
                (Category category) => !taken.contains(category.id),
                orElse: () => categories.first,
              )
              .id;
    }

    return AlertDialog(
      title: Text(
        widget.existing == null ? l10n.budgetAdd : l10n.budgetEdit,
      ),
      content: Form(
        key: _formKey,
        // ListBody требует неограниченной высоты по главной оси — как и в
        // форме операций, оборачиваем в SingleChildScrollView.
        child: SingleChildScrollView(
          child: ListBody(
            children: <Widget>[
            if (widget.existing == null)
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                decoration: InputDecoration(labelText: l10n.categoryLabel),
                items: <DropdownMenuItem<String>>[
                  for (final Category category in categories)
                    DropdownMenuItem<String>(
                      value: category.id,
                      enabled: !taken.contains(category.id) ||
                          category.id == _categoryId,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (String? value) =>
                    setState(() => _categoryId = value),
              )
            else
              Text(
                widget.existing!.categoryName,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            const SizedBox(height: 12),
            AmountField(controller: _limit),
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
