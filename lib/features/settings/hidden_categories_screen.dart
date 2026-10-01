// Экран «Скрытые категории» (M5-шаг 3, D-54 идея 3): скрытые системные
// категории с действием «вернуть». Скрытие — запись `deleted_at` в БД
// (схема v4 не меняется), возврат возвращает категорию во все живые списки.
//
// Запуск через pumpDialogApp (S2): in-memory БД, RU-локаль, весь KopilkaApp —
// переход из настроек, как делает пользователь.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/categories/categories_screen.dart'
    show categoryIcon;
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Скрытые системные категории: список по видам, возврат — тапом по строке.
class HiddenCategoriesScreen extends ConsumerWidget {
  const HiddenCategoriesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<List<Category>> hidden = ref.watch(
      hiddenSystemCategoriesProvider,
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.hiddenCategoriesTitle)),
      body: hidden.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          onRetry: () => ref.invalidate(hiddenSystemCategoriesProvider),
        ),
        data: (List<Category> rows) {
          if (rows.isEmpty) {
            return Center(child: Text(l10n.hiddenCategoriesEmpty));
          }
          return ListView(
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

class _KindSection extends ConsumerWidget {
  const _KindSection({required this.kind, required this.all});

  final CategoryKind kind;
  final List<Category> all;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Category> own = all
        .where(
          (Category category) => CategoryKind.fromDb(category.kind) == kind,
        )
        .toList();
    if (own.isEmpty) {
      return const SizedBox.shrink();
    }

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
          ListTile(
            leading: categoryIcon(category),
            title: Text(category.name),
            trailing: Tooltip(
              message: l10n.categoryRestoreAction,
              child: const Icon(Icons.restore),
            ),
            onTap: () => _restore(context, ref, category),
          ),
      ],
    );
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    Category category,
  ) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Result<Category> result = await ref
        .read(categoriesControllerProvider.notifier)
        .restoreCategory(category.id);
    if (!context.mounted) {
      return;
    }
    await showSnack(
      context,
      result.isSuccess
          ? l10n.categoryRestoredSnack(category.name)
          : l10n.errorNotFound,
    );
  }
}
