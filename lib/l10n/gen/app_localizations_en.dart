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
  String get retryAction => 'Retry';

  @override
  String get accountsEmptyCta => 'Add account';

  @override
  String get transactionsEmptyCta => 'Add transaction';

  @override
  String get addAction => 'Add';

  @override
  String get accountLabel => 'Account';

  @override
  String get selectAccountValidator => 'Select an account.';

  @override
  String get budgetMonthlyHint => 'The limit repeats every month';

  @override
  String budgetBaseCurrencyHint(String code) {
    return 'Limit in base currency ($code)';
  }

  @override
  String get navCategories => 'Categories';

  @override
  String get navReports => 'Reports';

  @override
  String get navSettings => 'Settings';

  @override
  String get reportsTotalBalance => 'Total balance';

  @override
  String get reportsCategoryBreakdownTitle => 'Expenses by category';

  @override
  String get reportsCategoryBreakdownEmpty => 'No expenses this month.';

  @override
  String get reportsMonthDynamicsTitle => 'Dynamics by month';

  @override
  String get reportsTotalLabel => 'Total';

  @override
  String get reportsAtCurrentRate => 'at current rate';

  @override
  String get budgetsTitle => 'Budgets';

  @override
  String get budgetsEmpty =>
      'No budgets yet. Set a monthly limit for a category.';

  @override
  String get budgetAdd => 'Add budget';

  @override
  String get budgetEdit => 'Edit budget';

  @override
  String get budgetDeleteTitle => 'Delete budget?';

  @override
  String budgetDeleteBody(String name) {
    return 'The budget for “$name” will be removed.';
  }

  @override
  String get backupSectionTitle => 'Backup and export';

  @override
  String get exportJsonAction => 'Export backup (JSON)';

  @override
  String get importJsonAction => 'Import backup (JSON)';

  @override
  String get exportCsvAction => 'Export transactions (CSV)';

  @override
  String get importCsvAction => 'Import transactions (CSV)';

  @override
  String get csvImportMappingTitle => 'Map CSV columns';

  @override
  String get csvMappingHint =>
      'For each file column choose what it contains. “Not used” columns are skipped.';

  @override
  String csvImportRowCount(int count) {
    return 'The file contains $count operations.';
  }

  @override
  String csvImportColumnName(int number) {
    return 'Column $number';
  }

  @override
  String get csvColumnUnused => 'Not used';

  @override
  String get csvFieldDate => 'Date';

  @override
  String get csvFieldType => 'Type';

  @override
  String get csvFieldAccount => 'Account (source)';

  @override
  String get csvFieldAmount => 'Amount';

  @override
  String get csvFieldCurrency => 'Currency';

  @override
  String get csvFieldTargetAccount => 'Account (target)';

  @override
  String get csvFieldTargetAmount => 'Amount (credited)';

  @override
  String get csvFieldCategory => 'Category';

  @override
  String get csvFieldNote => 'Note';

  @override
  String get csvMappingNextAction => 'Continue';

  @override
  String get csvMappingDuplicateField =>
      'Two columns are mapped to the same field.';

  @override
  String csvMappingMissingRequired(String fields) {
    return 'Required fields are not mapped: $fields.';
  }

  @override
  String csvMappingColumnMissing(int number) {
    return 'Column $number is mapped but the file rows are shorter.';
  }

  @override
  String get csvImportConfirmTitle => 'Import operations?';

  @override
  String get csvImportConfirmAction => 'Import';

  @override
  String csvImportMergeWarning(int count) {
    return '$count operations will be ADDED to the existing ones. Duplicates are not detected: importing the same file twice creates each operation twice.';
  }

  @override
  String csvImportDone(Object count) {
    return 'Added $count operations.';
  }

  @override
  String get errorCsvInvalidFormat => 'This file is not a valid CSV.';

  @override
  String get errorCsvNoDataRows => 'The file has no data rows.';

  @override
  String errorCsvInvalidFormatLine(int line) {
    return 'This file is not a valid CSV (line $line).';
  }

  @override
  String get errorCsvInvalidMapping =>
      'Column mapping is invalid: check for duplicates and required fields.';

  @override
  String get errorCsvInvalidData =>
      'File content does not match the accounts and categories of the database.';

  @override
  String errorCsvInvalidDataLine(int line) {
    return 'Line $line: the value does not match the accounts, categories or formats of the database. Nothing was imported.';
  }

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
  String get rateSyncSectionTitle => 'Currency rates';

  @override
  String get rateSyncEnabled => 'Update rates from the internet';

  @override
  String get rateSyncEnabledHint =>
      'Rates update at app launch and via the button below; manual entry stays available offline';

  @override
  String get rateSyncNow => 'Update now';

  @override
  String get rateSyncing => 'Updating…';

  @override
  String rateSyncUpdated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Updated $count currencies',
      one: 'Updated $count currency',
    );
    return '$_temp0';
  }

  @override
  String get rateSyncUnchanged => 'Rates are already up to date';

  @override
  String get rateSyncOffline => 'Network unavailable — keeping current rates';

  @override
  String get rateSyncDisabled => 'Rate synchronization is turned off';

  @override
  String get rateSyncFailed => 'Rate source failed — keeping current rates';

  @override
  String get rateSyncAlreadyRunning => 'An update is already running';

  @override
  String get saveAction => 'Save';

  @override
  String get cancelAction => 'Cancel';

  @override
  String get deleteAction => 'Delete';

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
  String get transferAmountInvalid => 'Enter the target amount.';

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
  String accountCurrencyRow(String symbol, String code) {
    return 'Currency: $symbol $code';
  }

  @override
  String get accountCurrencyLockedHint =>
      'Currency can be changed while the account has no transactions.';

  @override
  String get accountCurrencyChangeAction => 'Change currency';

  @override
  String get selectCurrencyValidator => 'Select a currency.';

  @override
  String get excludeFromBalanceLabel => 'Exclude from balance';

  @override
  String get excludeFromBalanceHint =>
      'The account will be removed from the total balance on the reports screen. Its own balance does not change.';

  @override
  String get accountExcludedBadge => 'Not in balance';

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
  String get categoryIconLabel => 'Icon';

  @override
  String get systemBadge => 'built-in';

  @override
  String get categoryDeleteTitle => 'Delete category?';

  @override
  String categoryDeleteBody(String name) {
    return 'The category “$name” will be hidden from the lists.';
  }

  @override
  String get categoryHideTitle => 'Hide category?';

  @override
  String get categoryHideAction => 'Hide';

  @override
  String categoryHideBody(String name) {
    return 'The built-in category “$name” will disappear from all lists. You can bring it back later in Settings → Hidden categories. Transactions and budgets will keep working.';
  }

  @override
  String categoryHiddenSnack(String name) {
    return 'Category “$name” hidden';
  }

  @override
  String get hiddenCategoriesTitle => 'Hidden categories';

  @override
  String hiddenCategoriesTileSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hidden categories',
      one: '1 hidden category',
    );
    return '$_temp0';
  }

  @override
  String get hiddenCategoriesEmpty => 'No hidden categories.';

  @override
  String get categoryRestoreAction => 'Restore';

  @override
  String categoryRestoredSnack(String name) {
    return 'Category “$name” restored';
  }

  @override
  String get transactionsEmpty => 'No transactions yet. Add the first one.';

  @override
  String get transactionsEmptyFiltered =>
      'Nothing matches the selected filters.';

  @override
  String get transactionsEmptyFilteredAction => 'Show all transactions';

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

  @override
  String get transactionTileNoCategory => 'No category';

  @override
  String get transactionTileAccountGone => 'Deleted account';

  @override
  String get currenciesScreenTitle => 'Currencies';

  @override
  String currenciesSettingsSubtitle(int count) {
    return '$count in the list';
  }

  @override
  String get currenciesBaseBadge => 'Base currency';

  @override
  String currenciesRateOf(String rate, String code) {
    return '1 = $rate $code';
  }

  @override
  String get currencyAdd => 'Add currency';

  @override
  String get currencySearchHint => 'Search by code or name';

  @override
  String get currencyAlreadyAdded => 'already added';

  @override
  String get currencyRateHint =>
      'Rate: how much base currency one unit of this currency is worth';

  @override
  String get currencyRateLabel => 'Rate to base';

  @override
  String get currencyRateInvalid =>
      'Enter a rate greater than zero (up to 6 decimal places).';

  @override
  String currencyRateDialogTitle(String code, String base) {
    return 'Rate $code → $base';
  }

  @override
  String get currencyRateRecalcNote =>
      'Reports are recalculated using the new rate.';

  @override
  String get currencyMakeBase => 'Make base';

  @override
  String currencyChangeBaseTitle(String code) {
    return 'Make $code the base currency?';
  }

  @override
  String currencyChangeBaseBody(String code) {
    return 'Account balances stay in their own currencies. Rates of the other currencies will be recalculated relative to $code. Reports and budget limits will be recalculated using the new rates.';
  }

  @override
  String get currencyChangeBaseAction => 'Make base';

  @override
  String currencyDeleteTitle(String code) {
    return 'Remove currency $code from the list?';
  }

  @override
  String get currencyDeleteBody => 'Transaction history will not change.';

  @override
  String currencyDeleteBlockedBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count accounts use this currency.',
      one: '$count account uses this currency.',
    );
    return '$_temp0 Delete or move them to another currency first.';
  }

  @override
  String get currencyDeleteMenuAction => 'Delete';

  @override
  String get transferAmountOut => 'Debited';

  @override
  String get transferAmountIn => 'Credited';

  @override
  String transferRateLine(String from, String rate, String to) {
    return 'At the rate 1 $from = $rate $to';
  }

  @override
  String get transferPrefillNote =>
      'Prefilled with the current rate — correct it if the exchange rate differed';

  @override
  String get themeSectionTitle => 'Theme';

  @override
  String get themeModeSystem => 'System';

  @override
  String get themeModeLight => 'Light';

  @override
  String get themeModeDark => 'Dark';

  @override
  String get themePresetsLabel => 'Presets';

  @override
  String get themePresetDefault => 'Default';

  @override
  String get themePresetOcean => 'Ocean';

  @override
  String get themePresetSunset => 'Sunset';

  @override
  String get themePresetAmethyst => 'Amethyst';

  @override
  String get themePresetGraphite => 'Graphite';

  @override
  String get themePresetRose => 'Rose';

  @override
  String get attachmentSectionTitle => 'Attachment';

  @override
  String get attachmentPickAction => 'Attach';

  @override
  String get attachmentPickTitle => 'Attach file';

  @override
  String get attachmentPickBody =>
      'The file will be stored with this transaction.';

  @override
  String get attachmentReplaceTitle => 'Replace file';

  @override
  String get attachmentReplaceAction => 'Replace';

  @override
  String get attachmentReplaceBody =>
      'The current attachment will be removed and replaced with the new file.';

  @override
  String get attachmentSaved => 'Attachment saved.';

  @override
  String get attachmentDeleteTitle => 'Delete attachment';

  @override
  String get attachmentDeleteBody =>
      'The attachment and its file on disk will be deleted.';

  @override
  String get attachmentOpenAction => 'View';

  @override
  String get attachmentFileMissing => 'File not found on disk.';

  @override
  String attachmentTooLarge(String maxSize) {
    return 'File is too large. Maximum size is $maxSize.';
  }

  @override
  String get attachmentPdfUnsupported =>
      'PDF preview is not available yet. The file is attached to the transaction.';

  @override
  String get attachmentMimeTypeUnsupported =>
      'This file type cannot be attached. Supported: images and PDF.';

  @override
  String get errorAttachmentStorage =>
      'The attachment could not be saved. Check free disk space and try again.';

  @override
  String get doneAction => 'Done';

  @override
  String get navDebts => 'Debts';

  @override
  String get debtsEmpty => 'No debts yet. Record who owes what.';

  @override
  String get debtsEmptyCta => 'Add debt';

  @override
  String get debtAddTooltip => 'Add debt';

  @override
  String get debtSectionTheyOweMe => 'Owed to me';

  @override
  String get debtSectionIOweThem => 'I owe';

  @override
  String debtSectionTotalTheyOweMe(String amount) {
    return 'Owed to me: $amount';
  }

  @override
  String debtSectionTotalIOweThem(String amount) {
    return 'I owe: $amount';
  }

  @override
  String debtRemainingLine(String amount) {
    return 'Remaining: $amount';
  }

  @override
  String debtPaidLine(String amount) {
    return 'Paid: $amount';
  }

  @override
  String get debtDueDateLabel => 'Due date';

  @override
  String get debtOverdueBadge => 'Overdue';

  @override
  String get debtPaidOffBadge => 'Paid off';

  @override
  String get debtDirectionTheyOweMe => 'Owed to me';

  @override
  String get debtDirectionIOweThem => 'I owe';

  @override
  String get debtPersonLabel => 'Person';

  @override
  String get debtDirectionLabel => 'Direction';

  @override
  String get debtAmountLabel => 'Principal';

  @override
  String get debtExtraLabel => 'Extra';

  @override
  String get debtExtraHelper => 'Included in the total due';

  @override
  String debtExtraLine(Object amount) {
    return 'Including extra: $amount';
  }

  @override
  String get debtCurrencyLabel => 'Currency';

  @override
  String get debtDueDateOptional => 'Due date (optional)';

  @override
  String get debtNoteLabel => 'Note';

  @override
  String get debtPersonRequired => 'Enter a name';

  @override
  String get debtAmountInvalid => 'The amount must be greater than zero';

  @override
  String get debtExtraInvalid => 'The extra amount cannot be negative';

  @override
  String get debtEditTitle => 'Edit debt';

  @override
  String get debtDeleteTitle => 'Delete debt?';

  @override
  String get debtDeleteBody =>
      'The debt will disappear from the lists. Its payments and the attachment file remain in the data.';

  @override
  String get debtAddTitle => 'New debt';

  @override
  String get debtPaymentsTitle => 'Payments';

  @override
  String get debtPaymentsEmpty => 'No payments yet.';

  @override
  String get debtRecordPaymentAction => 'Record payment';

  @override
  String get debtPaymentAmountLabel => 'Payment amount';

  @override
  String get debtPaymentDateLabel => 'Actual date';

  @override
  String get debtPaymentLinkTransfer => 'Link to a transfer';

  @override
  String get debtPaymentFormTitle => 'Record a payment';

  @override
  String get debtPaymentDeleteTitle => 'Delete payment?';

  @override
  String get debtPaymentDeleteBody =>
      'The amount returns to the debt remainder. The linked transfer transaction is not deleted.';

  @override
  String get debtTransferOutAccount => 'Source account';

  @override
  String get debtTransferInAccount => 'Target account';

  @override
  String get debtTransferNote => 'Transfer note';

  @override
  String get debtTransferRecordAction => 'Record';

  @override
  String get attachmentDebtPickBody =>
      'The file will be stored with this debt.';

  @override
  String get remindersBannerTitle => 'Payment reminders are off';

  @override
  String get remindersBannerBody =>
      'Turn on and Kopilka will remind you of due dates at 9:00.';

  @override
  String get remindersEnableAction => 'Turn on';

  @override
  String get remindersDismissAction => 'Not now';

  @override
  String get remindersEnabledSnackbar => 'Reminders are on';

  @override
  String get remindersPermissionDenied =>
      'Notification permission was not granted — enable it in system settings.';

  @override
  String get remindersLinuxHint =>
      'On Linux, reminders appear only when the app is running.';

  @override
  String get remindersSectionTitle => 'Reminders';

  @override
  String get remindersToggle => 'Payment reminders';

  @override
  String get remindersTimeNote => 'A reminder is shown at 9:00 local time.';

  @override
  String get remindersInterestNote =>
      'Interest reminders for savings accounts are included.';

  @override
  String get accountSavingsLabel => 'Savings';

  @override
  String get accountSavingsHint => 'You credit interest yourself, by transfer.';

  @override
  String get accountSavingsBadge => 'Savings';

  @override
  String get accountInterestDateLabel => 'Interest reminder date';

  @override
  String get accountInterestDateEditAction => 'Change';

  @override
  String get dashboardInterestCardTitle => 'Interest reminder';

  @override
  String dashboardInterestCardBody(String name, String date) {
    return 'Account “$name”: reminder date is $date.';
  }

  @override
  String dashboardInterestMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# more accounts',
      one: '1 more account',
    );
    return 'and $_temp0';
  }

  @override
  String get adviceMinBalanceTitle => 'A cushion that earns interest';

  @override
  String get adviceMinBalanceBody =>
      'Money on a regular account earns no interest. Create a savings account — a reminder will tell you when to credit it.';

  @override
  String get adviceMinBalanceAction => 'Create a savings account';

  @override
  String get transactionViewAttachment => 'View attachment';

  @override
  String reminderOverBudgetBody(String category, String amount, int days) {
    return '“$category” is close to the limit: $amount left for $days days.';
  }

  @override
  String reminderOverBudgetExceededBody(
    String category,
    String amount,
    int days,
  ) {
    return '“$category” is over the limit by $amount, $days days to go.';
  }

  @override
  String get navPlanning => 'Planning';

  @override
  String get planningEmpty =>
      'No plans yet. Plan an income or an expense for a period.';

  @override
  String get planningEmptyCta => 'Add plan';

  @override
  String get planningAddTooltip => 'Add plan';

  @override
  String get planningAutoTooltip => 'Auto-budget';

  @override
  String get planningSectionExpense => 'Expense plans';

  @override
  String get planningSectionIncome => 'Income plans';

  @override
  String planningPeriodRange(String start, String end) {
    return '$start – $end';
  }

  @override
  String planningPlanLine(String amount) {
    return 'Plan: $amount';
  }

  @override
  String planningFactLine(String amount) {
    return 'Actual: $amount';
  }

  @override
  String planningRemainingLine(String amount) {
    return 'Remaining: $amount';
  }

  @override
  String planningOverByLine(String amount) {
    return 'Over by: $amount';
  }

  @override
  String planningGoalReachedLine(String amount) {
    return 'Goal reached: +$amount';
  }

  @override
  String get planningActiveBadge => 'Ongoing';

  @override
  String get planningAddTitle => 'New plan';

  @override
  String get planningEditTitle => 'Edit plan';

  @override
  String get planningKindHint => 'The plan direction follows the category kind';

  @override
  String get planningPeriodStartLabel => 'Period start';

  @override
  String get planningPeriodEndLabel => 'Period end';

  @override
  String get planningPeriodInvalid =>
      'The period end cannot be before its start';

  @override
  String planningBaseCurrencyHint(String code) {
    return 'The plan amount is in the base currency ($code)';
  }

  @override
  String get planningNoCategoriesHint =>
      'No categories of this kind yet — create them in Categories';

  @override
  String get planningDeleteTitle => 'Delete plan?';

  @override
  String planningDeleteBody(String name) {
    return 'The plan for “$name” will be hidden from the lists. Transactions are not affected.';
  }

  @override
  String get planningAutoTitle => 'Auto-budget';

  @override
  String get planningAutoIntro =>
      'Kopilka will estimate the average income from your transactions and suggest a plan for the chosen term. Nothing is created without confirmation.';

  @override
  String planningAutoAverage(String amount, int count) {
    return 'Average income: $amount per month ($count months with income in the last 6 months)';
  }

  @override
  String get planningAutoNoData =>
      'At least one completed month with income is needed for the estimate.';

  @override
  String get planningAutoTermLabel => 'Plan term';

  @override
  String planningAutoMonths(int months) {
    return '$months mo.';
  }

  @override
  String planningAutoAmountHelper(String amount, int months) {
    return 'By average income: $amount × $months mo.';
  }

  @override
  String get planningAutoCreateAction => 'Create plan';

  @override
  String get planningAutoCreatedSnack => 'Plan created';

  @override
  String get errorPlanOverlap =>
      'This category already has a plan for an overlapping period. Change the period or delete the existing plan.';

  @override
  String get errorCategoryHasPlans =>
      'A plan refers to this category. Delete it first.';
}
