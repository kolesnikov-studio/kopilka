// Виджет-тесты формы быстрого ввода операции.
//
// Регресс разбора суммы: «25000» создаёт операцию ровно на 2 500 000
// минорных единиц (25 000,00 р), сумма в валюте счёта.
//
// Харнесс общий с формой счёта (S2, test/helpers/app_harness.dart):
// БД подменяется на in-memory, каталоги настроек — во временном каталоге.
//
// M3-шаг 4 (B4.1): форма перевода — одна сумма (валюты совпадают) или
// две (различаются) с расчётной строкой курса и умным предзаполнением.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/rate.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import '../../helpers/app_harness.dart';

/// Запускает приложение с окном побольше (спека U9: показ валидации
/// в узком окне давал несвязанный RenderFlex-overflow).
Future<AppHarness> _pumpApp(WidgetTester tester) => pumpDialogApp(
  tester,
  size: const Size(600, 1000),
  tempDirPrefix: 'kopilka_tx_transfer_test',
);

/// Открывает форму перевода: вкладка операций → фильтр «Переводы» → FAB
/// (U10: FAB открывает форму активного фильтра).
Future<void> _openTransferForm(WidgetTester tester, AppHarness app) async {
  await tester.tap(find.text(app.l10n.navTransactions).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(app.l10n.filterTransfers));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(FloatingActionButton));
  await tester.pumpAndSettle();
}

/// Выбирает счёт [name] в dropdown'е формы с меткой [label]: пустой
/// dropdown не содержит текста, поэтому поле ищется по labelText.
Future<void> _selectAccount(
  WidgetTester tester,
  AppHarness app,
  String label,
  String name,
) async {
  final Finder dropdowns = find.byType(DropdownButtonFormField<String>);
  final int total = tester.widgetList(dropdowns).length;
  var opened = false;
  for (int i = 0; i < total && !opened; i++) {
    final DropdownButtonFormField<String> field = tester
        .widget<DropdownButtonFormField<String>>(dropdowns.at(i));
    if (field.decoration.labelText == label) {
      await tester.tap(dropdowns.at(i));
      await tester.pumpAndSettle();
      opened = true;
    }
  }
  expect(opened, isTrue, reason: 'нет dropdown с меткой «$label»');
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

/// Поле суммы по метке (AmountField задаёт labelText): decoration у
/// TextFormField не публичный — читаем встроенный TextField.
TextField _amountField(WidgetTester tester, AppHarness app, String label) =>
    tester.widget<TextField>(find.widgetWithText(TextField, label));

void main() {
  testWidgets(
    'целая сумма «25000» сохраняется как 25 000,00 (2 500 000 minor)',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_tx_dialog_test',
      );

      // Счёт в валюте посева: операция наследует его валюту (§3).
      final Account account = await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );

      // Переключаемся на вкладку операций, фильтр типа «Доходы» и быстрый
      // ввод: FAB открывает форму выбранного фильтром типа.
      await tester.tap(find.text(app.l10n.navTransactions).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.filterIncomes));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '25000',
      );
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      // M5-шаг 6в: после сохранения диалог остаётся открытым в режиме
      // вложения (кнопка «Готово» закрывает), операция записана точно.
      expect(find.text(app.l10n.doneAction), findsOneWidget);
      final List<Transaction> rows = await app.db.transactionsDao.getFiltered(
        TransactionFilter(accountId: account.id),
      );
      expect(rows, hasLength(1));
      expect(TransactionType.fromDb(rows.single.type), TransactionType.income);
      expect(rows.single.amountMinor, 2500000);
      expect(rows.single.currencyCode, baseCurrencyCode);
    },
  );

  testWidgets(
    'U10: FAB открывает форму активного фильтра и подписывается его типом',
    (WidgetTester tester) async {
      final AppHarness app = await pumpDialogApp(
        tester,
        tempDirPrefix: 'kopilka_tx_dialog_test',
      );

      await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );

      await tester.tap(find.text(app.l10n.navTransactions).last);
      await tester.pumpAndSettle();

      // Без фильтра FAB — нейтральная «Добавить»: выбор типа в листе
      // (доход должен быть доступен без фильтра).
      expect(find.text(app.l10n.addAction), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.expenseAction), findsOneWidget);
      expect(find.text(app.l10n.incomeAction), findsOneWidget);
      expect(find.text(app.l10n.transferAction), findsOneWidget);

      // Выбор «Доход» в листе открывает форму дохода.
      await tester.tap(find.text(app.l10n.incomeAction));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.newIncomeTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, app.l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      // Лист закрывается без выбора — форма не открывается.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byType(FloatingActionButton)) -
            const Offset(0, 200),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      // С фильтром «Доходы» подпись FAB меняется на «Доход» и форма
      // открывается доходом: тип операции виден по заголовку диалога.
      await tester.tap(find.text(app.l10n.filterIncomes));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.incomeAction), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.newIncomeTitle), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, app.l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'U9: без выбранного счёта форма подсвечивает dropdown валидацией',
    (WidgetTester tester) async {
      // Окно 600×1000 оставлено по U9 (ревью 2026-09-26): при
      // показе ошибки валидации в узких 400px dropdown категории давал
      // RenderFlex-overflow, не связанный с сутью теста.
      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_tx_dialog_test',
      );

      // В посеве счетов нет: dropdown пуст, значение не выбрано.
      await tester.tap(find.text(app.l10n.navTransactions).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.l10n.expenseAction));
      await tester.pumpAndSettle();

      // Пытаемся сохранить: валидация счёта видна, диалог живой.
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '100',
      );
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pump();

      expect(find.text(app.l10n.selectAccountValidator), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets('B3: экспонент 0 (JPY) — разделитель в поле суммы не вводится', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_tx_dialog_test',
    );

    await app.db.currenciesDao.create(code: 'JPY', symbol: '¥');
    final Account jpy = await app.db.accountsDao.create(
      name: 'Иены',
      kind: AccountKind.cash,
      currencyCode: 'JPY',
    );

    await tester.tap(find.text(app.l10n.navTransactions).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(app.l10n.expenseAction));
    await tester.pumpAndSettle();

    // Выбираем счёт в иенах: единственный живой счёт — выбран по умолчанию.
    expect(find.text('Иены'), findsOneWidget);

    // Попытка ввести «1,5»: форматтер с экспонентом 0 не даёт ввести
    // разделитель (silent-ограничение, B3).
    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '1',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '1,',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, app.l10n.amountLabel),
          )
          .controller
          ?.text,
      '1',
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '1500',
    );
    await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
    await tester.pumpAndSettle();

    // Сумма сохранена в минорных единицах без масштаба ×100 (экспонент 0);
    // диалог остался в режиме вложения (6в).
    expect(find.text(app.l10n.doneAction), findsOneWidget);
    final List<Transaction> rows = await app.db.transactionsDao.getFiltered(
      TransactionFilter(accountId: jpy.id),
    );
    expect(rows.single.amountMinor, 1500);
    expect(rows.single.currencyCode, 'JPY');
  });

  testWidgets('B3: экспонент 3 (KWD) — три знака, суффикс символа счёта', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_tx_dialog_test',
    );

    await app.db.currenciesDao.create(code: 'KWD', symbol: 'د.ك');
    final Account kwd = await app.db.accountsDao.create(
      name: 'Динары',
      kind: AccountKind.bank,
      currencyCode: 'KWD',
    );

    await tester.tap(find.text(app.l10n.navTransactions).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(app.l10n.expenseAction));
    await tester.pumpAndSettle();

    // Три знака принимаются (форматтер пропускает, парсер разбирает).
    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '3,500',
    );
    // Четвёртый знак не вводится (silent-ограничение).
    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '3,5005',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, app.l10n.amountLabel),
          )
          .controller
          ?.text,
      '3,500',
    );

    await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
    await tester.pumpAndSettle();

    // Диалог остался в режиме вложения (6в); суммы записаны.
    expect(find.text(app.l10n.doneAction), findsOneWidget);
    final List<Transaction> rows = await app.db.transactionsDao.getFiltered(
      TransactionFilter(accountId: kwd.id),
    );
    // 3,500 KWD = 3500 минорных (миллимные единицы), не 350 000.
    expect(rows.single.amountMinor, 3500);
  });

  testWidgets('B3: при смене счёта поле суммы очищается (валюта сменилась)', (
    WidgetTester tester,
  ) async {
    final AppHarness app = await pumpDialogApp(
      tester,
      tempDirPrefix: 'kopilka_tx_dialog_test',
    );

    await app.db.currenciesDao.create(code: 'USD', symbol: r'$');
    await app.db.accountsDao.create(
      name: 'Рубли',
      kind: AccountKind.cash,
      currencyCode: baseCurrencyCode,
    );
    await app.db.accountsDao.create(
      name: 'Доллары',
      kind: AccountKind.bank,
      currencyCode: 'USD',
    );

    await tester.tap(find.text(app.l10n.navTransactions).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(app.l10n.expenseAction));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, app.l10n.amountLabel),
      '100',
    );

    // Смена счёта в dropdown'е: поле очищается (просто и предсказуемо,
    // решение ревью: пересчитывать введённый текст не нужно).
    await tester.tap(find.text('Рубли').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Доллары').last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, app.l10n.amountLabel),
          )
          .controller
          ?.text,
      '',
    );
  });

  testWidgets(
    'B4.1: одинаковые валюты счетов — одна сумма, вторая не показывается, пишется NULL',
    (WidgetTester tester) async {
      final AppHarness app = await _pumpApp(tester);
      await app.db.accountsDao.create(
        name: 'Рубль-наличные',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      await app.db.accountsDao.create(
        name: 'Рубль-карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );
      await _openTransferForm(tester, app);
      await _selectAccount(tester, app, app.l10n.accountFrom, 'Рубль-наличные');
      await _selectAccount(tester, app, app.l10n.accountTo, 'Рубль-карта');

      // Одна сумма с дефолтным ключом amountLabel; «Списано»/«Зачислено»
      // и расчётная строка курса не показываются (B4.1: не disabled —
      // не показывается вовсе).
      expect(
        find.widgetWithText(AmountField, app.l10n.amountLabel),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AmountField, app.l10n.transferAmountOut),
        findsNothing,
      );
      expect(
        find.widgetWithText(AmountField, app.l10n.transferAmountIn),
        findsNothing,
      );
      expect(find.textContaining('По курсу'), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.amountLabel),
        '100',
      );
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      // Диалог остался в режиме вложения (6в); перевод записан.
      expect(find.text(app.l10n.doneAction), findsOneWidget);
      final List<Transaction> rows = await app.db.transactionsDao.getFiltered(
        TransactionFilter(type: TransactionType.transfer),
      );
      expect(rows, hasLength(1));
      expect(rows.single.amountMinor, 10000);
      // D-17: перевод в одной валюте хранит target_amount_minor = NULL.
      expect(rows.single.targetAmountMinor, isNull);
    },
  );

  testWidgets(
    'B4.1: разные валюты — две суммы, предзаполнение по курсу, расчётная строка, запись обеих сумм',
    (WidgetTester tester) async {
      final AppHarness app = await _pumpApp(tester);
      // 1 $ = 97,50 ₽; списание в рублях, зачисление в долларах.
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      await app.db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      await _openTransferForm(tester, app);

      await _selectAccount(tester, app, app.l10n.accountFrom, 'Рубли');
      await _selectAccount(tester, app, app.l10n.accountTo, 'Доллары');

      // Две суммы с метками B4.1 и суффиксами валют своих счетов.
      expect(
        _amountField(
          tester,
          app,
          app.l10n.transferAmountOut,
        ).decoration?.suffixText,
        '₽',
      );
      expect(
        _amountField(
          tester,
          app,
          app.l10n.transferAmountIn,
        ).decoration?.suffixText,
        r'$',
      );
      expect(
        find.widgetWithText(AmountField, app.l10n.amountLabel),
        findsNothing,
      );

      // Ввод суммы списания: вторая сумма предзаполняется оценкой по
      // текущему курсу (100 ₽ → 1,03 $: 100/97,5 = 1,0256, half-up D-22)
      // и видна подсказка B4.1.
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountOut),
        '100',
      );
      await tester.pumpAndSettle();
      expect(
        _amountField(tester, app, app.l10n.transferAmountIn).controller?.text,
        '1,03',
      );
      expect(find.text(app.l10n.transferPrefillNote), findsOneWidget);

      // Расчётная строка — производный курс введённых сумм (D-17):
      // 100 ₽ за 1,03 $ ≈ 0,971; формат — formatRate шага 2 (до 6
      // значащих знаков, D-26; EN-разделитель — конвенция формата курса).
      final String prefilledRate = formatRate(derivedRate(10000, 103));
      expect(
        find.text(app.l10n.transferRateLine('RUB', prefilledRate, 'USD')),
        findsOneWidget,
      );

      // Правка второй суммы пользователем снимает пометку предзаполнения
      // и пересчитывает строку (0,5 $ за 100 ₽ = 0,005).
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountIn),
        '0,5',
      );
      await tester.pumpAndSettle();
      expect(find.text(app.l10n.transferPrefillNote), findsNothing);
      expect(
        find.text(
          app.l10n.transferRateLine(
            'RUB',
            formatRate(derivedRate(10000, 50)),
            'USD',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pumpAndSettle();

      // Диалог остался в режиме вложения (6в); обе суммы записаны.
      expect(find.text(app.l10n.doneAction), findsOneWidget);
      final List<Transaction> rows = await app.db.transactionsDao.getFiltered(
        TransactionFilter(type: TransactionType.transfer),
      );
      expect(rows, hasLength(1));
      // 100 ₽ списанием (10000 минорных), 0,50 $ зачислением (50 минорных).
      expect(rows.single.amountMinor, 10000);
      expect(rows.single.targetAmountMinor, 50);
      expect(rows.single.currencyCode, baseCurrencyCode);
    },
  );

  testWidgets(
    'B4.1: без курса в справочнике предзаполнения нет, поле пустое без ошибки',
    (WidgetTester tester) async {
      final AppHarness app = await _pumpApp(tester);
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      // Случай B4.1 «валюты нет в справочнике» легитимен только как порча
      // данных: DAO не даёт ни создать счёт без валюты в справочнике, ни
      // удалить валюту с живым счётом. Симулируем мягкое удаление записи
      // USD прямым UPDATE (FK не нарушается) — счёт переживает валюту.
      await app.db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      await app.db.customStatement(
        "UPDATE currencies SET deleted_at = strftime('%s', 'now') WHERE code = 'USD'",
      );
      await _openTransferForm(tester, app);

      await _selectAccount(tester, app, app.l10n.accountFrom, 'Рубли');
      await _selectAccount(tester, app, app.l10n.accountTo, 'Доллары');

      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountOut),
        '100',
      );
      await tester.pumpAndSettle();

      expect(
        _amountField(tester, app, app.l10n.transferAmountIn).controller?.text,
        '',
      );
      expect(find.text(app.l10n.transferPrefillNote), findsNothing);
      // Валидация обеих сумм: сохранение с пустой второй суммой невозможно.
      await tester.tap(find.widgetWithText(FilledButton, app.l10n.saveAction));
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        _amountField(
          tester,
          app,
          app.l10n.transferAmountIn,
        ).decoration?.errorText,
        app.l10n.amountInvalid,
      );
    },
  );

  testWidgets(
    'B4.1: смена любого счёта очищает обе суммы, пересчёт под новую валюту',
    (WidgetTester tester) async {
      final AppHarness app = await _pumpApp(tester);
      await app.db.currenciesDao.create(
        code: 'USD',
        symbol: r'$',
        rateToBase: 97.5,
      );
      await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      await app.db.accountsDao.create(
        name: 'Доллары',
        kind: AccountKind.bank,
        currencyCode: 'USD',
      );
      await _openTransferForm(tester, app);

      await _selectAccount(tester, app, app.l10n.accountFrom, 'Рубли');
      await _selectAccount(tester, app, app.l10n.accountTo, 'Доллары');
      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountOut),
        '100',
      );
      await tester.pumpAndSettle();
      expect(
        _amountField(tester, app, app.l10n.transferAmountIn).controller?.text,
        '1,03',
      );

      // Смена счёта списания на долларовый: обе суммы очищаются (D-27 —
      // смена валюты поля очищает сумму), поля остаются с одной суммой
      // (валюты счетов теперь совпадают).
      await _selectAccount(tester, app, app.l10n.accountFrom, 'Доллары');
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(AmountField, app.l10n.transferAmountOut),
        findsNothing,
      );
      expect(
        _amountField(tester, app, app.l10n.amountLabel).controller?.text,
        '',
      );
    },
  );

  testWidgets(
    'B4.1: экспонент 0 (JPY) — предзаполнение целым числом, без разделителя',
    (WidgetTester tester) async {
      final AppHarness app = await _pumpApp(tester);
      // 1 $ = 0,60 ₽-базы... в минорных: курс JPY 0.6 к базовой RUB.
      await app.db.currenciesDao.create(
        code: 'JPY',
        symbol: '¥',
        rateToBase: 0.6,
      );
      await app.db.accountsDao.create(
        name: 'Рубли',
        kind: AccountKind.cash,
        currencyCode: baseCurrencyCode,
      );
      await app.db.accountsDao.create(
        name: 'Йены',
        kind: AccountKind.bank,
        currencyCode: 'JPY',
      );
      await _openTransferForm(tester, app);

      await _selectAccount(tester, app, app.l10n.accountFrom, 'Рубли');
      await _selectAccount(tester, app, app.l10n.accountTo, 'Йены');

      await tester.enterText(
        find.widgetWithText(TextFormField, app.l10n.transferAmountOut),
        '100',
      );
      await tester.pumpAndSettle();
      // 100 ₽ → база 100 → 100 / 0.6 = 166,(6) мажорных йен → 167
      // (half-up, D-22); без дробной части (экспонент 0).
      expect(
        _amountField(tester, app, app.l10n.transferAmountIn).controller?.text,
        '167',
      );
      expect(
        _amountField(
          tester,
          app,
          app.l10n.transferAmountIn,
        ).decoration?.suffixText,
        '¥',
      );
    },
  );
}
