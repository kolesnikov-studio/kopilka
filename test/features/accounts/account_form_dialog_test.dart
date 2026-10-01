// Виджет-тесты диалога формы счёта.
//
// Регресс сохранения без выбранной валюты: валидатор поля валюты виден,
// счёт не создаётся, диалог остаётся живым («Отмена» активна и закрывает).
//
// Редактирование счёта: поле «Сумма» означает НОВЫЙ начальный баланс —
// предзаполняется initial_balance_minor и пишется напрямую; операции
// задним числом не трогаются (баланс считается из истории по §3).
//
// Харнесс общий с формой операций (S2, test/helpers/app_harness.dart):
// БД подменяется на in-memory, каталоги настроек — во временном каталоге.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

import '../../helpers/app_harness.dart';

void main() {
  testWidgets(
    'B2.1: в форме создания счёт в один тап сохраняется в базовой валюте',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      // Диалог добавления счёта: валюта не выбрана вручную — дефолт
      // dropdown'а «базовая валюта» (посев: RUB), не первая по алфавиту.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.nameLabel),
        'Наличные',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '500',
      );

      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      // Диалог закрылся, счёт создан в базовой валюте.
      expect(find.byType(AlertDialog), findsNothing);
      final List<Account> accounts = await app.db.accountsDao.getAlive();
      expect(accounts, hasLength(1));
      expect(accounts.single.name, 'Наличные');
      expect(accounts.single.currencyCode, baseCurrencyCode);
    },
  );

  testWidgets(
    'сохранение счёта с операциями без правок не меняет начальный баланс',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      // Счёт с начальным балансом 10 000,00 и живой операцией 500,00 —
      // вычисленный баланс 10 500,00 отличается от начального.
      final Account account = await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
        initialBalanceMinor: 1000000,
      );
      await app.db.transactionsDao.create(
        type: TransactionType.income,
        accountId: account.id,
        amountMinor: 50000,
      );

      // Открыть редактирование и сохранить без единой правки.
      await tester.tap(find.text(app.l10n.navAccounts).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Карта'));
      await tester.pumpAndSettle();

      // Поле «Сумма» предзаполнено начальным балансом, не вычисленным.
      expect(find.text('10000.00'), findsOneWidget);
      expect(find.text('10500.00'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      // Начальный баланс не изменился; баланс счёта по-прежнему складывается
      // из истории операций (§3) — 10 500,00.
      final Account? after = await app.db.accountsDao.findById(account.id);
      expect(after, isNotNull);
      expect(after!.initialBalanceMinor, 1000000);
      expect(await app.db.accountsDao.balanceMinor(account.id), 1050000);
    },
  );

  testWidgets('редактирование счёта с нулевым начальным балансом сохраняется', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_account_dialog_test',
    );

    final Account account = await app.db.accountsDao.create(
      name: 'Копилка',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );

    await tester.tap(find.text(app.l10n.navAccounts).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Копилка'));
    await tester.pumpAndSettle();

    // Ноль в поле «новый начальный баланс» корректен: валидация не
    // блокирует сохранение, значение не меняется.
    expect(find.text('0.00'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    final Account? after = await app.db.accountsDao.findById(account.id);
    expect(after, isNotNull);
    expect(after!.initialBalanceMinor, 0);
  });

  testWidgets(
    'U12: пустое поле начального баланса показывает placeholder «0,00»',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('0,00'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, app.l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('U1: на пустом списке счетов CTA-кнопка открывает форму счёта', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_account_dialog_test',
    );

    // База с посевом пуста счетов — на экране текст и CTA-кнопка
    // (текст совпадает с tooltip FAB, поэтому ищем по типу кнопки).
    expect(
      find.widgetWithText(FilledButton, app.l10n.accountsEmptyCta),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(FilledButton, app.l10n.accountsEmptyCta),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(app.l10n.accountAdd),
      ),
      findsOneWidget,
    );
  });

  testWidgets('U2: ошибка потока показывает ErrorState с кнопкой «Повторить»', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_account_dialog_test',
    );

    // U2-виджет проверяем напрямую: ErrorState рисует текст ошибки
    // и кнопку «Повторить» (поведение экранов покрывают их тесты,
    // здесь — контракт самого виджета).
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ErrorState(onRetry: () {})),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text(app.l10n.errorUnknown), findsOneWidget);
    expect(find.text(app.l10n.retryAction), findsOneWidget);
  });

  testWidgets(
    'B2.1: записи dropdown — «Символ Код — Название» из справочника',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      // Добавляем живую валюту USD: dropdown показывает только живые,
      // не весь ISO-список (спека B3).
      await app.db.currenciesDao.create(code: 'USD', symbol: r'$');

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('₽ RUB — Российский рубль').last);
      await tester.pumpAndSettle();

      // Обе живые валюты видны в меню; ISO-записи (например, JPY) — нет.
      expect(find.text(r'$ USD — Доллар США'), findsOneWidget);
      expect(find.text('¥ JPY — Японская иена'), findsNothing);
    },
  );

  testWidgets('D-24: у счёта с операциями валюта — строка без кнопки смены', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_account_dialog_test',
    );

    final Account account = await app.db.accountsDao.create(
      name: 'Карта',
      kind: AccountKind.card,
      currencyCode: baseCurrencyCode,
    );
    await app.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: account.id,
      amountMinor: 100,
    );

    await tester.tap(find.text(app.l10n.navAccounts).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Карта'));
    await tester.pumpAndSettle();

    // Строка «Валюта: ₽ RUB» вместо dropdown'а; ни кнопки, ни подсказки —
    // счёт с операциями смену валюты не получает (B2.2/D-24).
    expect(find.text('Валюта: ₽ RUB'), findsOneWidget);
    expect(find.text(app.l10n.accountCurrencyChangeAction), findsNothing);
    expect(find.text(app.l10n.accountCurrencyLockedHint), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets(
    'D-24: у счёта без операций есть подсказка и смена валюты сохраняется',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      await app.db.currenciesDao.create(code: 'USD', symbol: r'$');
      await app.db.accountsDao.create(
        name: 'Копилка',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );

      await tester.tap(find.text(app.l10n.navAccounts).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Копилка'));
      await tester.pumpAndSettle();

      // Строка + подпись + кнопка: счёт без операций смену валюты получает.
      expect(find.text('Валюта: ₽ RUB'), findsOneWidget);
      expect(find.text(app.l10n.accountCurrencyLockedHint), findsOneWidget);
      expect(
        find.widgetWithText(TextButton, app.l10n.accountCurrencyChangeAction),
        findsOneWidget,
      );

      // Смена валюты явной кнопкой: выбор из списка живых валют.
      await tester.tap(find.text(app.l10n.accountCurrencyChangeAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(r'$ USD — Доллар США'));
      await tester.pumpAndSettle();

      // B3: после смены валюты поле суммы очищено — пользователь вводит
      // начальный баланс уже в новой валюте.
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '200',
      );
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      final Account? after = await app.db.accountsDao.findById(
        (await app.db.accountsDao.getAlive()).first.id,
      );
      expect(after?.currencyCode, 'USD');
      expect(after?.initialBalanceMinor, 20000);
    },
  );

  testWidgets('B3: смена валюты в форме создания очищает поле суммы', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_account_dialog_test',
    );

    await app.db.currenciesDao.create(code: 'JPY', symbol: '¥');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '500',
    );

    await tester.tap(find.text('₽ RUB — Российский рубль').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('¥ JPY — Японская иена').last);
    await tester.pumpAndSettle();

    expect(find.text('500'), findsNothing);
  });

  testWidgets(
    'D-54: переключатель «не учитывать в балансе» создаёт счёт с флагом',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.nameLabel),
        'Накопительный',
      );
      // Начальный баланс: парсер принимает только суммы строго больше нуля,
      // пустое поле трактуется как 0 — сохранение отклонил бы валидатор.
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '99000',
      );

      // Переключатель выключен по умолчанию (нулевые отличия от v0.4);
      // в форме два тумблера: «не учитывать в балансе» (первый) и
      // «Накопительный» (M6-шаг D, второй).
      final SwitchListTile tile = tester.widget<SwitchListTile>(
        find.byType(SwitchListTile).first,
      );
      expect(tile.value, isFalse);
      // Подсказка называет последствие (по образцу hint Dz-1/D-48).
      expect(find.text(app.l10n.excludeFromBalanceHint), findsOneWidget);

      await tester.tap(find.text(app.l10n.excludeFromBalanceLabel));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isTrue,
      );

      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      final Account account = (await app.db.accountsDao.getAlive()).single;
      expect(account.name, 'Накопительный');
      expect(account.initialBalanceMinor, 9900000);
      expect(account.excludeFromBalance, isTrue);
    },
  );

  testWidgets(
    'D-54: флаг снимается при редактировании и плитка списка помечается',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_account_dialog_test',
      );

      final Account excluded = await app.db.accountsDao.create(
        name: 'Копилка',
        kind: AccountKind.bank,
        currencyCode: baseCurrencyCode,
        initialBalanceMinor: 9900000,
        excludeFromBalance: true,
      );

      await tester.tap(find.text(app.l10n.navAccounts).last);
      await tester.pumpAndSettle();

      // Плитка исключённого счёта помечена подписью (малый значок).
      expect(find.text(app.l10n.accountExcludedBadge), findsOneWidget);

      await tester.tap(find.text('Копилка'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).value,
        isTrue,
        reason: 'форма предзаполняется значением счёта',
      );

      // Снять флаг и сохранить.
      await tester.tap(find.text(app.l10n.excludeFromBalanceLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      final Account? after = await app.db.accountsDao.findById(excluded.id);
      expect(after!.excludeFromBalance, isFalse);
      // Пометка с плитки исчезла.
      expect(find.text(app.l10n.accountExcludedBadge), findsNothing);
    },
  );

  testWidgets('B3: баланс JPY-счёта в плитке списка — без копеек', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_account_dialog_test',
    );

    await app.db.currenciesDao.create(code: 'JPY', symbol: '¥');
    await app.db.accountsDao.create(
      name: 'Иены',
      kind: AccountKind.cash,
      currencyCode: 'JPY',
      initialBalanceMinor: 12345,
    );

    await tester.tap(find.text(app.l10n.navAccounts).last);
    await tester.pumpAndSettle();

    // Формат по экспоненту 0: 12 345 ¥ без дробной части (не «123.45»);
    // символ из карты справочника (R5); группировка в RU — неразрывный
    // пробел, поэтому ищем по фрагменту «345» и отсутствию точки.
    expect(find.textContaining('345'), findsOneWidget);
    expect(find.textContaining('.'), findsNothing);
  });
}
