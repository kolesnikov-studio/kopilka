// DoD-сценарий M7 «Планирование» end-to-end (ROADMAP M7, шаги A–D;
// решения D-115–D-121; образец — DoD-замок M6 m6_savings_dod_test.dart,
// приёмка D-104).
//
// Полный пользовательский путь над живыми потоками (харнесс S2:
// pumpDialogApp — in-memory drift, RU-локаль, KopilkaApp целиком):
// 1. План расхода через форму раздела «Планирование»: план/факт/остаток,
//    бейдж «Идёт», период текущего месяца; факт — расходом через форму
//    быстрого ввода, строка живым потоком показывает факт и остаток.
// 2. Автобюджет: диалог по среднему доходу закрытого месяца, префилл
//    «средний × срок» с канонической запятой (S2/D-137), создание по
//    явному согласию — план в секции доходов.
// 3. Прогноз баланса на «Отчётах»: карточка рисуется с данными (спека
//    D-130 §1; «нет данных» не показывается — планы и история есть).
// 4. Opt-in напоминаний в настройках (D-83/D-88.1) — путь включения
//    оповещений о перерасходе (D-118).
// 5. Перерасход плана (строка «Перерасход на …») — база оповещения ниже.
// 6. Отложенный перевод с комиссией через форму (секции «Отложить»/
//    «Комиссия», спека D §3) — снек «Перевод запланирован», подсекция
//    «Ожидают»: строка счетов + комиссия.
// 7. «Запуск приложения» — эмуляция автозапуска биндингов (прецедент
//    D-51.в, как syncOnLaunch в DoD M4): назревший перевод исполняется
//    (операция с датой execute_at + расход комиссии, D-119), подсекция
//    «Исполнены»; оповещение о перерасходе (план 1100/1000 ≥ порога 80%
//    D-118) и уведомление об исполнении показываются через шов
//    RemindersPlugin (D-83), подменённый шпигоном: платформенный канал в
//    виджет-тесте ненаблюдаем, шов — единственная точка показа.
//
// Seed-отступления DoD (пути ввода закрыты точечными замками форм,
// прецедент D-51.в/приёмка D-104): счета, категория комиссии, доход
// закрытого месяца (база автобюджета) и период плана-перерасхода
// (датапикер в fake_async требует шва — D-97) сеются DAO; план, расход,
// автобюджет, opt-in и отложенный перевод идут через UI. Продуктовый код
// не менялся — шов только в тест-харнессе (параметр overrides).
//
// Ожидания сумм — только через formatMoneyMinor (§7); даты — UTC (§3);
// меню dropdown — фиксированные pump (конвенция D-136); дрейф-потоки —
// через runAsync (_settle / _settleUntil).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/reminders/reminders_permission.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';
import 'package:kopilka/data/reminders/reminders_texts.dart';
import 'package:kopilka/data/scheduled/scheduled_transfers_binding.dart';
import 'package:kopilka/features/transactions/transactions_screen.dart'
    show transferLine;
import 'package:kopilka/l10n/gen/app_localizations.dart';
import 'package:riverpod/misc.dart' show Override;

import '../helpers/app_harness.dart';

/// Ожидание суммы — только через форматтер (§7, грабли).
String _money(AppHarness app, int amountMinor, {String symbol = '₽'}) =>
    formatMoneyMinor(amountMinor, symbol: symbol, locale: 'ru');

/// Полночь текущего дня UTC (§3).
DateTime _todayUtc() {
  final DateTime now = DateTime.now().toUtc();
  return DateTime.utc(now.year, now.month, now.day);
}

/// Дрейф-потоки завершают future вне кадров (§7) — даём завершиться
/// и пересобрать провайдеров (образец _settle m6_savings_dod_test).
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

/// Ждёт, пока [finder] появится: чередуем реальное время (runAsync —
/// вне его дрейф-потоки в fake_async-зоне не завершаются, D-136) и
/// продвижение фейковых часов (таймеры зоны теста). Цикл ограничен —
/// ожидание не виснет, а падение даёт понятный expect ниже.
Future<void> _settleUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 30,
}) async {
  for (int i = 0; i < attempts && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Пункт нижней навигации по подписи: заголовок AppBar содержит тот же
/// текст — матчится только навигация (образец planning_screen_test).
Future<void> _nav(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

/// Ждёт условия не по дереву (счётчики шпигонов), тем же ритмом, что
/// [_settleUntil]: цепочки биндингов идут в real-зоне (окна runAsync),
/// фейковая очередь сбрасывается драйвером после каждого окна.
Future<void> _settleWhile(
  WidgetTester tester,
  bool Function() pending, {
  int attempts = 30,
}) async {
  for (int i = 0; i < attempts && pending(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Dropdown по метке поля: в формах типы аргумента различны
/// (String / String?) — предикат по метке, а не по типу (U8/семпл).
Finder _dropdown(String label) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is DropdownButtonFormField && widget.decoration.labelText == label,
);

/// Меню dropdown — фиксированные pump (конвенция D-136: материал-меню
/// с периодическими кадрами не оседает в pumpAndSettle).
Future<void> _pick(WidgetTester tester, Finder dropdown, String option) async {
  await tester.tap(dropdown);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(find.text(option).last);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

/// Opt-in настроек: разрешение (D-88.1) — выдано без платформенного канала.
class _GrantedPermission implements RemindersPermission {
  @override
  Future<bool> request() async => true;
}

/// Пersistence opt-in и дедупа в памяти (шов D-83, образец
/// reminders_over_budget_test): по умолчанию выключено — как у пользователя.
class _SpyPrefs implements RemindersPreferencesFake {
  bool enabled = false;
  Map<String, String> lastShown = <String, String>{};

  @override
  Future<bool> readEnabled() async => enabled;

  @override
  Future<void> writeEnabled(bool value) async => enabled = value;

  @override
  Future<Map<String, String>> readAlertLastShown() async =>
      Map<String, String>.of(lastShown);

  @override
  Future<void> writeAlertLastShown(Map<String, String> values) async =>
      lastShown = Map<String, String>.of(values);
}

/// Шпигон платформенного канала уведомлений (шов RemindersPlugin D-83):
/// канал доступен (null = успех), показы копятся для_assertions ниже.
class _SpyPlugin implements RemindersPlugin {
  /// Показанные уведомления: «payload|body».
  final List<String> shown = <String>[];

  @override
  Future<RemindersChannelError?> initialize() async => null;

  @override
  Future<RemindersChannelError?> replaceAll(
    List<ReminderScheduleEntry> entries,
  ) async => null;

  @override
  Future<RemindersChannelError?> show(
    int notificationId, {
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add('$payload|$body');
    return null;
  }
}

void main() {
  testWidgets('DoD M7: план-факт и автобюджет, прогноз, opt-in напоминаний, '
      'отложенный перевод с комиссией, исполнение при запуске и '
      'оповещение о перерасходе', (WidgetTester tester) async {
    // Тексты оповещений — RU, как у живого binding'а (D-130 §2):
    // шов берёт l10n на момент показа, здесь — заранее загруженный RU.
    final AppLocalizations ru = await AppLocalizations.delegate.load(
      const Locale('ru'),
    );
    final _SpyPrefs prefs = _SpyPrefs();
    final _SpyPlugin plugin = _SpyPlugin();

    final AppHarness app = await pumpDialogApp(
      tester,
      size: const Size(600, 1000),
      tempDirPrefix: 'kopilka_dod_m7_planning',
      overrides: <Override>[
        remindersPermissionProvider.overrideWithValue(_GrantedPermission()),
        remindersServiceProvider.overrideWithValue(
          RemindersService(
            prefs: prefs,
            plugin: plugin,
            title: () => ru.reminderTitle,
            overBudgetBody:
                ({
                  required String categoryName,
                  required int remainingMinor,
                  required int daysLeft,
                }) => overBudgetBodyFor(
                  ru,
                  categoryName: categoryName,
                  remainingMinor: remainingMinor,
                  daysLeft: daysLeft,
                  symbol: '₽',
                ),
          ),
        ),
      ],
    );
    final AppLocalizations l10n = app.l10n;

    // ---------- Seed-отступления (DAO): ввод закрыт замками форм.
    final Account rub = await app.db.accountsDao.create(
      name: 'Рубли',
      kind: AccountKind.card,
      currencyCode: 'RUB',
    );
    await app.db.accountsDao.create(
      name: 'Копилка',
      kind: AccountKind.bank,
      currencyCode: 'RUB',
    );
    await app.db.categoriesDao.create(
      name: 'Комиссии',
      kind: CategoryKind.expense,
    );
    final Category salary = (await app.db.categoriesDao.getAlive(
      kind: CategoryKind.income,
    )).singleWhere((Category category) => category.name == 'Зарплата');
    // Единственный доход закрытого месяца — база среднего автобюджета.
    final DateTime nowLocal = DateTime.now();
    await app.db.transactionsDao.create(
      type: TransactionType.income,
      accountId: rub.id,
      categoryId: salary.id,
      amountMinor: 300000,
      date: DateTime.utc(nowLocal.year, nowLocal.month - 1, 15),
    );

    // ---------- 1. Пустой раздел → план через форму (D-127 §3).
    await _nav(tester, l10n.navPlanning);
    await _settleUntil(tester, find.text(l10n.planningEmpty));
    expect(find.text(l10n.planningEmptyCta), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.planningAddTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.planningAddTitle), findsOneWidget);
    expect(find.text(l10n.planningKindHint), findsOneWidget);

    await _pick(tester, _dropdown(l10n.categoryLabel), 'Продукты');
    await tester.enterText(find.byType(TextFormField).first, '500');
    await tester.tap(find.text(l10n.saveAction));
    await _settleUntil(
      tester,
      find.text(l10n.planningPlanLine(_money(app, 50000))),
    );
    expect(find.text(l10n.planningFactLine(_money(app, 0))), findsOneWidget);
    expect(
      find.text(l10n.planningRemainingLine(_money(app, 50000))),
      findsOneWidget,
    );
    expect(find.text(l10n.planningActiveBadge), findsOneWidget);

    // ---------- 2. Факт живым потоком: расход через форму быстрого ввода.
    await _nav(tester, l10n.navTransactions);
    await tester.tap(find.text(l10n.filterExpenses));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await _pick(tester, _dropdown(l10n.accountLabel), 'Рубли');
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.amountLabel),
      '150',
    );
    await _pick(tester, _dropdown(l10n.categoryLabel), 'Продукты');
    await tester.tap(find.widgetWithText(FilledButton, l10n.saveAction));
    await _settleUntil(tester, find.text(l10n.doneAction));
    await tester.tap(find.widgetWithText(FilledButton, l10n.doneAction));
    await tester.pumpAndSettle();

    await _nav(tester, l10n.navPlanning);
    await _settleUntil(
      tester,
      find.text(l10n.planningFactLine(_money(app, 15000))),
    );
    expect(
      find.text(l10n.planningRemainingLine(_money(app, 35000))),
      findsOneWidget,
    );

    // ---------- 3. Автобюджет по среднему доходу (D-54.17/D-121).
    await tester.tap(find.byTooltip(l10n.planningAutoTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.planningAutoTitle), findsOneWidget);
    expect(
      find.text(l10n.planningAutoAverage(_money(app, 300000), 1)),
      findsOneWidget,
    );
    // Префилл «средний × 6 мес» — канонический разделитель запятая
    // (S2, D-137).
    expect(find.text('18000,00'), findsOneWidget);

    await _pick(
      tester,
      _dropdown(l10n.categoryLabel),
      '${l10n.kindIncome} · Зарплата',
    );
    await tester.tap(find.text(l10n.planningAutoCreateAction));
    await _settleUntil(tester, find.text(l10n.planningAutoCreatedSnack));
    expect(find.text(l10n.planningSectionIncome), findsOneWidget);
    expect(
      find.text(l10n.planningPlanLine(_money(app, 1800000))),
      findsOneWidget,
    );

    // ---------- 4. Прогноз баланса на «Отчётах» (спека D-130 §1).
    await _nav(tester, l10n.navReports);
    await _settleUntil(tester, find.text(l10n.forecastCardTitle));
    expect(find.text(l10n.forecastNoData), findsNothing);

    // ---------- 5. Opt-in напоминаний: баннер раздела «Долги» (D-89 §7;
    // тот же контроллер, что тумблером в настройках — D-88.1).
    await _nav(tester, l10n.navDebts);
    await _settleUntil(tester, find.text(l10n.remindersBannerTitle));
    await tester.tap(find.text(l10n.remindersEnableAction));
    // Цепочка «разрешение → setEnabled → пересчёт → снек»
    // (debts_reminders) — ждём снек, чередуя реальное время и часы
    // зоны (_settleUntil); баннер гаснет сразу после включения.
    await _settleUntil(tester, find.text(l10n.remindersEnabledSnackbar));
    expect(find.text(l10n.remindersBannerTitle), findsNothing);
    expect(prefs.enabled, isTrue);
    // Снек гаснет по таймеру зоны (4 с); сам pumpAndSettle часы не
    // двигает — гасим явно, иначе он висит поверх FAB и тап по нему
    // не попадает в кнопку (предупреждение hit-test, форма не открывается).
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.byType(SnackBar), findsNothing);

    // ---------- 6. Перерасход плана (события DAO) → строка списка.
    final DateTime todayUtc = _todayUtc();
    final Category cafe = (await app.db.categoriesDao.getAlive(
      kind: CategoryKind.expense,
    )).singleWhere((Category category) => category.name == 'Кафе и рестораны');
    // Период плана — DAO: датапикер в fake_async требует шва (D-97);
    // хвост +30 дней гарантирует «≥ 1 дня до конца» в условии D-118
    // независимо от дня месяца (класс флейка D-100).
    await app.db.plansDao.create(
      categoryId: cafe.id,
      periodStart: todayUtc.subtract(const Duration(days: 1)),
      periodEnd: todayUtc.add(const Duration(days: 30)),
      amountMinor: 100000,
    );
    await app.db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: rub.id,
      categoryId: cafe.id,
      amountMinor: 110000,
      date: todayUtc,
    );
    await _nav(tester, l10n.navPlanning);
    await _settleUntil(
      tester,
      find.text(l10n.planningFactLine(_money(app, 110000))),
    );
    expect(
      find.text(l10n.planningOverByLine(_money(app, 10000))),
      findsOneWidget,
    );

    // ---------- 7. Отложенный перевод с комиссией через форму (D-130 §3).
    await _nav(tester, l10n.navTransactions);
    await tester.tap(find.text(l10n.filterTransfers));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await _pick(tester, _dropdown(l10n.accountFrom), 'Рубли');
    await _pick(tester, _dropdown(l10n.accountTo), 'Копилка');
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.amountLabel),
      '100',
    );
    await tester.tap(find.text(l10n.transferDeferLabel));
    await tester.pumpAndSettle();
    // Дата исполнения по умолчанию — сегодня UTC (шов formClock);
    // заметка и обычная дата скрыты — секция исполнения открыта.
    expect(
      find.textContaining('${l10n.transferExecuteDateLabel}:'),
      findsOneWidget,
    );
    expect(find.text(l10n.transferDeferredFixNote), findsOneWidget);

    await tester.tap(find.text(l10n.transferCommissionToggle));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, l10n.transferCommissionAmountLabel),
      '50',
    );
    await _pick(
      tester,
      _dropdown(l10n.transferCommissionCategoryLabel),
      'Комиссии',
    );
    final int txBefore = (await app.db.transactionsDao.getFiltered()).length;
    await tester.tap(find.widgetWithText(FilledButton, l10n.saveAction));
    await _settleUntil(tester, find.text(l10n.transferDeferredSnack));
    expect(find.byType(AlertDialog), findsNothing);
    // Отложено ≠ исполнено: операций не прибавилось (D-119 — при
    // запуске), в истории прежние строки.
    expect((await app.db.transactionsDao.getFiltered()).length, txBefore);

    await _nav(tester, l10n.navPlanning);
    await _settleUntil(tester, find.text(l10n.planningTransfersPendingSection));
    expect(find.text(l10n.planningTransfersExecutedSection), findsNothing);
    expect(find.text(transferLine('Рубли', 'Копилка')), findsOneWidget);
    expect(
      find.text(l10n.transferCommissionLine(_money(app, 5000))),
      findsOneWidget,
    );

    // ---------- 8. «Запуск»: автозапуск биндингов (эмуляция main,
    // прецедент D-51.в — как syncOnLaunch в DoD M4: вызов как в main,
    // fire-and-forget).
    //
    // Грабли зависания: окно runAsync не ждёт start(). После commit
    // исполнения потоки, на которые подписаны живые экраны, перезапрашивают
    // данные в фейковой зоне, а её очередь драйвер сбрасывает только ПОСЛЕ
    // окна — цепочка, ждущая фейковое продолжение внутри окна, виснет
    // (drift линкует ожидающих на future создателя — комментарий в
    // synchronized.dart дрифта). Реальная часть (запросы, транзакция,
    // показ) укладывается в окно; хвост сбрасывается драйвером после окна
    // и кадрами ниже.
    await tester.runAsync(() async {
      unawaited(app.container.read(remindersBindingProvider).start());
      unawaited(app.container.read(scheduledTransfersBindingProvider).start());
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await _settle(tester);

    // Исполненный перевод перешёл в подсекцию «Исполнены» (D-119).
    await _settleUntil(
      tester,
      find.text(l10n.planningTransfersExecutedSection),
    );
    expect(find.text(l10n.planningTransfersPendingSection), findsNothing);
    expect(find.text(transferLine('Рубли', 'Копилка')), findsOneWidget);
    expect(
      find.text(l10n.transferCommissionLine(_money(app, 5000))),
      findsOneWidget,
    );

    // В БД: перевод + расход комиссии, дата операции = execute_at (D-119).
    final List<Transaction> rows = await app.db
        .select(app.db.transactions)
        .get();
    final Transaction transferRow = rows.singleWhere(
      (Transaction row) =>
          TransactionType.fromDb(row.type) == TransactionType.transfer,
    );
    expect(transferRow.amountMinor, 10000);
    expect(transferRow.date.toUtc(), todayUtc);
    expect(
      rows.where(
        (Transaction row) =>
            TransactionType.fromDb(row.type) == TransactionType.expense &&
            row.amountMinor == 5000,
      ),
      hasLength(1),
    );

    // Оповещения через шов D-83: перерасход (план 1100/1000 ≥ 80%,
    // D-118) и уведомление об исполнении (D-119) — по одному показу
    // (дедуп раз в сутки — D-118; защёлка — D-138). Показы — хвост
    // асинхронной цепочки после commit — ждём в ритме settle.
    await _settleWhile(tester, () => plugin.shown.length < 2);
    final List<String> overBudget = plugin.shown
        .where((String entry) => entry.startsWith('plan:'))
        .toList();
    expect(overBudget, hasLength(1));
    expect(overBudget.single, contains('Кафе и рестораны'));
    expect(overBudget.single, contains('лимит превышен'));

    final List<String> executed = plugin.shown
        .where((String entry) => entry.startsWith('scheduled:'))
        .toList();
    expect(executed, hasLength(1));
    // Тело — l10n устройства (шов binding'а):(locale не фиксируем)
    // сумма и имя счёта — данные, а не тексты локали.
    expect(executed.single, contains('100'));
    expect(executed.single, contains('Копилка'));
  });
}
