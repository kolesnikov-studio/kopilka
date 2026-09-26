// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appTitle => 'Kopilka';

  @override
  String get navAccounts => 'Счета';

  @override
  String get navTransactions => 'Транзакции';

  @override
  String get navCategories => 'Категории';

  @override
  String get navReports => 'Отчёты';

  @override
  String get navSettings => 'Настройки';

  @override
  String get reportsPlaceholder => 'Здесь появятся отчёты и бюджеты. Этап M2.';

  @override
  String get reportsTotalBalance => 'Общий баланс';

  @override
  String get reportsCategoryBreakdownTitle => 'Расходы по категориям';

  @override
  String get reportsCategoryBreakdownEmpty => 'В этом месяце расходов нет.';

  @override
  String get reportsMonthDynamicsTitle => 'Динамика по месяцам';

  @override
  String get reportsTotalLabel => 'Всего';

  @override
  String get backupSectionTitle => 'Бэкап и экспорт';

  @override
  String get exportJsonAction => 'Экспорт бэкапа (JSON)';

  @override
  String get importJsonAction => 'Импорт бэкапа (JSON)';

  @override
  String get exportCsvAction => 'Экспорт операций (CSV)';

  @override
  String get autoBackupTitle => 'Автобэкап при запуске';

  @override
  String get autoBackupPickFolder => 'Выбрать папку';

  @override
  String get autoBackupDisabled => 'Папка не выбрана';

  @override
  String get autoBackupRunNow => 'Запустить сейчас';

  @override
  String get importReplaceWarning =>
      'Все текущие данные будут заменены содержимым бэкапа. Продолжить?';

  @override
  String get importConfirmTitle => 'Импортировать бэкап?';

  @override
  String get importDone => 'Бэкап восстановлен.';

  @override
  String get backupExported => 'Файл сохранён.';

  @override
  String get backupCancelled => 'Отменено.';

  @override
  String get errorBackupInvalidFormat =>
      'Этот файл не является бэкапом Kopilka.';

  @override
  String get errorBackupTooNew =>
      'Бэкап создан более новой версией приложения.';

  @override
  String get errorBackupTooOld =>
      'Версия бэкапа слишком старая и не может быть прочитана.';

  @override
  String get errorBackupInvalidData =>
      'Содержимое бэкапа повреждено или неполно.';

  @override
  String autoBackupDone(String fileName) {
    return 'Автобэкап сохранён: $fileName';
  }

  @override
  String autoBackupRemovedOld(int count) {
    return ' (удалено старых: $count)';
  }

  @override
  String autoBackupFailed(String reason) {
    return 'Автобэкап не удался: $reason';
  }

  @override
  String get updateSectionTitle => 'Обновления';

  @override
  String get updateAutoCheck => 'Проверять обновления автоматически';

  @override
  String get updateAutoCheckHint =>
      'Раз в 7 дней; другого сетевого трафика в приложении нет';

  @override
  String get updateCheckNow => 'Проверить сейчас';

  @override
  String get updateChecking => 'Проверяем…';

  @override
  String get updateUpToDate => 'У вас последняя версия';

  @override
  String get updateUnavailable => 'Не удалось проверить обновления';

  @override
  String updateFoundTitle(String version) {
    return 'Доступно обновление: $version';
  }

  @override
  String get updateFoundOpenRelease => 'Открыть страницу релиза';

  @override
  String get updateFoundNoChangelog => 'Описание релиза не указано.';

  @override
  String get updateOfferTitle => 'Проверять обновления автоматически?';

  @override
  String get updateOfferBody =>
      'Приложение раз в неделю свяжется с GitHub, чтобы узнать о новых версиях. Ничего больше не отправляется и не скачивается — обновления вы устанавливаете сами.';

  @override
  String get updateOfferEnable => 'Включить';

  @override
  String get updateOfferLater => 'Не сейчас';

  @override
  String get updateOpenFailed => 'Не удалось открыть страницу релиза';

  @override
  String get saveAction => 'Сохранить';

  @override
  String get cancelAction => 'Отмена';

  @override
  String get deleteAction => 'Удалить';

  @override
  String get editAction => 'Изменить';

  @override
  String get nameLabel => 'Название';

  @override
  String get amountLabel => 'Сумма';

  @override
  String get dateLabel => 'Дата';

  @override
  String get noteLabel => 'Заметка';

  @override
  String get categoryLabel => 'Категория';

  @override
  String get kindLabel => 'Вид';

  @override
  String get currencyLabel => 'Валюта';

  @override
  String get errorInvalidInput => 'Проверьте введённые значения.';

  @override
  String get errorNotFound => 'Запись уже удалена или не существует.';

  @override
  String get errorUnknown =>
      'Не удалось выполнить действие. Попробуйте ещё раз.';

  @override
  String get errorCurrencyUsedByAccounts =>
      'Эту валюту используют живые счета. Сначала удалите или переведите их.';

  @override
  String get errorAccountHasTransactions =>
      'У счёта есть операции. Сначала удалите их.';

  @override
  String get errorCategoryIsSystem =>
      'Предустановленную категорию удалить нельзя.';

  @override
  String get errorCategoryHasChildren =>
      'В категории есть вложенные. Сначала удалите или перенесите их.';

  @override
  String get errorCategoryHasTransactions =>
      'Категория используется в операциях. Сначала удалите их.';

  @override
  String get errorCategoryCycle =>
      'Такой перенос создал бы цикл в дереве категорий.';

  @override
  String get errorParentInvalid =>
      'Родительская категория недоступна или другого вида.';

  @override
  String get errorBudgetCategoryInvalid =>
      'Бюджет можно установить только на категорию расходов.';

  @override
  String get errorBudgetAlreadyExists => 'У этой категории уже есть бюджет.';

  @override
  String get errorCategoryHasBudget =>
      'На эту категорию ссылается бюджет. Сначала удалите его.';

  @override
  String get errorTransferSameAccount =>
      'Счёт списания и зачисления должны различаться.';

  @override
  String get amountInvalid => 'Введите сумму больше нуля.';

  @override
  String get selectCurrencyValidator => 'Выберите валюту.';

  @override
  String get accountsEmpty => 'Счетов пока нет. Добавьте первый.';

  @override
  String get accountAdd => 'Добавить счёт';

  @override
  String get accountEdit => 'Изменить счёт';

  @override
  String get accountKindCash => 'Наличные';

  @override
  String get accountKindBank => 'Банковский счёт';

  @override
  String get accountKindCard => 'Карта';

  @override
  String get accountKindOther => 'Другое';

  @override
  String get accountInitialBalance => 'Начальный баланс';

  @override
  String get accountDeleteTitle => 'Удалить счёт?';

  @override
  String accountDeleteBody(String name) {
    return 'Счёт «$name» будет скрыт из списков.';
  }

  @override
  String get categoriesTitle => 'Категории';

  @override
  String get categoriesEmpty => 'Категорий пока нет.';

  @override
  String get categoryAdd => 'Добавить категорию';

  @override
  String get categoryEdit => 'Изменить категорию';

  @override
  String get kindIncome => 'Доход';

  @override
  String get kindExpense => 'Расход';

  @override
  String get categoryParent => 'Родительская категория';

  @override
  String get categoryParentNone => 'Без родителя (верхний уровень)';

  @override
  String get systemBadge => 'предустановлена';

  @override
  String get categoryDeleteTitle => 'Удалить категорию?';

  @override
  String categoryDeleteBody(String name) {
    return 'Категория «$name» будет скрыта из списков.';
  }

  @override
  String get transactionsEmpty => 'Операций пока нет. Добавьте первую.';

  @override
  String get transactionsEmptyFiltered =>
      'Под выбранные фильтры ничего не подошло.';

  @override
  String get searchHint => 'Поиск по заметкам';

  @override
  String get filterAll => 'Все';

  @override
  String get filterIncomes => 'Доходы';

  @override
  String get filterExpenses => 'Расходы';

  @override
  String get filterTransfers => 'Переводы';

  @override
  String get filterAllAccounts => 'Все счета';

  @override
  String get expenseAction => 'Расход';

  @override
  String get incomeAction => 'Доход';

  @override
  String get transferAction => 'Перевод';

  @override
  String get newExpenseTitle => 'Новый расход';

  @override
  String get newIncomeTitle => 'Новый доход';

  @override
  String get newTransferTitle => 'Новый перевод';

  @override
  String get accountFrom => 'Счёт списания';

  @override
  String get accountTo => 'Счёт зачисления';

  @override
  String get transactionDeleteTitle => 'Удалить операцию?';

  @override
  String get transactionDeleteBody => 'Операция будет скрыта из списков.';
}
