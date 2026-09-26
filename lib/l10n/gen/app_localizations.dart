import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru'),
  ];

  /// Application name shown in the window title and task switcher
  ///
  /// In en, this message translates to:
  /// **'Kopilka'**
  String get appTitle;

  /// Navigation label and screen title for the accounts section
  ///
  /// In en, this message translates to:
  /// **'Accounts'**
  String get navAccounts;

  /// Navigation label and screen title for the transactions section
  ///
  /// In en, this message translates to:
  /// **'Transactions'**
  String get navTransactions;

  /// Navigation label and screen title for the categories section
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get navCategories;

  /// Navigation label and screen title for the reports section
  ///
  /// In en, this message translates to:
  /// **'Reports'**
  String get navReports;

  /// Navigation label and screen title for the settings section
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// Placeholder text of the reports screen
  ///
  /// In en, this message translates to:
  /// **'Reports and budgets will appear here. Stage M2.'**
  String get reportsPlaceholder;

  /// Header of the dashboard card with the sum of all account balances
  ///
  /// In en, this message translates to:
  /// **'Total balance'**
  String get reportsTotalBalance;

  /// Title of the dashboard card with the per-category expense breakdown
  ///
  /// In en, this message translates to:
  /// **'Expenses by category'**
  String get reportsCategoryBreakdownTitle;

  /// Empty state of the per-category breakdown for the selected month
  ///
  /// In en, this message translates to:
  /// **'No expenses this month.'**
  String get reportsCategoryBreakdownEmpty;

  /// Title of the dashboard card with income/expense dynamics across months
  ///
  /// In en, this message translates to:
  /// **'Dynamics by month'**
  String get reportsMonthDynamicsTitle;

  /// Prefix of the month total in the category breakdown card
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get reportsTotalLabel;

  /// Title of the budgets card on the reports dashboard
  ///
  /// In en, this message translates to:
  /// **'Budgets'**
  String get budgetsTitle;

  /// Empty state of the budgets card
  ///
  /// In en, this message translates to:
  /// **'No budgets yet. Set a monthly limit for a category.'**
  String get budgetsEmpty;

  /// Button and dialog title for creating a budget
  ///
  /// In en, this message translates to:
  /// **'Add budget'**
  String get budgetAdd;

  /// Dialog title for editing a budget limit
  ///
  /// In en, this message translates to:
  /// **'Edit budget'**
  String get budgetEdit;

  /// Confirmation title for budget deletion
  ///
  /// In en, this message translates to:
  /// **'Delete budget?'**
  String get budgetDeleteTitle;

  /// Confirmation body for budget deletion
  ///
  /// In en, this message translates to:
  /// **'The budget for “{name}” will be removed.'**
  String budgetDeleteBody(String name);

  /// Section header of the settings screen with backup actions
  ///
  /// In en, this message translates to:
  /// **'Backup and export'**
  String get backupSectionTitle;

  /// Action creating a full JSON backup and sharing the file
  ///
  /// In en, this message translates to:
  /// **'Export backup (JSON)'**
  String get exportJsonAction;

  /// Action restoring the database from a JSON backup
  ///
  /// In en, this message translates to:
  /// **'Import backup (JSON)'**
  String get importJsonAction;

  /// Action exporting live transactions to CSV
  ///
  /// In en, this message translates to:
  /// **'Export transactions (CSV)'**
  String get exportCsvAction;

  /// Setting title for the launch auto-backup directory
  ///
  /// In en, this message translates to:
  /// **'Auto-backup on launch'**
  String get autoBackupTitle;

  /// Button choosing the auto-backup directory
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get autoBackupPickFolder;

  /// Auto-backup state when no directory is chosen
  ///
  /// In en, this message translates to:
  /// **'Folder is not selected'**
  String get autoBackupDisabled;

  /// Button running the auto-backup immediately
  ///
  /// In en, this message translates to:
  /// **'Run now'**
  String get autoBackupRunNow;

  /// Body of the confirmation before importing a backup
  ///
  /// In en, this message translates to:
  /// **'All current data will be replaced with the backup content. Continue?'**
  String get importReplaceWarning;

  /// Title of the confirmation before importing a backup
  ///
  /// In en, this message translates to:
  /// **'Import backup?'**
  String get importConfirmTitle;

  /// Message after a successful import
  ///
  /// In en, this message translates to:
  /// **'Backup imported.'**
  String get importDone;

  /// Message after a file was exported
  ///
  /// In en, this message translates to:
  /// **'File saved.'**
  String get backupExported;

  /// Message when the user cancels a picker dialog
  ///
  /// In en, this message translates to:
  /// **'Cancelled.'**
  String get backupCancelled;

  /// Backup file is not valid JSON of the expected shape
  ///
  /// In en, this message translates to:
  /// **'This file is not a Kopilka backup.'**
  String get errorBackupInvalidFormat;

  /// Backup schema_version is newer than supported
  ///
  /// In en, this message translates to:
  /// **'This backup was made by a newer version of the app.'**
  String get errorBackupTooNew;

  /// Backup schema_version is older than any supported migration
  ///
  /// In en, this message translates to:
  /// **'This backup version is too old and cannot be read.'**
  String get errorBackupTooOld;

  /// Backup rows do not match the expected schema
  ///
  /// In en, this message translates to:
  /// **'Backup content is damaged or incomplete.'**
  String get errorBackupInvalidData;

  /// Message after a successful auto-backup
  ///
  /// In en, this message translates to:
  /// **'Auto-backup saved: {fileName}'**
  String autoBackupDone(String fileName);

  /// Appendix showing how many stale auto-backups were removed
  ///
  /// In en, this message translates to:
  /// **' ({count} old removed)'**
  String autoBackupRemovedOld(int count);

  /// Message when the auto-backup could not write the file
  ///
  /// In en, this message translates to:
  /// **'Auto-backup failed: {reason}'**
  String autoBackupFailed(String reason);

  /// Section header for update checks (M1, session 4)
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updateSectionTitle;

  /// Switch tile for automatic update checks
  ///
  /// In en, this message translates to:
  /// **'Check for updates automatically'**
  String get updateAutoCheck;

  /// Subtitle for the automatic check switch
  ///
  /// In en, this message translates to:
  /// **'Once every 7 days, no other network activity'**
  String get updateAutoCheckHint;

  /// Manual update check button
  ///
  /// In en, this message translates to:
  /// **'Check now'**
  String get updateCheckNow;

  /// Progress label during update check
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get updateChecking;

  /// Snack when no update is available
  ///
  /// In en, this message translates to:
  /// **'You have the latest version'**
  String get updateUpToDate;

  /// Snack when the check failed (offline or API error)
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates'**
  String get updateUnavailable;

  /// Title of the update dialog
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String updateFoundTitle(String version);

  /// Button that opens the release page in a browser
  ///
  /// In en, this message translates to:
  /// **'Open release page'**
  String get updateFoundOpenRelease;

  /// Body of the update dialog when the release has no notes
  ///
  /// In en, this message translates to:
  /// **'No changelog provided.'**
  String get updateFoundNoChangelog;

  /// First-launch offer to enable update checks
  ///
  /// In en, this message translates to:
  /// **'Check for updates automatically?'**
  String get updateOfferTitle;

  /// Body of the first-launch offer dialog
  ///
  /// In en, this message translates to:
  /// **'The app will contact GitHub once a week to look for new versions. Nothing else is sent or downloaded — you install updates yourself.'**
  String get updateOfferBody;

  /// Button that enables automatic checks
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get updateOfferEnable;

  /// Button that declines the offer
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get updateOfferLater;

  /// Snack when the browser could not be opened
  ///
  /// In en, this message translates to:
  /// **'Could not open the release page'**
  String get updateOpenFailed;

  /// Button that confirms a form
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveAction;

  /// Button that closes a form without changes
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelAction;

  /// Button that deletes the record
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteAction;

  /// Button that opens the record for editing
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editAction;

  /// Field label for a record name
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get nameLabel;

  /// Field label for a money amount
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get amountLabel;

  /// Field label for a transaction date
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get dateLabel;

  /// Field label for an optional transaction note
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get noteLabel;

  /// Field label for a transaction category
  ///
  /// In en, this message translates to:
  /// **'Category'**
  String get categoryLabel;

  /// Field label for income/expense kind
  ///
  /// In en, this message translates to:
  /// **'Kind'**
  String get kindLabel;

  /// Field label for a currency picker
  ///
  /// In en, this message translates to:
  /// **'Currency'**
  String get currencyLabel;

  /// Data layer rejected the input as invalid
  ///
  /// In en, this message translates to:
  /// **'Please check the entered values.'**
  String get errorInvalidInput;

  /// The record to update or delete is gone
  ///
  /// In en, this message translates to:
  /// **'This record has already been deleted or does not exist.'**
  String get errorNotFound;

  /// Unexpected failure of a data operation
  ///
  /// In en, this message translates to:
  /// **'The action failed. Please try again.'**
  String get errorUnknown;

  /// Currency soft delete refused because live accounts reference it
  ///
  /// In en, this message translates to:
  /// **'This currency is used by existing accounts. Delete or move them first.'**
  String get errorCurrencyUsedByAccounts;

  /// Account delete or currency change refused because live transactions reference it
  ///
  /// In en, this message translates to:
  /// **'This account has transactions. Delete them first.'**
  String get errorAccountHasTransactions;

  /// System preset category cannot be deleted
  ///
  /// In en, this message translates to:
  /// **'Built-in categories cannot be deleted.'**
  String get errorCategoryIsSystem;

  /// Category delete refused because live subcategories exist
  ///
  /// In en, this message translates to:
  /// **'This category has subcategories. Delete or move them first.'**
  String get errorCategoryHasChildren;

  /// Category delete refused because live transactions reference it
  ///
  /// In en, this message translates to:
  /// **'This category is used by transactions. Delete them first.'**
  String get errorCategoryHasTransactions;

  /// Category reparenting refused because it would create a cycle
  ///
  /// In en, this message translates to:
  /// **'This move would create a cycle in the category tree.'**
  String get errorCategoryCycle;

  /// Selected parent category is missing or of another kind
  ///
  /// In en, this message translates to:
  /// **'The parent category is unavailable or has a different kind.'**
  String get errorParentInvalid;

  /// Tried to create a budget on a non-expense category
  ///
  /// In en, this message translates to:
  /// **'A budget can only be set on an expense category.'**
  String get errorBudgetCategoryInvalid;

  /// Category already has a live budget
  ///
  /// In en, this message translates to:
  /// **'This category already has a budget.'**
  String get errorBudgetAlreadyExists;

  /// Cannot delete a category referenced by a live budget
  ///
  /// In en, this message translates to:
  /// **'This category has a budget. Delete the budget first.'**
  String get errorCategoryHasBudget;

  /// Transfer form rejected because both sides are the same account
  ///
  /// In en, this message translates to:
  /// **'The source and target accounts must be different.'**
  String get errorTransferSameAccount;

  /// Amount field validation message
  ///
  /// In en, this message translates to:
  /// **'Enter an amount greater than zero.'**
  String get amountInvalid;

  /// Validation message of the account form when no currency is chosen
  ///
  /// In en, this message translates to:
  /// **'Select a currency.'**
  String get selectCurrencyValidator;

  /// Empty state of the accounts list
  ///
  /// In en, this message translates to:
  /// **'No accounts yet. Add your first account.'**
  String get accountsEmpty;

  /// Button and dialog title for creating an account
  ///
  /// In en, this message translates to:
  /// **'Add account'**
  String get accountAdd;

  /// Dialog title for editing an account
  ///
  /// In en, this message translates to:
  /// **'Edit account'**
  String get accountEdit;

  /// Account kind: cash
  ///
  /// In en, this message translates to:
  /// **'Cash'**
  String get accountKindCash;

  /// Account kind: bank account
  ///
  /// In en, this message translates to:
  /// **'Bank account'**
  String get accountKindBank;

  /// Account kind: card
  ///
  /// In en, this message translates to:
  /// **'Card'**
  String get accountKindCard;

  /// Account kind: other
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get accountKindOther;

  /// Field label for the account opening balance
  ///
  /// In en, this message translates to:
  /// **'Initial balance'**
  String get accountInitialBalance;

  /// Confirmation title for account deletion
  ///
  /// In en, this message translates to:
  /// **'Delete account?'**
  String get accountDeleteTitle;

  /// Confirmation body for account deletion
  ///
  /// In en, this message translates to:
  /// **'The account “{name}” will be hidden from the lists.'**
  String accountDeleteBody(String name);

  /// Title of the categories management screen
  ///
  /// In en, this message translates to:
  /// **'Categories'**
  String get categoriesTitle;

  /// Empty state of the categories list
  ///
  /// In en, this message translates to:
  /// **'No categories yet.'**
  String get categoriesEmpty;

  /// Button and dialog title for creating a category
  ///
  /// In en, this message translates to:
  /// **'Add category'**
  String get categoryAdd;

  /// Dialog title for editing a category
  ///
  /// In en, this message translates to:
  /// **'Edit category'**
  String get categoryEdit;

  /// Category or transaction kind: income
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get kindIncome;

  /// Category or transaction kind: expense
  ///
  /// In en, this message translates to:
  /// **'Expense'**
  String get kindExpense;

  /// Field label for the parent category picker
  ///
  /// In en, this message translates to:
  /// **'Parent category'**
  String get categoryParent;

  /// Option meaning the category has no parent
  ///
  /// In en, this message translates to:
  /// **'No parent (top level)'**
  String get categoryParentNone;

  /// Badge marking a system preset category
  ///
  /// In en, this message translates to:
  /// **'built-in'**
  String get systemBadge;

  /// Confirmation title for category deletion
  ///
  /// In en, this message translates to:
  /// **'Delete category?'**
  String get categoryDeleteTitle;

  /// Confirmation body for category deletion
  ///
  /// In en, this message translates to:
  /// **'The category “{name}” will be hidden from the lists.'**
  String categoryDeleteBody(String name);

  /// Empty state of the transactions list without filters
  ///
  /// In en, this message translates to:
  /// **'No transactions yet. Add the first one.'**
  String get transactionsEmpty;

  /// Empty state of the filtered transactions list
  ///
  /// In en, this message translates to:
  /// **'Nothing matches the selected filters.'**
  String get transactionsEmptyFiltered;

  /// Hint of the transaction search field
  ///
  /// In en, this message translates to:
  /// **'Search in notes'**
  String get searchHint;

  /// Filter chip meaning no type filter
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// Filter chip for income transactions
  ///
  /// In en, this message translates to:
  /// **'Incomes'**
  String get filterIncomes;

  /// Filter chip for expense transactions
  ///
  /// In en, this message translates to:
  /// **'Expenses'**
  String get filterExpenses;

  /// Filter chip for transfer transactions
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get filterTransfers;

  /// Account filter option meaning no account filter
  ///
  /// In en, this message translates to:
  /// **'All accounts'**
  String get filterAllAccounts;

  /// Quick action creating an expense
  ///
  /// In en, this message translates to:
  /// **'Expense'**
  String get expenseAction;

  /// Quick action creating an income
  ///
  /// In en, this message translates to:
  /// **'Income'**
  String get incomeAction;

  /// Quick action creating a transfer
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get transferAction;

  /// Dialog title for creating an expense
  ///
  /// In en, this message translates to:
  /// **'New expense'**
  String get newExpenseTitle;

  /// Dialog title for creating an income
  ///
  /// In en, this message translates to:
  /// **'New income'**
  String get newIncomeTitle;

  /// Dialog title for creating a transfer
  ///
  /// In en, this message translates to:
  /// **'New transfer'**
  String get newTransferTitle;

  /// Field label for the transfer source account
  ///
  /// In en, this message translates to:
  /// **'From account'**
  String get accountFrom;

  /// Field label for the transfer target account
  ///
  /// In en, this message translates to:
  /// **'To account'**
  String get accountTo;

  /// Confirmation title for transaction deletion
  ///
  /// In en, this message translates to:
  /// **'Delete transaction?'**
  String get transactionDeleteTitle;

  /// Confirmation body for transaction deletion
  ///
  /// In en, this message translates to:
  /// **'The transaction will be hidden from the lists.'**
  String get transactionDeleteBody;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
