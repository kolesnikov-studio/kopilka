// Тест провайдера прогноза (M7-шаг B, D-117): in-memory БД + ProviderContainer
// — баланс дашборда, история нового агрегата D-116 и планы D-116 собираются
// в точки 1/3/6/9/12; проверяются знаки планов по виду категории и
// пересчёт после новых операций (линза без хранения).
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/forecast.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/forecast/forecast_providers.dart';

/// Ждёт, пока [condition] не станет истинной (bounded): drift-потоки и
/// Riverpod асинхронны — чтение .future сразу после записи не гарантирует
/// выдачу нового значения (гонка; образец feature_controllers_test).
Future<void> waitUntil(bool Function() condition) async {
  for (int i = 0; i < 200; i++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('условие не выполнилось за отведённое время');
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seedDefaultsIfEmpty(db);
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
  });

  /// Читает прогноз, удерживая autoDispose-провайдер живым до эмиссии:
  /// без подписки контейнер dispose'ит цепочку прямо в состоянии загрузки.
  Future<List<ForecastPoint>> readForecast() async {
    final ProviderSubscription<Future<List<ForecastPoint>>> subscription =
        container.listen(forecastProvider.future, (_, _) {});
    try {
      return await container.read(forecastProvider.future);
    } finally {
      subscription.close();
    }
  }

  test('прогноз: баланс + история + план на следующий месяц; окна 1/3/6/9/12',
      () async {
    final DateTime now = utcNow();
    // История — всегда в прошлом полном месяце, независимо от даты прогона.
    final DateTime lastMonth = DateTime.utc(now.year, now.month - 1, 5, 12);
    final DateTime nextMonth = DateTime.utc(now.year, now.month + 1);
    final DateTime monthAfterNext = DateTime.utc(now.year, now.month + 2);

    final Account account = await db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: 'RUB',
      initialBalanceMinor: 100000,
    );
    final Category food = await db.categoriesDao.create(
      name: 'Тест-еда',
      kind: CategoryKind.expense,
    );
    await db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: food.id,
      amountMinor: 300,
      date: lastMonth,
    );
    await db.plansDao.create(
      categoryId: food.id,
      periodStart: nextMonth,
      periodEnd: monthAfterNext,
      amountMinor: 500,
    );

    final List<ForecastPoint> points = await readForecast();

    // Баланс = 100000 − 300 = 99700; история — один месяц (среднее −300);
    // следующий месяц — план (−500), далее среднее (−300).
    expect(
      points.map((ForecastPoint p) => p.month).toList(),
      <DateTime>[
        DateTime.utc(now.year, now.month + 1),
        DateTime.utc(now.year, now.month + 3),
        DateTime.utc(now.year, now.month + 6),
        DateTime.utc(now.year, now.month + 9),
        DateTime.utc(now.year, now.month + 12),
      ],
    );
    expect(
      points.map((ForecastPoint p) => p.balanceMinor).toList(),
      <int>[99200, 98600, 97700, 96800, 95900],
    );
  });

  test('новые операции пересчитывают прогноз (линза без хранения)', () async {
    final DateTime now = utcNow();
    final DateTime lastMonth = DateTime.utc(now.year, now.month - 1, 5, 12);
    final Account account = await db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: 'RUB',
      initialBalanceMinor: 100000,
    );
    final Category food = await db.categoriesDao.create(
      name: 'Тест-еда',
      kind: CategoryKind.expense,
    );
    await db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: food.id,
      amountMinor: 300,
      date: lastMonth,
    );

    // Слушатель держит autoDispose-провайдер живым и ловит новые выдачи.
    final List<Future<List<ForecastPoint>>> futures =
        <Future<List<ForecastPoint>>>[];
    final ProviderSubscription<Future<List<ForecastPoint>>> subscription =
        container.listen(
          forecastProvider.future,
          (_, Future<List<ForecastPoint>> next) => futures.add(next),
        );
    addTearDown(subscription.close);

    final List<ForecastPoint> first = await container.read(
      forecastProvider.future,
    );
    expect(first.last.balanceMinor, 100000 - 300 - 12 * 300);

    final int before = futures.length;
    await db.transactionsDao.create(
      type: TransactionType.expense,
      accountId: account.id,
      categoryId: food.id,
      amountMinor: 600,
      date: lastMonth,
    );

    // Пересчёт приходит новой выдачей — без перезапуска и без кэша.
    await waitUntil(
      () => futures.length > before,
    );
    final List<ForecastPoint> second = await futures.last;
    // Среднее стало −900, баланс — 99100.
    expect(second.last.balanceMinor, 99100 - 12 * 900);
  });

  test('планы доходной и расходной категорий идут с разными знаками', () async {
    final DateTime now = utcNow();
    final DateTime nextMonth = DateTime.utc(now.year, now.month + 1);
    final DateTime monthAfterNext = DateTime.utc(now.year, now.month + 2);
    await db.accountsDao.create(
      name: 'Наличные',
      kind: AccountKind.cash,
      currencyCode: 'RUB',
    );
    final Category salary = await db.categoriesDao.create(
      name: 'Тест-зарплата',
      kind: CategoryKind.income,
    );
    final Category food = await db.categoriesDao.create(
      name: 'Тест-еда',
      kind: CategoryKind.expense,
    );
    await db.plansDao.create(
      categoryId: salary.id,
      periodStart: nextMonth,
      periodEnd: monthAfterNext,
      amountMinor: 1000,
    );
    await db.plansDao.create(
      categoryId: food.id,
      periodStart: nextMonth,
      periodEnd: monthAfterNext,
      amountMinor: 400,
    );

    final List<ForecastPoint> points = await readForecast();

    // Следующий месяц: +1000 − 400 = +600; далее планов нет.
    expect(
      points.map((ForecastPoint p) => p.balanceMinor).toList(),
      <int>[600, 600, 600, 600, 600],
    );
  });

  test('без операций и планов линия плоская: точки равны текущему балансу',
      () async {
    await db.accountsDao.create(
      name: 'Копилка',
      kind: AccountKind.cash,
      currencyCode: 'RUB',
      initialBalanceMinor: 5000,
    );

    final List<ForecastPoint> points = await readForecast();

    expect(
      points.map((ForecastPoint p) => p.balanceMinor).toList(),
      <int>[5000, 5000, 5000, 5000, 5000],
    );
  });
}
