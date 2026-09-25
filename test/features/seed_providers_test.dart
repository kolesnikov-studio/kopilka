// Провайдеры данных: БД подменяется через overrideWithValue — так приложение
// получает один AppDatabase, а тесты — in-memory.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';

void main() {
  test('DAO-провайдеры берут DAO из переопределённой БД', () async {
    final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDefaultsIfEmpty(db);

    final ProviderContainer container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    expect(container.read(appDatabaseProvider), same(db));
    expect(
      container.read(currenciesDaoProvider),
      same(db.currenciesDao),
    );
    expect(container.read(accountsDaoProvider), same(db.accountsDao));
    expect(container.read(categoriesDaoProvider), same(db.categoriesDao));
    expect(
      container.read(transactionsDaoProvider),
      same(db.transactionsDao),
    );

    final List<Currency> currencies =
        await container.read(currenciesDaoProvider).getAlive();
    expect(currencies.single.code, baseCurrencyCode);
    expect(
      (await db.categoriesDao.getAlive(kind: CategoryKind.income)),
      isNotEmpty,
    );
  });
}
