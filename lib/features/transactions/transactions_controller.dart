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

  /// Полный сброс фильтров (D-68.б): CTA пустого отфильтрованного результата
  /// снимает тип, счёт и поиск — иначе при фильтре «только поиск» кнопка
  /// ничего бы не меняла. Строка поиска видима и восстановима, честный жест
  /// один — «показать всё».
  void clearAll() => state = const TransactionsFilterState();
}

/// Строки списка операций с именами счетов и категории (R7): имена приходят
/// JOIN'ом из DAO, плиткам не нужны подписки на списки счетов/категорий.
final filteredTransactionViewsProvider =
    StreamProvider<List<TransactionView>>((ref) {
  final TransactionsFilterState state = ref.watch(transactionsFilterProvider);
  return ref.watch(transactionsDaoProvider).watchFilteredView(state.toFilter());
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

  /// Создаёт перевод. Отказы правил D-17 (счёт списания = зачисления;
  /// у мультивалютного перевода нет второй суммы) приходят из DAO как
  /// [DataFailure.invalidInput] и объясняются пользователю снеком.
  ///
  /// `targetAmountMinor` — сумма зачисления (M3-шаг 4, B4.1): обязательна
  /// при разных валютах счетов, у одно-валютного не передаётся (DAO
  /// контролирует корректность, D-17).
  Future<Result<Transaction>> createTransfer({
    required String accountId,
    required String targetAccountId,
    required int amountMinor,
    int? targetAmountMinor,
    String? note,
    DateTime? date,
  }) async {
    try {
      final Transaction transaction = await _transactions.create(
        type: TransactionType.transfer,
        accountId: accountId,
        targetAccountId: targetAccountId,
        amountMinor: amountMinor,
        targetAmountMinor: targetAmountMinor,
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
