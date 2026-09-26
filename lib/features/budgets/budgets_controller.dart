import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';

/// Живой прогресс бюджетов за месяц, в который попадает [moment].
///
/// Поток пересчитывается при любом изменении бюджетов, категорий и
/// операций (customSelect с readsFrom — §2). Сортировка — DAO (createdAt).
final budgetProgressProvider =
    StreamProvider.autoDispose<List<BudgetProgress>>((ref) {
  return ref.watch(budgetsDaoProvider).watchProgress(moment: utcNow());
});

/// Контроллер бюджетов: создание, лимит, удаление через DAO; отказы —
/// как [Result], UI объясняет их по машиночитаемому виду.
class BudgetsController extends Notifier {
  @override
  void build() {}

  BudgetsDao get _budgets => ref.read(budgetsDaoProvider);

  /// Создаёт бюджет на категорию расходов. Отказы: бюджет уже есть
  /// ([DataFailure.budgetAlreadyExists]), категория не расход
  /// ([DataFailure.budgetCategoryInvalid]).
  Future<Result<Budget>> createBudget({
    required String categoryId,
    required int limitMinor,
  }) async {
    try {
      final Budget budget = await _budgets.create(
        categoryId: categoryId,
        limitMinor: limitMinor,
      );
      return Success<Budget>(budget);
    } on DataValidationException catch (error) {
      return Failure<Budget>(error.kind);
    }
  }

  /// Меняет лимит бюджета.
  Future<Result<Budget>> updateLimit({
    required String id,
    required int limitMinor,
  }) async {
    try {
      final Budget budget = await _budgets.updateLimit(
        id,
        limitMinor: limitMinor,
      );
      return Success<Budget>(budget);
    } on DataValidationException catch (error) {
      return Failure<Budget>(error.kind);
    }
  }

  /// Мягко удаляет бюджет; освобождает категорию для нового бюджета.
  Future<Result<void>> deleteBudget(String id) async {
    try {
      await _budgets.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final budgetsControllerProvider =
    NotifierProvider<BudgetsController, void>(BudgetsController.new);
