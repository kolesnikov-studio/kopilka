// Виджет-тесты импорта CSV (M4-шаг 3): флоу «файл → маппинг → подтверждение
// → запись» с подменой выбора файла — шов [CsvImportController.pickDraft]:
// FilePicker в тестах не мокается (грабли fake_async, отчёт шага 2).
// Локаль RU, БД в памяти с севом — по образцу settings_screen_test.dart,
// файлы CSV — по образцу csv_import_test.dart.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/csv_import_controller.dart';
import 'package:kopilka/features/settings/csv_import_flow.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// БД в памяти с севом и двумя счетами: «Наличные» и «Карта» (RUB).
Future<AppDatabase> seeded() async {
  final AppDatabase database = AppDatabase.forTesting(NativeDatabase.memory());
  await seedDefaultsIfEmpty(database);
  await database.accountsDao.create(
    name: 'Наличные',
    kind: AccountKind.cash,
    currencyCode: 'RUB',
    initialBalanceMinor: 5000,
  );
  await database.accountsDao.create(
    name: 'Карта',
    kind: AccountKind.card,
    currencyCode: 'RUB',
  );
  return database;
}

/// Заголовок экспорта v0.3.
const String header =
    'id;date;type;account;target_account;category;amount;currency;note';

/// CSV-строка данных в порядке экспорта v0.3 (заметки без кавычек —
/// тестовые строки без разделителей).
String csvLine(
  String date,
  String type,
  String account,
  String targetAccount,
  String category,
  String amount,
  String currency,
  String note,
) =>
    'uuid;$date;$type;$account;$targetAccount;$category;$amount;$currency;$note';

/// Контроллер со швом вместо FilePicker: файл уже «выбран» тестом.
class _StubCsvImportController extends CsvImportController {
  _StubCsvImportController(this.draft);

  final CsvImportDraft draft;

  @override
  Future<CsvPickOutcome> pickDraft() async => CsvPickLoaded(draft);
}

/// Кнопка запуска флоу — та же точка входа, что у пункта настроек.
class _StartButton extends ConsumerWidget {
  const _StartButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => FilledButton(
        onPressed: () => runCsvImportFlow(context, ref),
        child: const Text('start'),
      );
}

Future<ProviderContainer> _pumpHarness(
  WidgetTester tester, {
  required AppDatabase db,
  required CsvImportDraft draft,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      csvImportControllerProvider.overrideWith(
        () => _StubCsvImportController(draft),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: _StartButton(),
          ),
        ),
      ),
    ),
  );
  return container;
}

/// Меняет привязку колонки [column] на пункт [option] (подпись из l10n).
Future<void> _setMapping(
  WidgetTester tester, {
  required int column,
  required String option,
}) async {
  await tester.tap(
    find.byKey(ValueKey<String>('csv-mapping-dropdown-$column')),
  );
  await tester.pumpAndSettle();
  // Пункт меню — внутри DropdownMenuItem; выбранное значение закрытого
  // dropdown тоже может содержать тот же текст и не должен попадать.
  // Пункт меню рендерится в overlay позже закрытых значений: берём .last
  // (закрытая строка другой колонки может показывать тот же текст).
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

FilledButton _nextButton(WidgetTester tester, AppLocalizations l10n) =>
    tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, l10n.csvMappingNextAction),
    );

void main() {
  testWidgets(
      'happy path: дефолтный маппинг v0.3, предупреждение merge, запись',
      (WidgetTester tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final AppDatabase db = await seeded();
    addTearDown(db.close);
    final String csv = '$header\n'
        '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Продукты', '123.45', 'RUB', 'кофе')}\n'
        '${csvLine('2026-09-27T11:00:00.000Z', 'income', 'Карта', '', 'Зарплата', '1000.00', 'RUB', '')}\n';
    final ProviderContainer container = await _pumpHarness(
      tester,
      db: db,
      draft: CsvImportDraft(
        csv: csv,
        header: header.split(';'),
        rowCount: 2,
      ),
    );
    addTearDown(container.dispose);

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    // Диалог маппинга: шапка файла и число строк данных.
    expect(find.text(l10n.csvImportMappingTitle), findsOneWidget);
    expect(find.text(l10n.csvImportRowCount(2)), findsOneWidget);
    expect(find.text('target_account'), findsOneWidget);

    await tester.tap(find.text(l10n.csvMappingNextAction));
    await tester.pumpAndSettle();

    // Подтверждение ДО записи: предупреждение merge (дубли не отслеживаются).
    expect(find.text(l10n.csvImportConfirmTitle), findsOneWidget);
    expect(find.text(l10n.csvImportMergeWarning(2)), findsOneWidget);

    await tester.tap(find.text(l10n.csvImportConfirmAction));
    // Запись идёт в живую БД: даём флоу завершиться, как в настройках.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.csvImportDone(2)), findsOneWidget);
    final List<Transaction> rows = await db.select(db.transactions).get();
    expect(rows, hasLength(2));
  });

  testWidgets(
      'правка маппинга: переставленные колонки, дубль поля блокирует кнопку',
      (WidgetTester tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final AppDatabase db = await seeded();
    addTearDown(db.close);
    // category и target_account переставлены относительно экспорта v0.3.
    const String swappedHeader =
        'id;date;type;account;category;target_account;amount;currency;note';
    const String csv = '$swappedHeader\n'
        'uuid;2026-09-27T10:00:00.000Z;expense;Наличные;Продукты;;123.45;RUB;кофе\n';
    final ProviderContainer container = await _pumpHarness(
      tester,
      db: db,
      draft: CsvImportDraft(
        csv: csv,
        header: swappedHeader.split(';'),
        rowCount: 1,
      ),
    );
    addTearDown(container.dispose);

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    // Дефолтный маппинг считает колонку 4 счётом зачисления; переводим
    // её в категорию — колонка 5 остаётся «категорией», дубль блокирует.
    await _setMapping(tester, column: 4, option: l10n.csvFieldCategory);
    expect(find.text(l10n.csvMappingDuplicateField), findsOneWidget);
    expect(_nextButton(tester, l10n).onPressed, isNull);

    // Вторую колонку отдаём счёту зачисления — маппинг валиден.
    await _setMapping(tester, column: 5, option: l10n.csvFieldTargetAccount);
    expect(find.text(l10n.csvMappingDuplicateField), findsNothing);
    expect(_nextButton(tester, l10n).onPressed, isNotNull);

    await tester.tap(find.text(l10n.csvMappingNextAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.csvImportConfirmAction));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.csvImportDone(1)), findsOneWidget);
    final List<Transaction> rows = await db.select(db.transactions).get();
    expect(rows, hasLength(1));
  });

  testWidgets(
      'валидация маппинга: без обязательного поля кнопка неактивна',
      (WidgetTester tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final AppDatabase db = await seeded();
    addTearDown(db.close);
    final String csv = '$header\n'
        '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Продукты', '123.45', 'RUB', 'кофе')}\n';
    final ProviderContainer container = await _pumpHarness(
      tester,
      db: db,
      draft: CsvImportDraft(
        csv: csv,
        header: header.split(';'),
        rowCount: 1,
      ),
    );
    addTearDown(container.dispose);

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    // Сняли «Дату» с колонки 1 — обязательное поле пропало.
    await _setMapping(tester, column: 1, option: l10n.csvColumnUnused);
    expect(
      find.text(l10n.csvMappingMissingRequired(l10n.csvFieldDate)),
      findsOneWidget,
    );
    expect(_nextButton(tester, l10n).onPressed, isNull);
  });

  testWidgets(
      'отказ валидации слоя: snack с номером строки, база не изменилась',
      (WidgetTester tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final AppLocalizations l10n =
        await AppLocalizations.delegate.load(const Locale('ru'));
    final AppDatabase db = await seeded();
    addTearDown(db.close);
    // Категории «Такой нет» среди живых категорий расходов нет (D-25).
    final String csv = '$header\n'
        '${csvLine('2026-09-27T10:00:00.000Z', 'expense', 'Наличные', '', 'Такой нет', '123.45', 'RUB', 'кофе')}\n';
    final ProviderContainer container = await _pumpHarness(
      tester,
      db: db,
      draft: CsvImportDraft(
        csv: csv,
        header: header.split(';'),
        rowCount: 1,
      ),
    );
    addTearDown(container.dispose);

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.csvMappingNextAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.csvImportConfirmAction));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    // Отказ всей загрузки с номером строки; частичной загрузки нет.
    expect(find.text(l10n.errorCsvInvalidDataLine(2)), findsOneWidget);
    final List<Transaction> rows = await db.select(db.transactions).get();
    expect(rows, hasLength(0));
  });
}
