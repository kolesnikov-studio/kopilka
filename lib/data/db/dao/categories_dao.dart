import 'package:drift/drift.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'categories_dao.g.dart';

/// Категории: CRUD с вложенностью (`parent_id`) и soft delete.
///
/// Дерево держим согласованным вручную, потому что каскадов нет (§3):
/// удаление запрещено, если есть живые вложенные категории или операции.
@DriftAccessor(tables: [Budgets, Categories, Transactions])
class CategoriesDao extends DatabaseAccessor<AppDatabase>
    with _$CategoriesDaoMixin {
  CategoriesDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт категорию. Вложенная категория обязана быть того же вида, что
  /// и родительская: доходы не вкладываются в расходы.
  Future<Category> create({
    required String name,
    required CategoryKind kind,
    String? parentId,
    String? icon,
    String? color,
    bool isSystem = false,
  }) async {
    final String trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw DataValidationException(
        'название категории не может быть пустым',
        kind: DataFailure.invalidInput,
      );
    }
    if (parentId != null) {
      await _requireValidParent(parentId: parentId, kind: kind);
    }
    final DateTime now = clock();
    return into(categories).insertReturning(
      CategoriesCompanion.insert(
        id: idGenerator(),
        name: trimmedName,
        kind: kind.dbValue,
        parentId: Value(parentId),
        icon: Value(optionalText(icon)),
        color: Value(optionalText(color)),
        isSystem: Value(isSystem),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живая категория по id.
  Future<Category?> findById(String id) => (select(
    categories,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Живые категории, при необходимости только одного вида.
  Future<List<Category>> getAlive({CategoryKind? kind}) =>
      _aliveQuery(kind).get();

  /// Поток живых категорий.
  Stream<List<Category>> watchAlive({CategoryKind? kind}) =>
      _aliveQuery(kind).watch();

  /// Меняет категорию; не переданные поля (`Value.absent()`) остаются как
  /// были, `Value(null)` очищает необязательное поле.
  ///
  /// Вид категории (`kind`) не меняется: от него зависит смысл операций.
  Future<Category> updateCategory(
    String id, {
    Value<String> name = const Value.absent(),
    Value<String?> parentId = const Value.absent(),
    Value<String?> icon = const Value.absent(),
    Value<String?> color = const Value.absent(),
  }) async {
    final Category current = await _requireAlive(id);
    Value<String>? newName;
    if (name.present) {
      final String trimmed = name.value.trim();
      if (trimmed.isEmpty) {
        throw DataValidationException(
          'название категории не может быть пустым',
          kind: DataFailure.invalidInput,
        );
      }
      newName = Value<String>(trimmed);
    }
    if (parentId.present) {
      final String? newParentId = parentId.value;
      if (newParentId == null) {
        // Открепление корневой категории — допустимо.
      } else {
        await _requireValidParent(
          parentId: newParentId,
          kind: CategoryKind.fromDb(current.kind),
          childId: id,
        );
        await _assertNoCycle(categoryId: id, parentId: newParentId);
      }
    }
    await (update(categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(
        name: newName ?? const Value.absent(),
        parentId: parentId,
        icon: icon.present
            ? Value<String?>(optionalText(icon.value))
            : const Value.absent(),
        color: color.present
            ? Value<String?>(optionalText(color.value))
            : const Value.absent(),
        updatedAt: Value(clock()),
      ),
    );
    return _requireAlive(id);
  }

  /// Мягко удаляет категорию. Запрещено для системных категорий, категорий с
  /// живыми вложенными и категорий, на которые ссылаются живые операции:
  /// каскадов нет (§3), а осиротевшие записи потеряли бы смысл.
  Future<void> softDelete(String id) async {
    final Category current = await _requireAlive(id);
    if (current.isSystem) {
      throw DataValidationException(
        'системную категорию «${current.name}» удалить нельзя',
        kind: DataFailure.categoryIsSystem,
      );
    }
    final int children = await _aliveChildrenCount(id);
    if (children > 0) {
      throw DataValidationException(
        'в категории «${current.name}» есть живые вложенные ($children) — '
        'сначала удалите или перенесите их',
        kind: DataFailure.categoryHasChildren,
      );
    }
    final int linked = await _aliveTransactionCount(id);
    if (linked > 0) {
      throw DataValidationException(
        'на категорию «${current.name}» ссылаются живые операции ($linked) — '
        'сначала удалите их',
        kind: DataFailure.categoryHasTransactions,
      );
    }
    final int budgets = await _aliveBudgetCount(id);
    if (budgets > 0) {
      throw DataValidationException(
        'на категорию «${current.name}» ссылается живой бюджет — '
        'сначала удалите его',
        kind: DataFailure.categoryHasBudget,
      );
    }
    final DateTime now = clock();
    await (update(categories)..where((t) => t.id.equals(id))).write(
      CategoriesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  SimpleSelectStatement<$CategoriesTable, Category> _aliveQuery(
    CategoryKind? kind,
  ) {
    final SimpleSelectStatement<$CategoriesTable, Category> query =
        select(categories)
          ..where(
            (t) =>
                t.deletedAt.isNull() &
                (kind == null
                    ? const Constant<bool>(true)
                    : t.kind.equals(kind.dbValue)),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.kind),
            (t) => OrderingTerm.asc(t.name),
          ]);
    return query;
  }

  Future<Category> _requireAlive(String id) async {
    final Category? category = await findById(id);
    if (category == null) {
      throw DataValidationException(
        'категория $id не найдена',
        kind: DataFailure.notFound,
      );
    }
    return category;
  }

  /// Категория по PK без учёта soft delete — нужна для обхода дерева.
  Future<Category?> _findAny(String id) =>
      (select(categories)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> _requireValidParent({
    required String parentId,
    required CategoryKind kind,
    String? childId,
  }) async {
    if (childId != null && parentId == childId) {
      throw DataValidationException(
        'категория не может быть родителем самой себе',
        kind: DataFailure.parentInvalid,
      );
    }
    final Category? parent = await _findAny(parentId);
    if (parent == null || parent.deletedAt != null) {
      throw DataValidationException(
        'родительская категория $parentId не найдена',
        kind: DataFailure.parentInvalid,
      );
    }
    if (CategoryKind.fromDb(parent.kind) != kind) {
      throw DataValidationException(
        'вложенная категория должна быть того же вида, что и родительская',
        kind: DataFailure.parentInvalid,
      );
    }
  }

  /// Перенос не должен создать цикл: поднимаемся по родителям до корня и
  /// следим, что исходная категория не встретится среди них.
  Future<void> _assertNoCycle({
    required String categoryId,
    required String parentId,
  }) async {
    final Set<String> visited = <String>{categoryId};
    String? current = parentId;
    while (current != null) {
      if (!visited.add(current)) {
        throw DataValidationException(
          'перенос создал бы цикл в дереве категорий',
          kind: DataFailure.categoryCycle,
        );
      }
      current = (await _findAny(current))?.parentId;
    }
  }

  Future<int> _aliveChildrenCount(String id) async {
    final Expression<int> count = categories.id.count();
    final TypedResult row = await (selectOnly(categories)
          ..addColumns([count])
          ..where(
            categories.parentId.equals(id) & categories.deletedAt.isNull(),
          ))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> _aliveTransactionCount(String id) async {
    final Expression<int> count = transactions.id.count();
    final TypedResult row = await (selectOnly(transactions)
          ..addColumns([count])
          ..where(
            transactions.categoryId.equals(id) &
                transactions.deletedAt.isNull(),
          ))
        .getSingle();
    return row.read(count) ?? 0;
  }

  Future<int> _aliveBudgetCount(String id) async {
    final Expression<int> count = budgets.id.count();
    final TypedResult row = await (selectOnly(budgets)
          ..addColumns([count])
          ..where(budgets.categoryId.equals(id) & budgets.deletedAt.isNull()))
        .getSingle();
    return row.read(count) ?? 0;
  }
}
