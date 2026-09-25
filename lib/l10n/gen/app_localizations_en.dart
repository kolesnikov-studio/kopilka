// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Kopilka';

  @override
  String get navAccounts => 'Accounts';

  @override
  String get navTransactions => 'Transactions';

  @override
  String get navCategories => 'Categories';

  @override
  String get navReports => 'Reports';

  @override
  String get navSettings => 'Settings';

  @override
  String get reportsPlaceholder =>
      'Reports and budgets will appear here. Stage M2.';

  @override
  String get backupSectionTitle => 'Backup and export';

  @override
  String get exportJsonAction => 'Export backup (JSON)';

  @override
  String get importJsonAction => 'Import backup (JSON)';

  @override
  String get exportCsvAction => 'Export transactions (CSV)';

  @override
  String get autoBackupTitle => 'Auto-backup on launch';

  @override
  String get autoBackupPickFolder => 'Choose folder';

  @override
  String get autoBackupDisabled => 'Folder is not selected';

  @override
  String get autoBackupRunNow => 'Run now';

  @override
  String get importReplaceWarning =>
      'All current data will be replaced with the backup content. Continue?';

  @override
  String get importConfirmTitle => 'Import backup?';

  @override
  String get importDone => 'Backup imported.';

  @override
  String get backupExported => 'File saved.';

  @override
  String get backupCancelled => 'Cancelled.';

  @override
  String get errorBackupInvalidFormat => 'This file is not a Kopilka backup.';

  @override
  String get errorBackupTooNew =>
      'This backup was made by a newer version of the app.';

  @override
  String get errorBackupTooOld =>
      'This backup version is too old and cannot be read.';

  @override
  String get errorBackupInvalidData =>
      'Backup content is damaged or incomplete.';

  @override
  String autoBackupDone(String fileName) {
    return 'Auto-backup saved: $fileName';
  }

  @override
  String autoBackupRemovedOld(int count) {
    return ' ($count old removed)';
  }

  @override
  String autoBackupFailed(String reason) {
    return 'Auto-backup failed: $reason';
  }

  @override
  String get updateSectionTitle => 'Updates';

  @override
  String get updateAutoCheck => 'Check for updates automatically';

  @override
  String get updateAutoCheckHint =>
      'Once every 7 days, no other network activity';

  @override
  String get updateCheckNow => 'Check now';

  @override
  String get updateChecking => 'Checking…';

  @override
  String get updateUpToDate => 'You have the latest version';

  @override
  String get updateUnavailable => 'Could not check for updates';

  @override
  String updateFoundTitle(String version) {
    return 'Update available: $version';
  }

  @override
  String get updateFoundOpenRelease => 'Open release page';

  @override
  String get updateFoundNoChangelog => 'No changelog provided.';

  @override
  String get updateOfferTitle => 'Check for updates automatically?';

  @override
  String get updateOfferBody =>
      'The app will contact GitHub once a week to look for new versions. Nothing else is sent or downloaded — you install updates yourself.';

  @override
  String get updateOfferEnable => 'Enable';

  @override
  String get updateOfferLater => 'Not now';

  @override
  String get updateOpenFailed => 'Could not open the release page';

  @override
  String get saveAction => 'Save';

  @override
  String get cancelAction => 'Cancel';

  @override
  String get deleteAction => 'Delete';

  @override
  String get editAction => 'Edit';

  @override
  String get nameLabel => 'Name';

  @override
  String get amountLabel => 'Amount';

  @override
  String get dateLabel => 'Date';

  @override
  String get noteLabel => 'Note';

  @override
  String get categoryLabel => 'Category';

  @override
  String get kindLabel => 'Kind';

  @override
  String get currencyLabel => 'Currency';

  @override
  String get errorInvalidInput => 'Please check the entered values.';

  @override
  String get errorNotFound =>
      'This record has already been deleted or does not exist.';

  @override
  String get errorUnknown => 'The action failed. Please try again.';

  @override
  String get errorCurrencyUsedByAccounts =>
      'This currency is used by existing accounts. Delete or move them first.';

  @override
  String get errorAccountHasTransactions =>
      'This account has transactions. Delete them first.';

  @override
  String get errorCategoryIsSystem => 'Built-in categories cannot be deleted.';

  @override
  String get errorCategoryHasChildren =>
      'This category has subcategories. Delete or move them first.';

  @override
  String get errorCategoryHasTransactions =>
      'This category is used by transactions. Delete them first.';

  @override
  String get errorCategoryCycle =>
      'This move would create a cycle in the category tree.';

  @override
  String get errorParentInvalid =>
      'The parent category is unavailable or has a different kind.';

  @override
  String get errorBudgetCategoryInvalid =>
      'A budget can only be set on an expense category.';

  @override
  String get errorBudgetAlreadyExists => 'This category already has a budget.';

  @override
  String get errorCategoryHasBudget =>
      'This category has a budget. Delete the budget first.';

  @override
  String get errorTransferSameAccount =>
      'The source and target accounts must be different.';

  @override
  String get amountInvalid => 'Enter an amount greater than zero.';

  @override
  String get selectCurrencyValidator => 'Select a currency.';

  @override
  String get accountsEmpty => 'No accounts yet. Add your first account.';

  @override
  String get accountAdd => 'Add account';

  @override
  String get accountEdit => 'Edit account';

  @override
  String get accountKindCash => 'Cash';

  @override
  String get accountKindBank => 'Bank account';

  @override
  String get accountKindCard => 'Card';

  @override
  String get accountKindOther => 'Other';

  @override
  String get accountInitialBalance => 'Initial balance';

  @override
  String get accountDeleteTitle => 'Delete account?';

  @override
  String accountDeleteBody(String name) {
    return 'The account “$name” will be hidden from the lists.';
  }

  @override
  String get categoriesTitle => 'Categories';

  @override
  String get categoriesEmpty => 'No categories yet.';

  @override
  String get categoryAdd => 'Add category';

  @override
  String get categoryEdit => 'Edit category';

  @override
  String get kindIncome => 'Income';

  @override
  String get kindExpense => 'Expense';

  @override
  String get categoryParent => 'Parent category';

  @override
  String get categoryParentNone => 'No parent (top level)';

  @override
  String get systemBadge => 'built-in';

  @override
  String get categoryDeleteTitle => 'Delete category?';

  @override
  String categoryDeleteBody(String name) {
    return 'The category “$name” will be hidden from the lists.';
  }

  @override
  String get transactionsEmpty => 'No transactions yet. Add the first one.';

  @override
  String get transactionsEmptyFiltered =>
      'Nothing matches the selected filters.';

  @override
  String get searchHint => 'Search in notes';

  @override
  String get filterAll => 'All';

  @override
  String get filterIncomes => 'Incomes';

  @override
  String get filterExpenses => 'Expenses';

  @override
  String get filterTransfers => 'Transfers';

  @override
  String get filterAllAccounts => 'All accounts';

  @override
  String get expenseAction => 'Expense';

  @override
  String get incomeAction => 'Income';

  @override
  String get transferAction => 'Transfer';

  @override
  String get newExpenseTitle => 'New expense';

  @override
  String get newIncomeTitle => 'New income';

  @override
  String get newTransferTitle => 'New transfer';

  @override
  String get accountFrom => 'From account';

  @override
  String get accountTo => 'To account';

  @override
  String get transactionDeleteTitle => 'Delete transaction?';

  @override
  String get transactionDeleteBody =>
      'The transaction will be hidden from the lists.';
}
