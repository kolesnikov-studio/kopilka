import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/attachments_service.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/attachments_dao.dart';
import 'package:kopilka/data/db/dao/budgets_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/export/backup_service.dart';

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

final budgetsDaoProvider = Provider<BudgetsDao>(
  (ref) => ref.watch(appDatabaseProvider).budgetsDao,
);

final attachmentsDaoProvider = Provider<AttachmentsDao>(
  (ref) => ref.watch(appDatabaseProvider).attachmentsDao,
);

/// Долги и погашения (v7, M6/D-82).
final debtsDaoProvider = Provider<DebtsDao>(
  (ref) => ref.watch(appDatabaseProvider).debtsDao,
);

/// Хранилище файлов вложений (v6, D-63): каталог `attachments/` рядом с
/// `kopilka.sqlite`. База создаётся в main и подменяется переопределением
/// провайдера — образец магазинов настроек (D-43).
final attachmentsStorageProvider = Provider<AttachmentsStorage>((ref) {
  throw UnimplementedError(
    'создаётся в main: AttachmentsStorage(rootDirectory: каталог attachments/ рядом с БД)',
  );
});

/// Сервис вложений (v6, D-63): единый метод «запись файла + запись БД».
final attachmentsServiceProvider = Provider<AttachmentsService>(
  (ref) => AttachmentsService(
    ref.watch(attachmentsStorageProvider),
    ref.watch(attachmentsDaoProvider),
  ),
);

/// Сервис бэкапа/экспорта над единственной БД (A18): один экземпляр
/// вместо нового объекта на каждый вызов метода контроллера настроек.
final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(appDatabaseProvider)),
);

/// Контекст валют (R5/A17): одна семантика «какая валюта у этой суммы»
/// для всех экранов M3.

/// Символ базовой валюты — совместимый короткий вариант для дашборда
/// (до загрузки — пустая строка; дашборд не ждёт справочник).
final baseCurrencySymbolProvider = StreamProvider.autoDispose<String>((ref) {
  return ref
      .watch(currenciesDaoProvider)
      .watchAlive()
      .map(
        (List<Currency> currencies) => baseCurrencyOf(currencies)?.symbol ?? '',
      );
});

/// Базовая валюта целиком: код, символ, курс, экспонент из справочника
/// core (D-15). Заменяет точечные поиски символа по списку.
final baseCurrencyStreamProvider = StreamProvider.autoDispose<Currency>(
  (ref) => ref
      .watch(currenciesDaoProvider)
      .watchAlive()
      .map(
        (List<Currency> currencies) =>
            baseCurrencyOf(currencies) ?? currencies.first,
      ),
);

/// Базовая валюта списка; пустой список невозможен (посев), но безопасен.
Currency? baseCurrencyOf(List<Currency> currencies) {
  for (final Currency currency in currencies) {
    if (currency.isBase) {
      return currency;
    }
  }
  return currencies.isEmpty ? null : currencies.first;
}

/// Карта «код → валюта» (R5): O(1) поиск символа/кода вместо линейного
/// прохода по списку в каждой плитке (accounts_screen._currencySymbol).
final currenciesMapProvider = StreamProvider.autoDispose<Map<String, Currency>>(
  (ref) {
    return ref
        .watch(currenciesDaoProvider)
        .watchAlive()
        .map(
          (List<Currency> currencies) => <String, Currency>{
            for (final Currency currency in currencies) currency.code: currency,
          },
        );
  },
);
