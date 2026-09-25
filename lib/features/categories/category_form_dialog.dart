import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог формы категории: создание или редактирование.
///
/// Вид (`kind`) задаётся только при создании: DAO не меняет его, потому что
/// от вида зависит смысл операций. Родитель выбирается среди категорий того
/// же вида, саму категорию и её потомков DAO исключит сам.
Future<void> showCategoryFormDialog(
  BuildContext context, {
  Category? category,
  CategoryKind initialKind = CategoryKind.expense,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _CategoryFormDialog(initial: category, initialKind: initialKind),
  );
}

class _CategoryFormDialog extends ConsumerStatefulWidget {
  const _CategoryFormDialog({this.initial, required this.initialKind});

  final Category? initial;
  final CategoryKind initialKind;

  @override
  ConsumerState<_CategoryFormDialog> createState() =>
      _CategoryFormDialogState();
}

class _CategoryFormDialogState extends ConsumerState<_CategoryFormDialog> {
  final TextEditingController _name = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late CategoryKind _kind = widget.initialKind;
  String? _parentId;

  @override
  void initState() {
    super.initState();
    final Category? initial = widget.initial;
    if (initial != null) {
      _name.text = initial.name;
      _kind = CategoryKind.fromDb(initial.kind);
      _parentId = initial.parentId;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final CategoriesController controller = ref.read(
      categoriesControllerProvider.notifier,
    );
    final Result<dynamic> result;
    if (widget.initial == null) {
      result = await controller.createCategory(
        name: _name.text,
        kind: _kind,
        parentId: _parentId,
      );
    } else {
      result = await controller.updateCategory(
        widget.initial!.id,
        name: Value<String>(_name.text),
        parentId: Value<String?>(_parentId),
      );
    }
    if (!mounted) {
      return;
    }
    if (result.isSuccess) {
      Navigator.of(context).pop();
    } else {
      // Отказ DAO (родитель другого вида, цикл) объясняется пользователю.
      await showDataFailureSnack(context, result.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool editing = widget.initial != null;
    final List<Category> sameKind =
        ref.watch(categoriesByKindProvider(_kind)).value ??
            const <Category>[];
    final List<Category> parentOptions = sameKind
        .where((Category category) => category.id != widget.initial?.id)
        .toList();

    return AlertDialog(
      title: Text(editing ? l10n.categoryEdit : l10n.categoryAdd),
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
              SegmentedButton<CategoryKind>(
                segments: <ButtonSegment<CategoryKind>>[
                  ButtonSegment<CategoryKind>(
                    value: CategoryKind.expense,
                    label: Text(l10n.kindExpense),
                    icon: const Icon(Icons.south_west),
                  ),
                  ButtonSegment<CategoryKind>(
                    value: CategoryKind.income,
                    label: Text(l10n.kindIncome),
                    icon: const Icon(Icons.north_east),
                  ),
                ],
                selected: <CategoryKind>{_kind},
                onSelectionChanged: editing
                    ? null
                    : (Set<CategoryKind> selection) =>
                        setState(() => _kind = selection.first),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: _parentId,
                decoration: InputDecoration(
                  labelText: l10n.categoryParent,
                ),
                items: <DropdownMenuItem<String?>>[
                  DropdownMenuItem<String?>(
                    child: Text(l10n.categoryParentNone),
                  ),
                  for (final Category category in parentOptions)
                    DropdownMenuItem<String?>(
                      value: category.id,
                      child: Text(category.name),
                    ),
                ],
                onChanged: (String? value) => setState(() => _parentId = value),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(l10n.saveAction),
        ),
      ],
    );
  }
}
