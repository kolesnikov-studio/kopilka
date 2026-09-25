import 'package:kopilka/core/errors.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Локализованный текст для машиночитаемого вида отказа слоя данных.
///
/// Тексты DAO (для логов) в UI не показываются: интерфейс объясняет отказ
/// по [DataFailure], поэтому RU/EN покрываются одинаково.
String localizedError(AppLocalizations l10n, DataFailure failure) {
  switch (failure) {
    case DataFailure.invalidInput:
      return l10n.errorInvalidInput;
    case DataFailure.notFound:
      return l10n.errorNotFound;
    case DataFailure.currencyUsedByAccounts:
      return l10n.errorCurrencyUsedByAccounts;
    case DataFailure.accountHasTransactions:
      return l10n.errorAccountHasTransactions;
    case DataFailure.categoryIsSystem:
      return l10n.errorCategoryIsSystem;
    case DataFailure.categoryHasChildren:
      return l10n.errorCategoryHasChildren;
    case DataFailure.categoryHasTransactions:
      return l10n.errorCategoryHasTransactions;
    case DataFailure.categoryCycle:
      return l10n.errorCategoryCycle;
    case DataFailure.parentInvalid:
      return l10n.errorParentInvalid;
    case DataFailure.unknown:
      return l10n.errorUnknown;
  }
}
