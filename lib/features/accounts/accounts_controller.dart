import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';

/// Строка списка счетов: счёт и его баланс из `AccountsDao.watchBalances()`.
///
/// Балансы не считаются и не хранятся в UI (§3): единственный источник —
/// DAO.
typedef AccountRow = AccountBalance;

/// Список счетов с балансами (DAO пересчитывает его сам).
final accountsWithBalancesProvider = StreamProvider<List<AccountRow>>((
  ref,
) {
  return ref.watch(accountsDaoProvider).watchBalances();
});

/// Живые валюты — для выбора в форме счёта.
final currenciesProvider = StreamProvider<List<Currency>>((ref) {
  return ref.watch(currenciesDaoProvider).watchAlive();
});

/// Контроллер экрана счетов: формы и удаление через DAO, без прямого SQL.
class AccountsController extends Notifier {
  @override
  void build() {}

  AccountsDao get _accounts => ref.read(accountsDaoProvider);

  /// Создаёт счёт; отказ возвращает как [Result], не бросая исключение.
  Future<Result<Account>> createAccount({
    required String name,
    required AccountKind kind,
    required String currencyCode,
    int initialBalanceMinor = 0,
  }) async {
    try {
      final Account account = await _accounts.create(
        name: name,
        kind: kind,
        currencyCode: currencyCode,
        initialBalanceMinor: initialBalanceMinor,
      );
      return Success<Account>(account);
    } on DataValidationException catch (error) {
      return Failure<Account>(error.kind);
    }
  }

  /// Меняет поля счёта (не переданные — `Value.absent()`).
  Future<Result<Account>> updateAccount(
    String id, {
    Value<String> name = const Value.absent(),
    Value<AccountKind> kind = const Value.absent(),
    Value<String> currencyCode = const Value.absent(),
    Value<int> initialBalanceMinor = const Value.absent(),
  }) async {
    try {
      final Account account = await _accounts.updateAccount(
        id,
        name: name,
        kind: kind,
        currencyCode: currencyCode,
        initialBalanceMinor: initialBalanceMinor,
      );
      return Success<Account>(account);
    } on DataValidationException catch (error) {
      return Failure<Account>(error.kind);
    }
  }

  /// Мягко удаляет счёт. Отказ «есть живые операции» UI объясняет текстом
  /// [DataFailure.accountHasTransactions].
  Future<Result<void>> deleteAccount(String id) async {
    try {
      await _accounts.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final accountsControllerProvider =
    NotifierProvider<AccountsController, void>(AccountsController.new);
