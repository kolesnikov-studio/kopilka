import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';

// Конвенция Value<T> (A1): `Value.absent()` — поле не менять, `Value(null)`
// — записать NULL (только nullable-поля). Полный текст — в начале
// accounts_controller.dart; здесь дублируется для читателя файла.

/// Живые категории по виду — для экрана и выбора в формах операций.
final categoriesByKindProvider =
    StreamProvider.family<List<Category>, CategoryKind>((ref, kind) {
      return ref.watch(categoriesDaoProvider).watchAlive(kind: kind);
    });

/// Все живые категории — для экрана управления.
final allCategoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref.watch(categoriesDaoProvider).watchAlive();
});

/// Скрытые системные категории — для возврата из настроек (M5, D-54 идея 3).
final hiddenSystemCategoriesProvider = StreamProvider<List<Category>>((ref) {
  return ref.watch(categoriesDaoProvider).watchHiddenSystem();
});

/// Контроллер экрана категорий: формы и удаление через DAO.
class CategoriesController extends Notifier {
  @override
  void build() {}

  CategoriesDao get _categories => ref.read(categoriesDaoProvider);

  /// Создаёт категорию.
  ///
  /// [iconCode] — код из справочника `core/category_icons.dart` (v4, D-54);
  /// неизвестный код отвергается слоем данных (invalidInput).
  Future<Result<Category>> createCategory({
    required String name,
    required CategoryKind kind,
    required String iconCode,
    String? parentId,
  }) async {
    try {
      final Category category = await _categories.create(
        name: name,
        kind: kind,
        parentId: parentId,
        iconCode: iconCode,
      );
      return Success<Category>(category);
    } on DataValidationException catch (error) {
      return Failure<Category>(error.kind);
    }
  }

  /// Меняет категорию; вид (`kind`) не меняется — от него зависит смысл
  /// операций (DAO это и не позволяет).
  ///
  /// [iconCode] — код из справочника `core/category_icons.dart` (v4, D-54);
  /// NULL снимает иконку, неизвестный код отвергается слоем данных.
  Future<Result<Category>> updateCategory(
    String id, {
    Value<String> name = const Value.absent(),
    Value<String?> parentId = const Value.absent(),
    Value<String?> iconCode = const Value.absent(),
  }) async {
    try {
      final Category category = await _categories.updateCategory(
        id,
        name: name,
        parentId: parentId,
        iconCode: iconCode,
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

  /// Скрывает системную категорию (M5, D-54 идея 3): запись `deleted_at` в БД
  /// без смены схемы; категория исчезает из всех живых списков (выбор в форме
  /// операции, фильтры, отчёты, бюджеты) и с экрана категорий, но операции и
  /// бюджеты продолжают существовать и считаться. Отказ (не-системная) UI
  /// объясняет по машиночитаемому виду.
  Future<Result<Category>> hideCategory(String id) async {
    try {
      return Success<Category>(await _categories.hide(id));
    } on DataValidationException catch (error) {
      return Failure<Category>(error.kind);
    }
  }

  /// Возвращает скрытую системную категорию во все живые списки.
  Future<Result<Category>> restoreCategory(String id) async {
    try {
      return Success<Category>(await _categories.restore(id));
    } on DataValidationException catch (error) {
      return Failure<Category>(error.kind);
    }
  }
}

final categoriesControllerProvider =
    NotifierProvider<CategoriesController, void>(CategoriesController.new);
