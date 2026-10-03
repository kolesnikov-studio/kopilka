import 'package:drift/drift.dart';
import 'package:kopilka/core/currency.dart';

/// Построчная конвертация строки агрегата в минорные единицы базовой
/// валюты (D-18/D-22): строка SELECT с JOIN операций и курсов несёт сумму
/// в минорных единицах своей валюты, текущий курс к базовой и код валюты;
/// округление — half-up по модулю без double-арифметики на хранении (§3).
///
/// Общий хелпер BudgetsDao (watchProgress/progressOf) и PlansDao
/// (watchPlanVsFact) — P2 открывающего прохода M7 (D-124): механика
/// клонировалась при появлении планов. Имена полей параметризованы:
/// бюджеты читают `amount_minor`, планы — `tx_amount_minor`; курс и код
/// валюты у обоих запросов называются одинаково.
int baseMinorFromRow(
  QueryRow row, {
  required String amountField,
  String rateField = 'rate',
  String currencyField = 'currency_code',
}) => convertMinor(
  row.read<int>(amountField),
  row.read<double>(rateField),
  exponent: currencyExponentByCode(row.read<String>(currencyField)),
);
