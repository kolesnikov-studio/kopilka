// Round-trip тест слоя экспорта (§4): экспорт → импорт → экспорт обязан
// дать идентичный документ. Гарантия того, что бэкап можно восстановить
// без потери данных: любые потери/искажения формата ловятся здесь, на
// этапе разработки, а не у пользователя при восстановлении.
//
// Фикстура покрывает все различимые случаи формата v1: две валюты (в т.ч.
// нецелый курс), три счёта (все виды kind, два не в базовой валюте,
// soft-deleted), вложенные категории (два уровня, системные и обычные,
// soft-deleted), все виды операций (расход/доход/перевод, живые и
// мягко удалённые, с заметкой и без, история обновления).
//
// drift импортируется с hide isNotNull/isNull — конфликт с flutter_test;
// даты сравниваются через toUtc (drift отдаёт локальную зону).
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/export/backup_service.dart';

/// Богатая база: максимум различимых случаев формата v1.
Future<AppDatabase> richSeeded() async {
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  await seedDefaultsIfEmpty(database);

  // Валюты: базовая RUB из посева + USD с нецелым курсом (проверка,
  // что double не искажается).
  await database.currenciesDao.create(
    code: 'USD',
    symbol: '\$',
    rateToBase: 79.375,
  );

  // Счета: все виды kind + мягко удалённый.
  final Account card = await database.accountsDao.create(
    name: 'Карта',
    kind: AccountKind.card,
    currencyCode: 'RUB',
    initialBalanceMinor: 150000,
  );
  final Account usdCash = await database.accountsDao.create(
    name: 'Наличные USD',
    kind: AccountKind.cash,
    currencyCode: 'USD',
  );
  final Account savings = await database.accountsDao.create(
    name: 'Накопления',
    kind: AccountKind.bank,
    currencyCode: 'USD',
    initialBalanceMinor: 10000,
  );
  final Account deleted = await database.accountsDao.create(
    name: 'Закрытый счёт',
    kind: AccountKind.cash,
    currencyCode: 'RUB',
  );
  await database.transactionsDao.create(
    type: TransactionType.expense,
    accountId: card.id,
    amountMinor: 100,
  );
  await database.accountsDao.softDelete(deleted.id);

  // Категории: вложенность, системные и обычные, мягко удалённые.
  final Category groceries = await database.categoriesDao.create(
    name: 'Продукты',
    kind: CategoryKind.expense,
    isSystem: true,
  );
  final Category milk = await database.categoriesDao.create(
    name: 'Молочка',
    kind: CategoryKind.expense,
    parentId: groceries.id,
  );
  final Category customDeleted = await database.categoriesDao.create(
    name: 'Моё удалённое',
    kind: CategoryKind.expense,
  );
  await database.categoriesDao.softDelete(customDeleted.id);

  // Все виды операций: расход (живой/удалённый), доход с заметкой,
  // перевод между счетами в разных валютах.
  await database.transactionsDao.create(
    type: TransactionType.expense,
    accountId: card.id,
    categoryId: milk.id,
    amountMinor: 12345,
    note: 'молоко',
  );
  await database.transactionsDao.create(
    type: TransactionType.expense,
    accountId: card.id,
    categoryId: groceries.id,
    amountMinor: 999,
  );
  await database.transactionsDao.create(
    type: TransactionType.income,
    accountId: card.id,
    amountMinor: 500000,
    note: 'зарплата; премия "за всё"',
  );
  await database.transactionsDao.create(
    type: TransactionType.transfer,
    accountId: card.id,
    targetAccountId: savings.id,
    amountMinor: 7000,
  );
  await database.transactionsDao.create(
    type: TransactionType.income,
    accountId: usdCash.id,
    amountMinor: 123,
  );
  final Transaction deletedExpense = await database.transactionsDao.create(
    type: TransactionType.expense,
    accountId: card.id,
    amountMinor: 500,
  );
  await database.transactionsDao.softDelete(deletedExpense.id);

  return database;
}

/// Канонизирует документ для сравнения: таблицы как множества строк
/// (порядок строк формат v1 не задаёт), exported_at проверяется отдельно
/// (обновляется при каждом экспорте). Ключ строки — её jsonEncode.
typedef CanonicalDocument = ({
  Map<String, Set<String>> tables,
});

CanonicalDocument canonical(Map<String, dynamic> document) {
  final Map<String, dynamic> data = document['data'] as Map<String, dynamic>;
  return (
    tables: <String, Set<String>>{
      for (final MapEntry<String, dynamic> table in data.entries)
        table.key: <String>{
          for (final dynamic row in table.value as List<dynamic>)
            jsonEncode(row as Map<String, dynamic>),
        },
    },
  );
}

void main() {
  test('экспорт → импорт → экспорт даёт идентичный документ', () async {
    final AppDatabase source = await richSeeded();
    addTearDown(source.close);

    final BackupService service = BackupService(source);
    final String firstJson = await service.exportJson();
    final Map<String, dynamic> first =
        jsonDecode(firstJson) as Map<String, dynamic>;

    // Импортируем в чистую базу: посев не делаем — документ должен
    // самостоятельно восстановить справочники первого запуска.
    final AppDatabase restored = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(restored.close);
    await BackupService(restored).importJson(firstJson);

    final String secondJson = await BackupService(restored).exportJson();
    final Map<String, dynamic> second =
        jsonDecode(secondJson) as Map<String, dynamic>;

    // Оболочка формата: версия совпадает, exported_at — свежее время
    // (обновляется при экспорте, идентичность данных это не нарушает).
    expect(second['schema_version'], first['schema_version']);
    expect(
      DateTime.parse(second['exported_at'] as String).isUtc,
      isTrue,
    );

    // Данные: таблицы как множества строк (jsonEncode каждой строки).
    final CanonicalDocument expected = canonical(first);
    final CanonicalDocument actual = canonical(second);
    for (final String table in expected.tables.keys) {
      expect(
        actual.tables[table],
        expected.tables[table],
        reason: 'таблица $table искажена round-trip',
      );
    }
  });

  test('round-trip сохраняет содержимое: суммы, валюты, курсы, ссылки', () async {
    final AppDatabase source = await richSeeded();
    addTearDown(source.close);

    final String firstJson = await BackupService(source).exportJson();
    final AppDatabase restored = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(restored.close);
    await BackupService(restored).importJson(firstJson);

    // Деньги в минорных единицах не искажаются.
    final List<Account> accounts = await restored.accountsDao.getAlive();
    expect(accounts, hasLength(3)); // один счёт мягко удалён
    final Account card = accounts.singleWhere((Account a) => a.name == 'Карта');
    expect(card.initialBalanceMinor, 150000);
    final Account savings = accounts.singleWhere((Account a) => a.name == 'Накопления');
    expect(savings.currencyCode, 'USD');

    // Нецелый курс double сохраняется без искажений.
    final Currency usd = await restored.currenciesDao.findAlive('USD')
        as Currency;
    expect(usd.rateToBase, 79.375);

    // Вложенность и мягко удалённые строки физически в базе.
    final List<QueryRow> nested = await restored.customSelect(
      "SELECT c2.name AS child, c1.name AS parent FROM categories c1 "
      "JOIN categories c2 ON c2.parent_id = c1.id WHERE c2.deleted_at IS NULL",
    ).get();
    expect(nested.single.data['child'], 'Молочка');
    expect(nested.single.data['parent'], 'Продукты');

    // Все виды операций живыми: расход (3, с категорией и без), доход (2,
    // в т.ч. в USD), перевод между счетами в разных валютах; один расход
    // мягко удалён и в живой список не входит.
    final List<Transaction> alive =
        await restored.transactionsDao.getFiltered();
    expect(alive, hasLength(6));
    final Transaction transfer = alive.singleWhere(
        (Transaction t) =>
            TransactionType.fromDb(t.type) == TransactionType.transfer);
    expect(transfer.accountId, isNotNull);
    expect(transfer.targetAccountId, isNotNull);

    // Заметка с разделителем CSV и кавычками — исключительно вопрос
    // JSON-дампа: строка не искажается.
    final Transaction income =
        alive.singleWhere((Transaction t) => t.note != null && t.note!.contains(';'));
    expect(income.note, 'зарплата; премия "за всё"');

    // Балансы совпадают: RESTORED база эквивалентна источнику.
    final int sourceBalance = await source.accountsDao.balanceMinor(card.id);
    final int restoredBalance = await restored.accountsDao.balanceMinor(card.id);
    expect(restoredBalance, sourceBalance);
  });

  test('round-trip мягко удалённых строк: удалённые остаются удалёнными', () async {
    final AppDatabase source = await richSeeded();
    addTearDown(source.close);

    final String firstJson = await BackupService(source).exportJson();
    final AppDatabase restored = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(restored.close);
    await BackupService(restored).importJson(firstJson);

    // Счёт: 1 мягко удалён физически и не входит в живые.
    final List<QueryRow> deletedAccounts = await restored.customSelect(
      'SELECT COUNT(*) AS c FROM accounts WHERE deleted_at IS NOT NULL',
    ).get();
    expect(deletedAccounts.single.data['c'], 1);
    expect(
      (await restored.accountsDao.getAlive())
          .where((Account a) => a.name == 'Закрытый счёт'),
      isEmpty,
    );

    // Категория: мягко удалена, вложенные live-операции нет (у неё не было
    // операций), системная не удалялась.
    final List<QueryRow> deletedCategories = await restored.customSelect(
      'SELECT COUNT(*) AS c FROM categories WHERE deleted_at IS NOT NULL',
    ).get();
    expect(deletedCategories.single.data['c'], 1);

    // Операция: мягко удалена, физически в дампе.
    final List<QueryRow> deletedTransactions = await restored.customSelect(
      'SELECT COUNT(*) AS c FROM transactions WHERE deleted_at IS NOT NULL',
    ).get();
    expect(deletedTransactions.single.data['c'], 1);
  });

  test('повторный round-trip стабилен: экспорт → импорт → экспорт → импорт → экспорт',
      () async {
    final AppDatabase source = await richSeeded();
    addTearDown(source.close);

    final BackupService sourceService = BackupService(source);
    final String firstJson = await sourceService.exportJson();

    final AppDatabase a = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(a.close);
    await BackupService(a).importJson(firstJson);
    final String secondJson = await BackupService(a).exportJson();

    final AppDatabase b = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(b.close);
    await BackupService(b).importJson(secondJson);
    final String thirdJson = await BackupService(b).exportJson();

    final CanonicalDocument two = canonical(jsonDecode(secondJson) as Map<String, dynamic>);
    final CanonicalDocument three = canonical(jsonDecode(thirdJson) as Map<String, dynamic>);
    for (final String table in two.tables.keys) {
      expect(three.tables[table], two.tables[table],
          reason: 'таблица $table изменилась на втором цикле');
    }
  });
}
