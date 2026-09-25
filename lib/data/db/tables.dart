import 'package:drift/drift.dart';

// Схема v2. v1 — дословно по ARCHITECTURE.md §3 (currencies, accounts,
// categories, transactions). v2 добавляет бюджеты (M2, D-14) — см.
// миграцию в database.dart.
//
// Общие правила (нарушать нельзя):
// - PK — UUID v4 (TEXT), генерирует приложение. Не автоинкремент: это основа
//   будущего слияния файлов/синка.
// - Каждая таблица: created_at, updated_at (UTC), deleted_at (NULL = живая
//   запись). Удаление — только soft delete, без каскадов.
// - Деньги — INTEGER в минорных единицах (копейки/центы). Float для денег
//   запрещён. Курс валюты (rate_to_base) — не деньги, поэтому REAL.
// - Индексы: transactions(date), transactions(account_id),
//   transactions(category_id).

/// Справочник валют (ISO 4217). Первичный ключ — код валюты.
class Currencies extends Table {
  /// ISO 4217, например `RUB`.
  TextColumn get code => text()();

  TextColumn get symbol => text()();

  /// Базовая валюта приложения (в M1 — одна).
  BoolColumn get isBase => boolean().withDefault(const Constant(false))();

  /// Множитель для пересчёта в базовую валюту; пересчёты — M2/M3.
  RealColumn get rateToBase => real().withDefault(const Constant(1))();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {code};
}

/// Счета пользователя. Единая валюта счёта (мультивалютность — позже,
/// без изменения схемы).
class Accounts extends Table {
  /// UUID v4, генерирует приложение.
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// `cash` | `bank` | `card` | `other`.
  TextColumn get kind => text()();

  /// Валюта счёта (FK на `currencies.code`).
  TextColumn get currencyCode => text().references(Currencies, #code)();

  /// Начальный остаток в минорных единицах.
  IntColumn get initialBalanceMinor =>
      integer().withDefault(const Constant(0))();

  /// Порядок отображения в списке.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Категории доходов и расходов, допускают вложенность (`parent_id`).
class Categories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// `income` | `expense`.
  TextColumn get kind => text()();

  /// Родительская категория или NULL для корневой.
  TextColumn get parentId => text().nullable().references(Categories, #id)();

  TextColumn get icon => text().nullable()();

  TextColumn get color => text().nullable()();

  /// Предустановленная (системная) категория — нельзя удалить.
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Операции: доход, расход, перевод между счетами.
@TableIndex(name: 'idx_transactions_date', columns: {#date})
@TableIndex(name: 'idx_transactions_account_id', columns: {#accountId})
@TableIndex(name: 'idx_transactions_category_id', columns: {#categoryId})
class Transactions extends Table {
  TextColumn get id => text()();

  /// `income` | `expense` | `transfer`.
  TextColumn get type => text()();

  /// Счёт операции; для перевода — счёт списания.
  @ReferenceName('outgoingTransactions')
  TextColumn get accountId => text().references(Accounts, #id)();

  /// Счёт зачисления, только для `transfer`.
  @ReferenceName('incomingTransactions')
  TextColumn get targetAccountId =>
      text().nullable().references(Accounts, #id)();

  /// Для перевода — NULL.
  TextColumn get categoryId => text().nullable().references(Categories, #id)();

  /// Сумма в минорных единицах, всегда положительная.
  IntColumn get amountMinor => integer()();

  /// Валюта операции (в M1 наследуется от счёта).
  TextColumn get currencyCode => text().references(Currencies, #code)();

  DateTimeColumn get date => dateTime()();

  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Бюджеты (v2, D-14): повторяющийся месячный лимит расходов по категории.
///
/// Без колонки месяца: бюджет действует каждый календарный месяц, прогресс
/// считается запросом по операциям месяца (см. `BudgetsDao`).
class Budgets extends Table {
  /// UUID v4, генерирует приложение.
  TextColumn get id => text()();

  /// Категория расходов (FK на `categories.id`). Ровно один живой бюджет
  /// на категорию — правило DAO, не SQL: уникальный индекс по живым строкам
  /// в SQLite потребовал бы частичный индекс, а soft delete без каскадов
  /// (§3) оставляет удалённые строки с тем же `category_id`.
  TextColumn get categoryId => text().references(Categories, #id)();

  /// Лимит расходов за месяц в минорных единицах.
  IntColumn get limitMinor => integer()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
