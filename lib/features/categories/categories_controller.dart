import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';

/// Живые категории по виду — для экрана и выбора в формах операций.
final categoriesByKindProvider =
    StreamProvider.family<List<Category>, CategoryKind>((ref, kind) {
      return ref.watch(categoriesDaoProvider).watchAlive(kind: kind);
    });

/// Все живые категории — для экрана управления.
final allCategoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref.watch(categoriesDaoProvider).watchAlive();
});

/// Контроллер экрана категорий: формы и удаление через DAO.
class CategoriesController extends Notifier {
  @override
  void build() {}

  CategoriesDao get _categories => ref.read(categoriesDaoProvider);

  /// Создаёт категорию.
  Future<Result<Category>> createCategory({
    required String name,
    required CategoryKind kind,
    String? parentId,
  }) async {
    try {
      final Category category = await _categories.create(
        name: name,
        kind: kind,
        parentId: parentId,
      );
      return Success<Category>(category);
    } on DataValidationException catch (error) {
      return Failure<Category>(error.kind);
    }
  }

  /// Меняет категорию; вид (`kind`) не меняется — от него зависит смысл
  /// операций (DAO это и не позволяет).
  Future<Result<Category>> updateCategory(
    String id, {
    Value<String> name = const Value.absent(),
    Value<String?> parentId = const Value.absent(),
  }) async {
    try {
      final Category category = await _categories.updateCategory(
        id,
        name: name,
        parentId: parentId,
      );
      return Success<Category>(category);
    } on DataValidationException catch (error) {
      return Failure<Category>(error.kind);
    }
  }

  /// Мягко удаляет категорию. Отказы (системная, с вложенными, с операциями)
  /// UI объясняет по машиночитаемому виду.
  Future<Result<void>> deleteCategory(String id) async {
    try {
      await _categories.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final categoriesControllerProvider =
    NotifierProvider<CategoriesController, void>(CategoriesController.new);
