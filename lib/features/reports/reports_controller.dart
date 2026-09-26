import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';

/// Выбранный месяц дашборда: любой момент внутри месяца (§3, UTC).
/// По умолчанию — текущий месяц; переключение стрелками не ограничено
/// ни прошлым, ни будущим.
class ReportsMonthController extends Notifier<DateTime> {
  @override
  DateTime build() => utcNow();

  /// Сдвигает выбранный месяц на [months] (отрицательное — назад).
  void shiftMonths(int months) {
    final DateTime shifted = DateTime.utc(
      state.year,
      state.month + months,
    );
    state = monthStart(shifted);
  }
}

final reportsMonthProvider =
    NotifierProvider<ReportsMonthController, DateTime>(
  ReportsMonthController.new,
);

/// Сколько месяцев динамики показывает дашборд (выбранный — последний).
const int reportsMonthWindow = 6;

/// Расходы по категориям за выбранный месяц (живой поток DAO).
final expensesByCategoryProvider =
    StreamProvider.autoDispose<List<CategoryExpense>>((ref) {
  final DateTime moment = ref.watch(reportsMonthProvider);
  return ref
      .watch(transactionsDaoProvider)
      .watchExpensesByCategoryForMonth(moment: moment);
});

/// Динамика доходов и расходов за [reportsMonthWindow] месяцев до конца
/// выбранного включительно; месяцы без операций заполняются нулями.
final monthTotalsProvider =
    StreamProvider.autoDispose<List<MonthTotals>>((ref) {
  final DateTime moment = ref.watch(reportsMonthProvider);
  final DateTime to = nextMonthStart(moment);
  final DateTime from = DateTime.utc(to.year, to.month - reportsMonthWindow);
  return ref.watch(transactionsDaoProvider).watchTotalsByMonth(
        from: from,
        to: to,
      );
});

/// Суммарный баланс всех живых счетов (Stream.fold поверх потока DAO).
/// Переводы внутри не влияют: списание и зачисление гасятся.
final totalBalanceProvider = StreamProvider.autoDispose<int>((ref) async* {
  await for (final List<AccountBalance> balances
      in ref.watch(accountsDaoProvider).watchBalances()) {
    yield balances.fold<int>(
      0,
      (int sum, AccountBalance row) => sum + row.balanceMinor,
    );
  }
});

/// Символ базовой валюты для подписей сумм; до загрузки — пустая строка,
/// дашборд не ждёт справочник, чтобы показать цифры.
final baseCurrencySymbolProvider = StreamProvider.autoDispose<String>((ref) {
  return ref
      .watch(currenciesDaoProvider)
      .watchAlive()
      .map((List<Currency> currencies) {
    for (final Currency currency in currencies) {
      if (currency.isBase) {
        return currency.symbol;
      }
    }
    return currencies.isEmpty ? '' : currencies.first.symbol;
  });
});

/// Заголовок месяца («сентябрь 2026 г.») для подписи выбранного периода.
String reportsMonthLabel(DateTime moment, String locale) =>
    DateFormat.yMMMM(locale).format(moment.toUtc());

/// Короткая подпись месяца для оси динамики («сент.»).
String reportsMonthShortLabel(DateTime moment, String locale) =>
    DateFormat.MMM(locale).format(moment.toUtc());
