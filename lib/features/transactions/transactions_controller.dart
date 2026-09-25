import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';

/// Параметры фильтра списка операций (отображается на [TransactionFilter]).
class TransactionsFilterState {
  const TransactionsFilterState({
    this.type,
    this.accountId,
    this.search = '',
  });

  final TransactionType? type;
  final String? accountId;
  final String search;

  /// Период не фильтруем (M1: все операции); при необходимости добавится.
  TransactionFilter toFilter() => TransactionFilter(
        type: type,
        accountId: accountId,
        search: search,
      );

  TransactionsFilterState copyWith({
    TransactionType? type,
    String? accountId,
    String? search,
    bool clearType = false,
    bool clearAccount = false,
  }) =>
      TransactionsFilterState(
        type: clearType ? null : (type ?? this.type),
        accountId: clearAccount ? null : (accountId ?? this.accountId),
        search: search ?? this.search,
      );
}

/// Текущий фильтр списка операций.
final transactionsFilterProvider =
    NotifierProvider<TransactionsFilterController, TransactionsFilterState>(
  TransactionsFilterController.new,
);

class TransactionsFilterController extends Notifier<TransactionsFilterState> {
  @override
  TransactionsFilterState build() => const TransactionsFilterState();

  void setType(TransactionType? type) =>
      state = state.copyWith(type: type, clearType: type == null);

  void setAccount(String? accountId) =>
      state = state.copyWith(accountId: accountId, clearAccount: accountId == null);

  void setSearch(String search) => state = TransactionsFilterState(
        type: state.type,
        accountId: state.accountId,
        search: search,
      );
}

/// Живые операции по текущему фильтру.
final filteredTransactionsProvider =
    StreamProvider<List<Transaction>>((ref) {
  final TransactionsFilterState state = ref.watch(transactionsFilterProvider);
  return ref.watch(transactionsDaoProvider).watchFiltered(state.toFilter());
});

/// Живые счета — для форм и подстановки имён в списке операций.
final accountsProvider = StreamProvider<List<Account>>((ref) {
  return ref.watch(accountsDaoProvider).watchAlive();
});

/// Контроллер формы ввода: расход/доход/перевод через DAO.
class TransactionsController extends Notifier {
  @override
  void build() {}

  TransactionsDao get _transactions => ref.read(transactionsDaoProvider);

  /// Создаёт расход или доход. Категория необязательна, сумма — минорные
  /// единицы (парсинг ввода — [parseAmountToMinor], до контроллера).
  Future<Result<Transaction>> createIncomeOrExpense({
    required TransactionType type,
    required String accountId,
    required int amountMinor,
    String? categoryId,
    String? note,
    DateTime? date,
  }) async {
    try {
      final Transaction transaction = await _transactions.create(
        type: type,
        accountId: accountId,
        categoryId: categoryId,
        amountMinor: amountMinor,
        note: note,
        date: date ?? utcNow(),
      );
      return Success<Transaction>(transaction);
    } on DataValidationException catch (error) {
      return Failure<Transaction>(error.kind);
    }
  }

  /// Создаёт перевод. Отказ «счёт списания = зачисления» приходит из DAO
  /// как [DataFailure.invalidInput] и объясняется пользователю.
  Future<Result<Transaction>> createTransfer({
    required String accountId,
    required String targetAccountId,
    required int amountMinor,
    String? note,
    DateTime? date,
  }) async {
    try {
      final Transaction transaction = await _transactions.create(
        type: TransactionType.transfer,
        accountId: accountId,
        targetAccountId: targetAccountId,
        amountMinor: amountMinor,
        note: note,
        date: date ?? utcNow(),
      );
      return Success<Transaction>(transaction);
    } on DataValidationException catch (error) {
      return Failure<Transaction>(error.kind);
    }
  }

  /// Мягко удаляет операцию — отказов по связям у неё нет.
  Future<Result<void>> deleteTransaction(String id) async {
    try {
      await _transactions.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final transactionsControllerProvider =
    NotifierProvider<TransactionsController, void>(TransactionsController.new);
