import 'package:kopilka/core/errors.dart';

// Перечисления значений, которые §3 хранит в TEXT-колонках. В БД попадают
// канонические строки (`cash`, `expense`, `transfer`, ...), а не имена Dart
// в кавычках: схема остаётся читаемой в любом экспорте и при слиянии файлов.

/// Вид счёта: `accounts.kind`.
enum AccountKind {
  cash,
  bank,
  card,
  other;

  /// Значение для колонки в БД.
  String get dbValue => switch (this) {
    AccountKind.cash => 'cash',
    AccountKind.bank => 'bank',
    AccountKind.card => 'card',
    AccountKind.other => 'other',
  };

  static AccountKind fromDb(String value) => switch (value) {
    'cash' => AccountKind.cash,
    'bank' => AccountKind.bank,
    'card' => AccountKind.card,
    'other' => AccountKind.other,
    _ => throw DataValidationException('неизвестный вид счёта: «$value»'),
  };
}

/// Вид категории: `categories.kind`.
enum CategoryKind {
  income,
  expense;

  /// Значение для колонки в БД.
  String get dbValue => switch (this) {
    CategoryKind.income => 'income',
    CategoryKind.expense => 'expense',
  };

  static CategoryKind fromDb(String value) => switch (value) {
    'income' => CategoryKind.income,
    'expense' => CategoryKind.expense,
    _ => throw DataValidationException('неизвестный вид категории: «$value»'),
  };
}

/// Тип операции: `transactions.type`.
enum TransactionType {
  income,
  expense,
  transfer;

  /// Значение для колонки в БД.
  String get dbValue => switch (this) {
    TransactionType.income => 'income',
    TransactionType.expense => 'expense',
    TransactionType.transfer => 'transfer',
  };

  static TransactionType fromDb(String value) => switch (value) {
    'income' => TransactionType.income,
    'expense' => TransactionType.expense,
    'transfer' => TransactionType.transfer,
    _ => throw DataValidationException('неизвестный тип операции: «$value»'),
  };
}
