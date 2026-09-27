// Виджет-тесты списка операций: строка перевода между валютами (B4.3).
//
// M3-шаг 4: у мультивалютного перевода обе суммы справа в компактном
// формате «− 100,00 ₽ → 1,00 $», каждая по экспоненту своей валюты;
// не помещается — перенос на вторую строку (Wrap), без сокращений.
// Одно-валютный перевод — одна сумма, как раньше. Курс в список не
// выводится (B4.3).
//
// Здесь же путь B4.2 (D-17): правки операций в M3 нет (edit-диалог —
// бэклог M4), «исправление» перевода между валютами — удалить и создать
// заново; обе суммы пишутся парой, удаление мягкое.
//
// Харнесс общий (S2, test/helpers/app_harness.dart): in-memory БД,
// RU-локаль, окно узкое по умолчанию — здесь окно расширяется, где нужен
// перенос.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import '../../helpers/app_harness.dart';

/// Ожидание суммы — только через форматтер (§7, грабли): группировка идёт
/// неразрывными пробелами, строковые литералы с обычным пробелом не равны.
String _amount(AppHarness app, int amountMinor, {String symbol = '₽'}) =>
    formatMoneyMinor(amountMinor, symbol: symbol, locale: 'ru');

/// Приложение открывается на вкладке счетов (там свои суммы-балансы —
/// они мешают поискам): переключаемся на список операций.
Future<void> _openTransactionsTab(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navTransactions).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'B4.3: мультивалютный перевод — обе суммы по экспонентам своих валют',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_tx_tile_test',
      );
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      final Account rub = await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Account usd = await app.db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      await app.db.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 1000000,
        targetAmountMinor: 10256,
      );
      await _openTransactionsTab(tester, app);

      // Строка перевода содержит обе суммы, каждая в формате своей
      // валюты (экспонент 2).
      expect(
        find.textContaining(_amount(app, 1000000)),
        findsOneWidget,
      );
      expect(
        find.textContaining(_amount(app, 10256, symbol: r'$')),
        findsOneWidget,
      );
      // Курс в строку списка не выводится (B4.3).
      expect(find.textContaining('По курсу'), findsNothing);
    },
  );

  testWidgets(
    'B4.3: одно-валютный перевод — одна сумма, как раньше',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_tx_tile_test',
      );
      final Account rub = await app.db.accountsDao.create(
        name: 'Рубль-наличные',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Account card = await app.db.accountsDao.create(
        name: 'Рубль-карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );
      await app.db.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: card.id,
        amountMinor: 150000,
      );
      await _openTransactionsTab(tester, app);

      // Одна сумма со стрелкой направления; второй суммы нет.
      expect(find.textContaining(_amount(app, 150000)), findsOneWidget);
      expect(find.textContaining('102,56'), findsNothing);
    },
  );

  testWidgets(
    'B4.3: длинные суммы переносятся на вторую строку без сокращений',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_tx_tile_test',
      );
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      final Account rub = await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Account usd = await app.db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      // Намеренно длинные суммы: группировка и дробная часть должны
      // сохраниться целиком (сокращать и округлять нельзя — B4.3).
      await app.db.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 1234567890,
        targetAmountMinor: 123456789,
      );
      await _openTransactionsTab(tester, app);

      // Обе суммы присутствуют полностью, без усечения (Wrap переносит).
      expect(find.textContaining(_amount(app, 1234567890)), findsOneWidget);
      expect(
        find.textContaining(_amount(app, 123456789, symbol: r'$')),
        findsOneWidget,
      );
      // Нет исключений переполнения — тест бы упал на assert пейнтера.
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'B4.2: удаление и пересоздание перевода между валютами пишет пару сумм',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_tx_tile_test',
      );
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      final Account rub = await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      final Account usd = await app.db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      final Transaction original = await app.db.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 1000000,
        targetAmountMinor: 10256,
      );
      await _openTransactionsTab(tester, app);

      // Долгий тап по плитке → подтверждение → мягкое удаление (B4.2:
      // способ «исправить» перевод — удалить и создать заново).
      await tester.longPress(find.textContaining(_amount(app, 1000000)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.deleteAction).last);
      await tester.pumpAndSettle();

      // findById отфильтровывает удалённые — строка живых исчезла;
      // мягкость удаления проверяем сырым чтением: строка осталась,
      // deleted_at заполнен (§3).
      expect(
        await app.db.transactionsDao.findById(original.id),
        isNull,
      );
      final List<Transaction> rawRows =
          await app.db.select(app.db.transactions).get();
      final Transaction deletedRow = rawRows.singleWhere(
        (Transaction t) => t.id == original.id,
      );
      expect(deletedRow.deletedAt, isNotNull, reason: 'удаление мягкое (§3)');

      // Пересоздание с исправленными суммами — парой, как требует D-17.
      final Transaction recreated = await app.db.transactionsDao.create(
        type: TransactionType.transfer,
        accountId: rub.id,
        targetAccountId: usd.id,
        amountMinor: 2000000,
        targetAmountMinor: 20513,
      );
      expect(recreated.amountMinor, 2000000);
      expect(recreated.targetAmountMinor, 20513);

      // Оба счёта живы; в списке — только новая операция.
      expect(
        (await app.db.accountsDao.findById(rub.id))?.deletedAt,
        isNull,
      );
      expect(
        (await app.db.accountsDao.findById(usd.id))?.deletedAt,
        isNull,
      );
      final List<Transaction> alive = await app.db.transactionsDao
          .getFiltered(TransactionFilter(type: TransactionType.transfer));
      expect(alive, hasLength(1));
      expect(alive.single.id, recreated.id);
      // Поток списка перекачивается после прямой записи в БД.
      await tester.pumpAndSettle();
      expect(find.textContaining(_amount(app, 2000000)), findsOneWidget);
    },
  );
}
