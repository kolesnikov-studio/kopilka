import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/categories/category_form_dialog.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Управление категориями: системный предустановленный набор помечен бейджем,
/// пользовательские можно удалять (soft delete с объяснением отказов).
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<List<Category>> categories = ref.watch(
      allCategoriesProvider,
    );

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        tooltip: l10n.categoryAdd,
        onPressed: () => showCategoryFormDialog(context),
        child: const Icon(Icons.add),
      ),
      body: categories.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) =>
            Center(child: Text(l10n.errorUnknown)),
        data: (List<Category> rows) {
          if (rows.isEmpty) {
            return Center(child: Text(l10n.categoriesEmpty));
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: <Widget>[
              _KindSection(kind: CategoryKind.expense, all: rows),
              _KindSection(kind: CategoryKind.income, all: rows),
            ],
          );
        },
      ),
    );
  }
}

class _KindSection extends StatelessWidget {
  const _KindSection({required this.kind, required this.all});

  final CategoryKind kind;
  final List<Category> all;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Category> own = all
        .where((Category category) => CategoryKind.fromDb(category.kind) == kind)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            kind == CategoryKind.expense ? l10n.kindExpense : l10n.kindIncome,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        for (final Category category in own)
          _CategoryTile(category: category),
      ],
    );
  }
}

class _CategoryTile extends ConsumerWidget {
  const _CategoryTile({required this.category});

  final Category category;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? parentName = _parentName(ref, category.parentId);

    return ListTile(
      leading: Icon(
        CategoryKind.fromDb(category.kind) == CategoryKind.income
            ? Icons.north_east
            : Icons.south_west,
      ),
      title: Row(
        children: <Widget>[
          Flexible(child: Text(category.name, overflow: TextOverflow.ellipsis)),
          if (category.isSystem) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              l10n.systemBadge,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ],
      ),
      subtitle: parentName == null ? null : Text(parentName),
      onTap: () => showCategoryFormDialog(context, category: category),
      onLongPress: () => _confirmDelete(context, ref, l10n),
    );
  }

  String? _parentName(WidgetRef ref, String? parentId) {
    if (parentId == null) {
      return null;
    }
    final List<Category> categories =
        ref.watch(allCategoriesProvider).value ?? const <Category>[];
    for (final Category category in categories) {
      if (category.id == parentId) {
        return category.name;
      }
    }
    return null;
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
  ) async {
    if (category.isSystem) {
      // Системную категорию DAO не удаляет — объясняем сразу, без диалога.
      await showSnack(context, l10n.errorCategoryIsSystem);
      return;
    }
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.categoryDeleteTitle,
      body: l10n.categoryDeleteBody(category.name),
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result = await ref
        .read(categoriesControllerProvider.notifier)
        .deleteCategory(category.id);
    if (result.isFailure && context.mounted) {
      // Вложенные или ссылающиеся операции — объясняем отказом DAO.
      await showDataFailureSnack(context, result.failure);
    }
  }
}
