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

/// Расходы по категориям за выбранный месяц в базовой валюте (M3-шаг 5,
/// D-18): живой поток DAO, построчная конвертация по текущему курсу —
/// смена курса пересчитывает отчёт без перезапуска.
final expensesByCategoryProvider =
    StreamProvider.autoDispose<List<CategoryExpenseBase>>((ref) {
  final DateTime moment = ref.watch(reportsMonthProvider);
  return ref
      .watch(transactionsDaoProvider)
      .watchExpensesByCategoryForMonthInBase(moment: moment);
});

/// Динамика доходов и расходов за [reportsMonthWindow] месяцев до конца
/// выбранного включительно в базовой валюте (D-18); месяцы без операций
/// заполняются нулями.
final monthTotalsProvider =
    StreamProvider.autoDispose<List<MonthTotalsBase>>((ref) {
  final DateTime moment = ref.watch(reportsMonthProvider);
  final DateTime to = nextMonthStart(moment);
  final DateTime from = DateTime.utc(to.year, to.month - reportsMonthWindow);
  return ref.watch(transactionsDaoProvider).watchTotalsByMonthInBase(
        from: from,
        to: to,
      );
});

/// Снимок курсов «код → курс к базовой» из живого справочника валют:
/// источник конвертации общего баланса (D-18). Курс базовой — по
/// определению 1 (D-16); поток пересчитывает карту при любом изменении
/// справочника, кэша нет (D-18).
final ratesSnapshotProvider = StreamProvider.autoDispose<Map<String, double>>(
  (ref) => ref.watch(currenciesDaoProvider).watchAlive().map(
        (List<Currency> currencies) => <String, double>{
          for (final Currency c in currencies) c.code: c.isBase ? 1.0 : c.rateToBase,
        },
      ),
);

/// Суммарный баланс живых счетов в базовой валюте (M3-шаг 5, D-18):
/// балансы счетов (в валютах счетов) конвертируются текущим курсом
/// справочника. Балансы самих счетов (список) остаются в валюте счёта —
/// конвертируется только общий итог дашборда (D-18).
///
/// Счета с флагом «не учитывать в балансе» (v5, M5/D-54) выпадают из
/// суммы: накопительный счёт не раздувает общий итог. Исключение —
/// только про этот агрегат: персональные балансы счетов считаются
/// как раньше (`_balanceExpression` DAO не тронут).
///
/// Пересчёт — чистая карта потока балансов с актуальным снимком курсов:
/// изменение балансов даёт новую выдачу из потока drift, изменение курса
/// пересобирает провайдер (watch [ratesSnapshotProvider]) с новой картой —
/// без кэша и без перезапуска (D-18). Переводы внутри не влияют:
/// списание и зачисление гасятся. Переключение флага счёта тоже даёт
/// новую выдачу: строка счёта изменилась в потоке `watchBalances`.
final totalBalanceProvider = StreamProvider.autoDispose<int>((ref) {
  final Map<String, double> rates =
      ref.watch(ratesSnapshotProvider).value ?? const <String, double>{};
  return ref.watch(accountsDaoProvider).watchBalances().map(
        (List<AccountBalance> balances) => balances
            .where((AccountBalance row) => row.account.excludeFromBalance != true)
            .fold<int>(
              0,
              (int sum, AccountBalance row) =>
                  sum + convertBalanceToBase(row, rates),
            ),
      );
});

/// Нужно ли помечать отчёты «по текущему курсу» (B5): живые счета больше
/// чем в одной валюте. Моновалютному пользователю пометка не показывается
/// (не шумим): у него «текущий курс» тождественно равен 1.
final reportsMultiCurrencyProvider = StreamProvider.autoDispose<bool>((ref) {
  return ref.watch(accountsDaoProvider).watchAlive().map(
        (List<Account> accounts) => <String>{
          for (final Account a in accounts) a.currencyCode,
        }.length > 1,
      );
});

/// Сумма одного счёта в минорных единицах базовой валюты (D-18): баланс
/// счёта умножается на текущий курс (half-up по модулю, знак отдельно —
/// D-22), экспонент валюты-источника — из справочника core по коду
/// (D-27). Код без строки справочника (несогласованный импорт) попадает
/// в сумму без конвертации — счёт остаётся видимым в итоге.
int convertBalanceToBase(AccountBalance balance, Map<String, double> rates) {
  final int amountMinor = balance.balanceMinor;
  final double? rateToBase = rates[balance.account.currencyCode];
  if (rateToBase == null || amountMinor == 0 || rateToBase == 1.0) {
    return amountMinor;
  }
  final bool negative = amountMinor < 0;
  final int magnitude = negative ? -amountMinor : amountMinor;
  final int converted = (magnitude * rateToBase).round();
  return negative ? -converted : converted;
}

/// Заголовок месяца («сентябрь 2026 г.») для подписи выбранного периода.
String reportsMonthLabel(DateTime moment, String locale) =>
    DateFormat.yMMMM(locale).format(moment.toUtc());

/// Короткая подпись месяца для оси динамики («сент.»).
String reportsMonthShortLabel(DateTime moment, String locale) =>
    DateFormat.MMM(locale).format(moment.toUtc());
