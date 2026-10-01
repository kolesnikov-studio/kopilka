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
import 'package:kopilka/data/attachments_storage.dart';

/// Богатая база: максимум различимых случаев формата v1. Возвращает базу,
/// идентификаторы категорий с иконкой/без и id операции с вложением —
/// они нужны проверкам v4/v6.
Future<
  ({
    AppDatabase db,
    String groceriesId,
    String milkId,
    String attachmentTransactionId,
  })
>
richSeeded() async {
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

  // Категории: вложенность, системные и обычные, с иконкой и без (v4,
  // D-54), мягко удалённые. Идентификаторы нужны второму тесту: посев
  // создаёт одноимённую системную «Продукты», поиск по имени двусмыслен.
  final Category groceries = await database.categoriesDao.create(
    name: 'Продукты',
    kind: CategoryKind.expense,
    isSystem: true,
    iconCode: 'groceries',
  );
  final Category milk = await database.categoriesDao.create(
    name: 'Молочка',
    kind: CategoryKind.expense,
    parentId: groceries.id,
  );
  final String groceriesId = groceries.id;
  final String milkId = milk.id;
  final Category customDeleted = await database.categoriesDao.create(
    name: 'Моё удалённое',
    kind: CategoryKind.expense,
  );
  await database.categoriesDao.softDelete(customDeleted.id);

  // Бюджеты (v2): живой на вложенную категорию + мягко удалённый на ту же
  // категорию (после soft delete бюджета категория снова принимает новый).
  final Budget deadBudget = await database.budgetsDao.create(
    categoryId: milk.id,
    limitMinor: 11111,
  );
  await database.budgetsDao.softDelete(deadBudget.id);
  await database.budgetsDao.create(categoryId: milk.id, limitMinor: 12345);

  // Все виды операций: расход (живой/удалённый), доход с заметкой,
  // перевод между счетами в разных валютах (D-17: обе суммы, вторая —
  // в валюте зачисления).
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
    targetAmountMinor: 88,
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

  // Вложение (v6, D-64): метаданные через DAO живой операции. Файл на
  // диске не нужен: бэкап переносит только метаданные (D-63).
  final Transaction groceriesExpense = await database.transactionsDao.create(
    type: TransactionType.expense,
    accountId: card.id,
    categoryId: groceries.id,
    amountMinor: 1500,
  );
  final String attachmentFileName =
      'att-${groceriesExpense.id.substring(0, 8)}.jpg';
  await database.attachmentsDao.create(
    transactionId: groceriesExpense.id,
    filePath: attachmentFileName,
    mimeType: 'image/jpeg',
    fileSize: 2048,
  );

  // Накопительный счёт (v7, D-81): дата напоминания о процентах
  // переживает round-trip дословно.
  await database.accountsDao.create(
    name: 'Накопительный RUB',
    kind: AccountKind.bank,
    currencyCode: 'RUB',
    initialBalanceMinor: 9900000,
    excludeFromBalance: true,
    interestReminderDate: DateTime.utc(2026, 10, 30),
  );

  // Долг (v7, D-81/D-85): живой с платежом-переводом и мягко удалённый.
  final Debt debt = await database.debtsDao.create(
    person: 'Алексей',
    direction: DebtDirection.theyOweMe,
    amountMinor: 500000,
    currencyCode: 'RUB',
    extraMinor: 25000,
    dueDate: DateTime.utc(2026, 11, 1),
    note: 'под расписку',
  );
  await database.debtsDao.addPayment(
    debt.id,
    transactionId: groceriesExpense.id,
    amountMinor: 100000,
    paidAt: DateTime.utc(2026, 10, 2),
  );
  final Debt deadDebt = await database.debtsDao.create(
    person: 'Мария',
    direction: DebtDirection.iOweThem,
    amountMinor: 300000,
    currencyCode: 'RUB',
  );
  await database.debtsDao.softDelete(deadDebt.id);

  // Вложение долга (M6/D-82, D-90): владелец — ключ d:<id> в той же
  // колонке. Файл на диске не нужен: бэкап переносит только метаданные.
  await database.attachmentsDao.createForDebt(
    debtId: debt.id,
    filePath: 'debt-check.jpg',
    mimeType: 'image/jpeg',
    fileSize: 4096,
  );

  return (
    db: database,
    groceriesId: groceriesId,
    milkId: milkId,
    attachmentTransactionId: groceriesExpense.id,
  );
}

/// Канонизирует документ для сравнения: таблицы как множества строк
/// (порядок строк формат v1 не задаёт), exported_at проверяется отдельно
/// (обновляется при каждом экспорте). Ключ строки — её jsonEncode.
typedef CanonicalDocument = ({Map<String, Set<String>> tables});

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
    final AppDatabase source = (await richSeeded()).db;
    addTearDown(source.close);

    final BackupService service = BackupService(source);
    final String firstJson = await service.exportJson();
    final Map<String, dynamic> first =
        jsonDecode(firstJson) as Map<String, dynamic>;

    // Импортируем в чистую базу: посев не делаем — документ должен
    // самостоятельно восстановить справочники первого запуска.
    final AppDatabase restored = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(restored.close);
    await BackupService(restored).importJson(firstJson);

    final String secondJson = await BackupService(restored).exportJson();
    final Map<String, dynamic> second =
        jsonDecode(secondJson) as Map<String, dynamic>;

    // Оболочка формата: версия совпадает, exported_at — свежее время
    // (обновляется при экспорте, идентичность данных это не нарушает).
    expect(second['schema_version'], first['schema_version']);
    expect(DateTime.parse(second['exported_at'] as String).isUtc, isTrue);

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

  test(
    'round-trip сохраняет содержимое: суммы, валюты, курсы, ссылки',
    () async {
      final (
        db: AppDatabase source,
        groceriesId: String groceriesId,
        milkId: String milkId,
        attachmentTransactionId: String attachmentTransactionId,
      ) = await richSeeded();
      addTearDown(source.close);

      final String firstJson = await BackupService(source).exportJson();
      final AppDatabase restored = AppDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(restored.close);
      await BackupService(restored).importJson(firstJson);

      // Деньги в минорных единицах не искажаются.
      final List<Account> accounts = await restored.accountsDao.getAlive();
      expect(
        accounts,
        hasLength(4),
      ); // один счёт мягко удалён + накопительный v7
      final Account card = accounts.singleWhere(
        (Account a) => a.name == 'Карта',
      );
      expect(card.initialBalanceMinor, 150000);
      final Account savings = accounts.singleWhere(
        (Account a) => a.name == 'Накопления',
      );
      expect(savings.currencyCode, 'USD');

      // Нецелый курс double сохраняется без искажений.
      final Currency usd =
          await restored.currenciesDao.findAlive('USD') as Currency;
      expect(usd.rateToBase, 79.375);

      // Иконки категорий (v4, D-54) переживают round-trip дословно:
      // выбранная — сохраняется, NULL — остаётся NULL. Проверяем по id
      // фикстуры: посев создаёт одноимённую системную «Продукты» без иконки
      // (замок на посев менять нельзя, §8).
      expect(
        (await restored.categoriesDao.findById(groceriesId))?.iconCode,
        'groceries',
      );
      expect((await restored.categoriesDao.findById(milkId))?.iconCode, isNull);

      // Вложенность и мягко удалённые строки физически в базе.
      final List<QueryRow> nested = await restored
          .customSelect(
            "SELECT c2.name AS child, c1.name AS parent FROM categories c1 "
            "JOIN categories c2 ON c2.parent_id = c1.id WHERE c2.deleted_at IS NULL",
          )
          .get();
      expect(nested.single.data['child'], 'Молочка');
      expect(nested.single.data['parent'], 'Продукты');

      // Все виды операций живыми: расход (4, с категорией и без — включая
      // носителя вложения на 1500), доход (2, в т.ч. в USD), перевод между
      // счетами в разных валютах; один расход мягко удалён и в живой список
      // не входит.
      final List<Transaction> alive = await restored.transactionsDao
          .getFiltered();
      expect(alive, hasLength(7));
      final Transaction transfer = alive.singleWhere(
        (Transaction t) =>
            TransactionType.fromDb(t.type) == TransactionType.transfer,
      );
      expect(transfer.accountId, isNotNull);
      expect(transfer.targetAccountId, isNotNull);
      // Вторая сумма перевода (D-17) пережила round-trip без искажений.
      expect(transfer.amountMinor, 7000);
      expect(transfer.targetAmountMinor, 88);

      // Заметка с разделителем CSV и кавычками — исключительно вопрос
      // JSON-дампа: строка не искажается.
      final Transaction income = alive.singleWhere(
        (Transaction t) => t.note != null && t.note!.contains(';'),
      );
      expect(income.note, 'зарплата; премия "за всё"');

      // Балансы совпадают: RESTORED база эквивалентна источнику.
      final int sourceBalance = await source.accountsDao.balanceMinor(card.id);
      final int restoredBalance = await restored.accountsDao.balanceMinor(
        card.id,
      );
      expect(restoredBalance, sourceBalance);

      // Бюджеты (v2): живой один, мягко удалённый физически на месте.
      final List<Budget> budgets = await restored.budgetsDao.getAlive();
      expect(budgets, hasLength(1));
      expect(budgets.single.limitMinor, 12345);
      // Ссылка категории сходится по имени (milk внутри фикстуры не виден).
      final List<QueryRow> budgetCategory = await restored
          .customSelect(
            'SELECT c.name AS name FROM budgets b '
            'JOIN categories c ON c.id = b.category_id '
            "WHERE b.deleted_at IS NULL",
          )
          .get();
      expect(budgetCategory.single.read<String>('name'), 'Молочка');
      final List<QueryRow> deadBudgets = await restored
          .customSelect(
            'SELECT COUNT(*) AS c FROM budgets WHERE deleted_at IS NOT NULL',
          )
          .get();
      expect(deadBudgets.single.read<int>('c'), 1);

      // Вложение (v6, D-64): метаданные пережили round-trip дословно;
      // файл на диске НЕ требуется — бэкап его не переносит (D-63),
      // отсутствие файла — норма (UI 6в обязан показывать это без падения).
      final Attachment? attachment = await restored.attachmentsDao
          .findByTransaction(attachmentTransactionId);
      expect(attachment, isNotNull);
      expect(attachment!.mimeType, 'image/jpeg');
      expect(attachment.fileSize, 2048);
      expect(AttachmentsStorage.isMimeTypeAllowed(attachment.mimeType), isTrue);
      expect(attachment.filePath, endsWith('.jpg'));

      // Мягко удалённая операция без вложения: вложений два — операция (v6)
      // и долг (M6/D-90).
      final List<QueryRow> attachmentsCount = await restored
          .customSelect('SELECT COUNT(*) AS c FROM attachments')
          .get();
      expect(attachmentsCount.single.read<int>('c'), 2);

      // Долги (v7, D-85): живой долг с телом/переплатой/сроком пережил
      // round-trip дословно; платёж сохранил ссылку на перевод; мягко
      // удалённый долг остался физически.
      final List<Debt> aliveDebts = await restored.debtsDao.watchAlive().first;
      expect(aliveDebts, hasLength(1));
      final Debt restoredDebt = aliveDebts.single;
      expect(restoredDebt.person, 'Алексей');
      expect(restoredDebt.direction, 'they_owe_me');
      expect(restoredDebt.amountMinor, 500000);
      expect(restoredDebt.extraMinor, 25000);
      expect(restoredDebt.dueDate, '2026-11-01T00:00:00.000Z');
      expect(restoredDebt.note, 'под расписку');
      final List<DebtPayment> payments = await restored.debtsDao
          .watchPayments(restoredDebt.id)
          .first;
      expect(payments, hasLength(1));
      expect(payments.single.amountMinor, 100000);
      expect(payments.single.transactionId, attachmentTransactionId);
      final List<QueryRow> deadDebts = await restored
          .customSelect(
            "SELECT COUNT(*) AS c FROM debts WHERE deleted_at IS NOT NULL",
          )
          .get();
      expect(deadDebts.single.read<int>('c'), 1);

      // Вложение долга (D-90): ключ владельца d:<id> пережил round-trip —
      // вложение живёт в восстановленном файле и найдено findByDebt.
      final Attachment? debtAttachment = await restored.attachmentsDao
          .findByDebt(restoredDebt.id);
      expect(debtAttachment, isNotNull);
      expect(debtAttachment!.filePath, 'debt-check.jpg');
      expect(debtAttachment.fileSize, 4096);

      // Накопительный счёт (v7, D-81): дата напоминания восстановлена.
      final Account restoredSavings = accounts.singleWhere(
        (Account a) => a.name == 'Накопительный RUB',
      );
      expect(restoredSavings.interestReminderDate, '2026-10-30T00:00:00.000Z');
    },
  );

  test('round-trip мягко удалённых строк: удалённые остаются удалёнными', () async {
    final AppDatabase source = (await richSeeded()).db;
    addTearDown(source.close);

    final String firstJson = await BackupService(source).exportJson();
    final AppDatabase restored = AppDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(restored.close);
    await BackupService(restored).importJson(firstJson);

    // Счёт: 1 мягко удалён физически и не входит в живые.
    final List<QueryRow> deletedAccounts = await restored
        .customSelect(
          'SELECT COUNT(*) AS c FROM accounts WHERE deleted_at IS NOT NULL',
        )
        .get();
    expect(deletedAccounts.single.data['c'], 1);
    expect(
      (await restored.accountsDao.getAlive()).where(
        (Account a) => a.name == 'Закрытый счёт',
      ),
      isEmpty,
    );

    // Категория: мягко удалена, вложенные live-операции нет (у неё не было
    // операций), системная не удалялась.
    final List<QueryRow> deletedCategories = await restored
        .customSelect(
          'SELECT COUNT(*) AS c FROM categories WHERE deleted_at IS NOT NULL',
        )
        .get();
    expect(deletedCategories.single.data['c'], 1);

    // Операция: мягко удалена, физически в дампе.
    final List<QueryRow> deletedTransactions = await restored
        .customSelect(
          'SELECT COUNT(*) AS c FROM transactions WHERE deleted_at IS NOT NULL',
        )
        .get();
    expect(deletedTransactions.single.data['c'], 1);

    // Вложения — метаданные в дампе (v6 + M6-долг, D-90), файлы на диске
    // не требуются: вложение операции и вложение долга.
    final List<QueryRow> attachments = await restored
        .customSelect('SELECT COUNT(*) AS c FROM attachments')
        .get();
    expect(attachments.single.read<int>('c'), 2);
  });

  test('повторный round-trip стабилен: экспорт → импорт → экспорт → импорт → экспорт', () async {
    final AppDatabase source = (await richSeeded()).db;
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

    final CanonicalDocument two = canonical(
      jsonDecode(secondJson) as Map<String, dynamic>,
    );
    final CanonicalDocument three = canonical(
      jsonDecode(thirdJson) as Map<String, dynamic>,
    );
    for (final String table in two.tables.keys) {
      expect(
        three.tables[table],
        two.tables[table],
        reason: 'таблица $table изменилась на втором цикле',
      );
    }
  });
}
