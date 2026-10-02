import 'package:drift/drift.dart';

// Схема v8. v1 — дословно по ARCHITECTURE.md §3 (currencies, accounts,
// categories, transactions). v2 добавляет бюджеты (M2, D-14). v3 добавляет
// nullable-колонку transactions.target_amount_minor — суммы зачисления
// перевода между счетами в разных валютах (M3, D-17/D-21). v4 добавляет
// nullable-колонку categories.icon_code — код иконки категории из
// константного справочника core (M5, D-54). v5 добавляет nullable-колонку
// accounts.exclude_from_balance — флаг «не учитывать в балансе» (M5, D-54).
// v6 добавляет таблицу attachments — вложения фото/PDF к операциям
// (M5, D-63); сами файлы живут вне БД (см. data/attachments_service.dart).
// v7 добавляет таблицы debts и debt_payments — долги и их погашения
// (M6, D-81), и nullable-колонку accounts.interest_reminder_date — дату
// напоминания о процентах накопительного счёта (M6, D-81).
// v8 добавляет таблицы plans — срочные планы по категориям (M7, D-115) —
// и scheduled_transfers — отложенные переводы с комиссией (M7, D-115).
// См. миграцию в database.dart.
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

  /// Флаг «не учитывать в балансе» (v5, M5/D-54): true = счёт выпадает из
  /// суммарного баланса (накопительный счёт не раздувает общий итог).
  /// NULL/false = учитывать (дефолт и поведение v0.1–v0.4 без отличий).
  /// Исключение касается только агрегата: персональный баланс счёта
  /// считается как раньше (§3, [_balanceExpression] не тронут).
  BoolColumn get excludeFromBalance => boolean().nullable()();

  /// Дата напоминания о процентах (v7, M6/D-81): UTC-дата или NULL.
  /// NULL = обычный счёт; непустая дата = накопительный счёт (выводить
  /// «накопительный» из exclude_from_balance запрещено — флаг
  /// настраивается явно). Начисление процентов — вручную по напоминанию,
  /// деньгами-переводом (D-81); сам флаг не влияет на балансы.
  TextColumn get interestReminderDate => text().nullable()();

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

  /// Код иконки из справочника `core/category_icons.dart` (v4, M5/D-54):
  /// стабильная snake_case-строка ("food"). NULL = иконка не выбрана;
  /// значение обязано быть в справочнике — контролирует DAO и импорт
  /// бэкапа (строгая валидация, по образцу D-25). Колонка `icon` выше —
  /// старое свободное поле §3, не трогаем (§8).
  TextColumn get iconCode => text().nullable()();

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

  /// Сумма списания в минорных единицах, всегда положительная.
  IntColumn get amountMinor => integer()();

  /// Сумма зачисления перевода в минорных единицах, положительная; валюты —
  /// целевого счёта. Правила D-17: NULL = перевод в одной валюте и любой
  /// не-перевод; не NULL — только когда валюты счетов перевода различаются.
  /// Заполняется только вместе с [amountMinor] (update — одной правкой);
  /// курс обмена хранить не нужно — он производный (отношение сумм).
  IntColumn get targetAmountMinor => integer().nullable()();

  /// Валюта операции (суммы списания); для перевода — валюта счёта
  /// списания, у зачисления — валюта целевого счёта.
  TextColumn get currencyCode => text().references(Currencies, #code)();

  DateTimeColumn get date => dateTime()();

  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Вложения к операциям (v6, D-63): фото или PDF рядом с операцией.
///
/// Сами файлы хранятся вне БД — в каталоге `attachments/` рядом с
/// `kopilka.sqlite` (см. `data/attachments_storage.dart`); здесь — только
/// метаданные. FK на операции без каскада: мягкое удаление операции
/// файл не трогает (§3 — удаление только soft delete).
/// Ровно один живой файл на операцию — правило DAO, не SQL (образец
/// «один живой бюджет на категорию»); расширение до многих — без миграции.
class Attachments extends Table {
  /// UUID v4, генерирует приложение; имя файла без расширения.
  TextColumn get id => text()();

  /// Операция-владелец вложения (FK на `transactions.id`, без каскада).
  TextColumn get transactionId => text().references(Transactions, #id)();

  /// Относительный путь файла в каталоге вложений: `<uuid>.<расширение>`.
  TextColumn get filePath => text()();

  /// MIME-тип из белого списка: image/* или application/pdf (D-63).
  TextColumn get mimeType => text()();

  /// Размер файла в байтах; лимит — константа в `data/attachments_storage.dart`.
  IntColumn get fileSize => integer()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Долги (v7, D-81): кто, сколько, в какой валюте и к когда возврат.
///
/// Отдельная таблица, не операции: долги не идут через счета/категории
/// (§3), а погашение связывается с переводом через `debt_payments`
/// (таблица транзакций фиче-колонками не расширяется, D-81).
class Debts extends Table {
  /// UUID v4, генерирует приложение.
  TextColumn get id => text()();

  /// Имя человека, непустое.
  TextColumn get person => text()();

  /// `they_owe_me` (мне должны) | `i_owe_them` (я должен).
  TextColumn get direction => text()();

  /// Тело долга в минорных единицах, строго положительное.
  IntColumn get amountMinor => integer()();

  /// Переплата суммой в минорных единицах (>= 0): проценты или штраф,
  /// согласованные сторонами одной суммой. Переплата процентом вводится
  /// в UI и сохраняется суммой — производные не храним (D-81).
  IntColumn get extraMinor => integer()();

  /// Валюта долга (FK на `currencies.code`); у платежей та же валюта.
  TextColumn get currencyCode => text().references(Currencies, #code)();

  /// Срок возврата (UTC-дата) или NULL — без срока.
  TextColumn get dueDate => text().nullable()();

  TextColumn get note => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Погашения долга (v7, D-81): факт возврата деньгами.
///
/// FK на долг и операцию без каскада (§3, D-25): мягкое удаление
/// долга или операции-перевода платёж не трогает. Ссылка на операцию
/// необязательна: перевод можно записать позже — платёж цел и без неё.
class DebtPayments extends Table {
  /// UUID v4, генерирует приложение.
  TextColumn get id => text()();

  /// Долг, к которому относится платёж (FK на `debts.id`, без каскада).
  TextColumn get debtId => text().references(Debts, #id)();

  /// Перевод гашения (FK на `transactions.id`, без каскада) или NULL:
  /// платёж можно связать с переводом позже или не связывать вовсе.
  TextColumn get transactionId =>
      text().nullable().references(Transactions, #id)();

  /// Сумма платежа в минорных единицах, строго положительная, в валюте
  /// долга (конвертация — решение пользователя, D-81).
  IntColumn get amountMinor => integer()();

  /// Дата факта платежа (UTC).
  TextColumn get paidAt => text()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Планы (v8, M7/D-115): срочная целевая сумма по категории на период.
///
/// Бюджеты (D-14) и планы — разные сущности (D-115.б): бюджет —
/// повторяющийся месячный лимит расходов без дат, план — целевая сумма
/// на конкретный период [period_start, period_end) обоих направлений.
/// Направление «доход/расход» — не колонка, а производная от
/// `categories.kind` (D-115.а): один источник истины (образец D-17).
/// Сумма — в минорных единицах базовой валюты (образец D-19: у категории
/// валюты нет). Пересекающиеся живые планы одной категории невозможны —
/// правило DAO, не SQL (D-115.в).
class Plans extends Table {
  /// UUID v4, генерирует приложение.
  TextColumn get id => text()();

  /// Категория плана (FK на `categories.id`, без каскада). Направление
  /// плана производно от `categories.kind` (D-115.а).
  TextColumn get categoryId => text().references(Categories, #id)();

  /// Начало периода (TEXT UTC, ISO-8601): полузамкнутый интервал
  /// [periodStart, periodEnd) — образец SQL-окон бюджетов (D-115.а).
  /// TEXT (не unix-секунды), как due_date долгов: сравнения в SQL идут
  /// через strftime('%s', ...).
  TextColumn get periodStart => text()();

  /// Конец периода (TEXT UTC, не включается): строго позже начала.
  TextColumn get periodEnd => text()();

  /// Целевая сумма периода в минорных единицах базовой валюты, > 0 (D-19).
  IntColumn get amountMinor => integer()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Отложенные переводы (v8, M7/D-115/D-119): перевод между счетами,
/// который исполняется в дату `execute_at` сервисом `data/scheduled`.
///
/// Pending-строки **не участвуют в балансах** до исполнения (§8-агрегаты
/// не трогаются, D-115.г): балансы остаются вычисляемыми только из
/// живых операций. Суммы фиксируются при планировании (D-17: валюты
/// счетов различаются ⇔ обе суммы; курс заморожен, при исполнении
/// пересчёта нет). Комиссия — пара `commission_minor` +
/// `commission_category_id` «обе или ни одной» (D-115.г): при исполнении
/// создаётся расход в категорию комиссии со счёта списания. Удаление
/// счёта или категории комиссии при живых отложенных (ещё не исполненных)
/// переводах — отказ DAO.
class ScheduledTransfers extends Table {
  /// UUID v4, генерирует приложение.
  TextColumn get id => text()();

  /// Счёт списания (FK на `accounts.id`, без каскада).
  @ReferenceName('outgoingScheduledTransfers')
  TextColumn get accountId => text().references(Accounts, #id)();

  /// Счёт зачисления (FK на `accounts.id`, без каскада).
  @ReferenceName('incomingScheduledTransfers')
  TextColumn get targetAccountId => text().references(Accounts, #id)();

  /// Сумма списания в минорных единицах, строго положительная.
  IntColumn get amountMinor => integer()();

  /// Сумма зачисления (правило D-17): NULL, когда валюты счетов совпадают;
  /// обязательна и положительна, когда различаются. Замораживается при
  /// планировании — при исполнении не пересчитывается (D-115.г).
  IntColumn get targetAmountMinor => integer().nullable()();

  /// Момент исполнения (TEXT UTC, ISO-8601). Дата создаваемой операции —
  /// именно `execute_at`, не момент запуска (D-119).
  TextColumn get executeAt => text()();

  /// Комиссия в минорных единицах, >= 0: NULL вместе с
  /// `commission_category_id` (без комиссии) или >= 0 вместе с ней
  /// (D-115.г). Одна из пары без другой — отказ DAO.
  IntColumn get commissionMinor => integer().nullable()();

  /// Категория расхода комиссии (FK на `categories.id`, без каскада);
  /// NULL = комиссии нет (D-115.г).
  TextColumn get commissionCategoryId =>
      text().nullable().references(Categories, #id)();

  /// Момент исполнения-отметки (TEXT UTC) или NULL = перевод ещё ожидает
  /// (D-116/D-119: идемпотентность — повторный запуск не исполняет).
  TextColumn get executedAt => text().nullable()();

  /// Созданная исполнением операция-перевод (FK на `transactions.id`,
  /// без каскада) или NULL, пока перевод не исполнен (D-116:
  /// `markExecuted(id, transactionId, executedAt)`).
  TextColumn get executedTransactionId =>
      text().nullable().references(Transactions, #id)();

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
