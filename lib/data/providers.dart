import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';

/// Единственная БД приложения. Открывается лениво, при первом обращении.
///
/// Подменяется в тестах через [ProviderScope.overrides]; в живом приложении
/// файл `kopilka.sqlite` открывается один раз на процесс.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final AppDatabase db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Доступ к данным только через DAO (§2): UI обращается к ним не напрямую,
/// а через контроллеры фич.
final currenciesDaoProvider = Provider<CurrenciesDao>(
  (ref) => ref.watch(appDatabaseProvider).currenciesDao,
);

final accountsDaoProvider = Provider<AccountsDao>(
  (ref) => ref.watch(appDatabaseProvider).accountsDao,
);

final categoriesDaoProvider = Provider<CategoriesDao>(
  (ref) => ref.watch(appDatabaseProvider).categoriesDao,
);

final transactionsDaoProvider = Provider<TransactionsDao>(
  (ref) => ref.watch(appDatabaseProvider).transactionsDao,
);
