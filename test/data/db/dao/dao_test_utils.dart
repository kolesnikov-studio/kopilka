// Общие помощники тестов слоя данных: in-memory БД, фиксированные часы и
// детерминированные идентификаторы.
//
// isNull из drift — конструктор SQL-выражения; в тестах нужен одноимённый
// матчер flutter_test, поэтому drift-вариант скрыт.
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

/// Часы теста: время двигается только явным [advance], поэтому отметки
/// `created_at` и `updated_at` проверяются точно.
class TestClock {
  TestClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 9, 25, 12);

  DateTime _now;

  /// Текущее время для DAO (передаётся как `clock:`).
  DateTime read() => _now;

  /// Сдвигает время вперёд: нужно, чтобы `updatedAt` отличался от `createdAt`.
  DateTime advance(Duration duration) => _now = _now.add(duration);
}

/// Детерминированный генератор идентификаторов: `acc-1`, `acc-2`, …
IdGenerator sequentialIds(String prefix) {
  int counter = 0;
  return () => '$prefix-${++counter}';
}

/// Слой данных в памяти: БД и DAO с фиксированными часами плюс посев данных.
class DataLayerFixture {
  DataLayerFixture()
    : db = AppDatabase.forTesting(NativeDatabase.memory()),
      clock = TestClock() {
    currencies = CurrenciesDao(db, clock: clock.read);
    accounts = AccountsDao(
      db,
      idGenerator: sequentialIds('acc'),
      clock: clock.read,
    );
    categories = CategoriesDao(
      db,
      idGenerator: sequentialIds('cat'),
      clock: clock.read,
    );
    transactions = TransactionsDao(
      db,
      idGenerator: sequentialIds('tx'),
      clock: clock.read,
    );
  }

  final AppDatabase db;
  final TestClock clock;
  late final CurrenciesDao currencies;
  late final AccountsDao accounts;
  late final CategoriesDao categories;
  late final TransactionsDao transactions;

  Future<void> dispose() => db.close();

  /// Базовая валюта RUB, если её ещё нет.
  Future<Currency> ensureRub() async =>
      await currencies.findAlive('RUB') ?? await currencies.create(code: 'RUB', symbol: '₽', isBase: true);

  /// Счёт в рублях.
  Future<Account> seedAccount({
    String name = 'Наличные',
    AccountKind kind = AccountKind.cash,
    int initialBalanceMinor = 0,
  }) async {
    await ensureRub();
    return accounts.create(
      name: name,
      kind: kind,
      currencyCode: 'RUB',
      initialBalanceMinor: initialBalanceMinor,
    );
  }

  /// Категория.
  Future<Category> seedCategory({
    String name = 'Продукты',
    CategoryKind kind = CategoryKind.expense,
    String? parentId,
    bool isSystem = false,
  }) => categories.create(
    name: name,
    kind: kind,
    parentId: parentId,
    isSystem: isSystem,
  );
}

/// Физическое число строк в таблице: soft delete строку не удаляет (§3).
Future<int> rawRowCount(AppDatabase db, String table) async {
  final QueryRow row = await db
      .customSelect('SELECT COUNT(*) AS count FROM $table')
      .getSingle();
  return row.read<int>('count');
}

/// Канонический ли UUID v4 строка.
final RegExp uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
