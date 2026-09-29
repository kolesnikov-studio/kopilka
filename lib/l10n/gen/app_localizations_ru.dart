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
  String get navTransactions => 'Операции';

  @override
  String get retryAction => 'Повторить';

  @override
  String get accountsEmptyCta => 'Добавить счёт';

  @override
  String get transactionsEmptyCta => 'Добавить операцию';

  @override
  String get addAction => 'Добавить';

  @override
  String get accountLabel => 'Счёт';

  @override
  String get selectAccountValidator => 'Выберите счёт.';

  @override
  String get budgetMonthlyHint => 'Лимит действует каждый месяц';

  @override
  String budgetBaseCurrencyHint(String code) {
    return 'Лимит в базовой валюте ($code)';
  }

  @override
  String get navCategories => 'Категории';

  @override
  String get navReports => 'Отчёты';

  @override
  String get navSettings => 'Настройки';

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
  String get reportsAtCurrentRate => 'по текущему курсу';

  @override
  String get budgetsTitle => 'Бюджеты';

  @override
  String get budgetsEmpty =>
      'Бюджетов пока нет. Задайте месячный лимит категории.';

  @override
  String get budgetAdd => 'Добавить бюджет';

  @override
  String get budgetEdit => 'Изменить бюджет';

  @override
  String get budgetDeleteTitle => 'Удалить бюджет?';

  @override
  String budgetDeleteBody(String name) {
    return 'Бюджет для «$name» будет удалён.';
  }

  @override
  String get backupSectionTitle => 'Бэкап и экспорт';

  @override
  String get exportJsonAction => 'Экспорт бэкапа (JSON)';

  @override
  String get importJsonAction => 'Импорт бэкапа (JSON)';

  @override
  String get exportCsvAction => 'Экспорт операций (CSV)';

  @override
  String get importCsvAction => 'Импорт операций (CSV)';

  @override
  String get csvImportMappingTitle => 'Сопоставление колонок';

  @override
  String get csvMappingHint =>
      'Для каждой колонки файла выберите, что в ней находится. Колонки «не используется» пропускаются.';

  @override
  String csvImportRowCount(int count) {
    return 'В файле операций: $count.';
  }

  @override
  String csvImportColumnName(int number) {
    return 'Колонка $number';
  }

  @override
  String get csvColumnUnused => 'Не используется';

  @override
  String get csvFieldDate => 'Дата';

  @override
  String get csvFieldType => 'Тип';

  @override
  String get csvFieldAccount => 'Счёт (списания)';

  @override
  String get csvFieldAmount => 'Сумма';

  @override
  String get csvFieldCurrency => 'Валюта';

  @override
  String get csvFieldTargetAccount => 'Счёт (зачисления)';

  @override
  String get csvFieldTargetAmount => 'Сумма (зачисления)';

  @override
  String get csvFieldCategory => 'Категория';

  @override
  String get csvFieldNote => 'Заметка';

  @override
  String get csvMappingNextAction => 'Продолжить';

  @override
  String get csvMappingDuplicateField => 'Две колонки привязаны к одному полю.';

  @override
  String csvMappingMissingRequired(String fields) {
    return 'Не привязаны обязательные поля: $fields.';
  }

  @override
  String csvMappingColumnMissing(int number) {
    return 'Колонка $number привязана, но в строках файла её нет.';
  }

  @override
  String get csvImportConfirmTitle => 'Импортировать операции?';

  @override
  String get csvImportConfirmAction => 'Импортировать';

  @override
  String csvImportMergeWarning(int count) {
    return 'Операции ($count) будут ДОБАВЛЕНЫ к существующим. Дубли не отслеживаются: повторный импорт того же файла создаст каждую операцию заново.';
  }

  @override
  String csvImportDone(Object count) {
    return 'Добавлено операций: $count.';
  }

  @override
  String get errorCsvInvalidFormat =>
      'Не удалось разобрать файл: это не корректный CSV.';

  @override
  String get errorCsvNoDataRows => 'В файле нет строк данных.';

  @override
  String errorCsvInvalidFormatLine(int line) {
    return 'Файл не является корректным CSV (строка $line).';
  }

  @override
  String get errorCsvInvalidMapping =>
      'Маппинг колонок неверен: проверьте дубли и обязательные поля.';

  @override
  String get errorCsvInvalidData =>
      'Содержимое файла не соответствует счетам и категориям базы.';

  @override
  String errorCsvInvalidDataLine(int line) {
    return 'Строка $line: значение не соответствует счетам, категориям или форматам базы. Ничего не импортировано.';
  }

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
  String get rateSyncSectionTitle => 'Курсы валют';

  @override
  String get rateSyncEnabled => 'Обновлять курсы из интернета';

  @override
  String get rateSyncEnabledHint =>
      'Курсы обновляются при запуске приложения и по кнопке ниже; без сети курсы вводятся вручную';

  @override
  String get rateSyncNow => 'Обновить сейчас';

  @override
  String get rateSyncing => 'Обновляем…';

  @override
  String rateSyncUpdated(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Обновлено $count валюты',
      many: 'Обновлено $count валют',
      few: 'Обновлено $count валюты',
      one: 'Обновлена $count валюта',
    );
    return '$_temp0';
  }

  @override
  String get rateSyncUnchanged => 'Курсы не изменились';

  @override
  String get rateSyncOffline => 'Сеть недоступна — остались прежние курсы';

  @override
  String get rateSyncDisabled => 'Синхронизация курсов выключена';

  @override
  String get rateSyncFailed =>
      'Источник курсов не отвечает — остались прежние курсы';

  @override
  String get rateSyncAlreadyRunning => 'Обновление уже выполняется';

  @override
  String get saveAction => 'Сохранить';

  @override
  String get cancelAction => 'Отмена';

  @override
  String get deleteAction => 'Удалить';

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
  String accountCurrencyRow(String symbol, String code) {
    return 'Валюта: $symbol $code';
  }

  @override
  String get accountCurrencyLockedHint =>
      'Валюта счёта меняется, пока у счёта нет операций';

  @override
  String get accountCurrencyChangeAction => 'Сменить валюту';

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
  String get categoryIconLabel => 'Иконка';

  @override
  String get systemBadge => 'предустановлена';

  @override
  String get categoryDeleteTitle => 'Удалить категорию?';

  @override
  String categoryDeleteBody(String name) {
    return 'Категория «$name» будет скрыта из списков.';
  }

  @override
  String get categoryHideTitle => 'Скрыть категорию?';

  @override
  String get categoryHideAction => 'Скрыть';

  @override
  String categoryHideBody(String name) {
    return 'Предустановленная категория «$name» исчезнет из всех списков. Вернуть можно позже: Настройки → Скрытые категории. Операции и бюджеты продолжат работать.';
  }

  @override
  String categoryHiddenSnack(String name) {
    return 'Категория «$name» скрыта';
  }

  @override
  String get hiddenCategoriesTitle => 'Скрытые категории';

  @override
  String hiddenCategoriesTileSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count скрытой категории',
      many: '$count скрытых категорий',
      few: '$count скрытые категории',
      one: '$count скрытая категория',
    );
    return '$_temp0';
  }

  @override
  String get hiddenCategoriesEmpty => 'Скрытых категорий нет.';

  @override
  String get categoryRestoreAction => 'Вернуть';

  @override
  String categoryRestoredSnack(String name) {
    return 'Категория «$name» возвращена';
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

  @override
  String get transactionTileNoCategory => 'Без категории';

  @override
  String get transactionTileAccountGone => 'Счёт удалён';

  @override
  String get currenciesScreenTitle => 'Валюты';

  @override
  String currenciesSettingsSubtitle(int count) {
    return 'В списке: $count';
  }

  @override
  String get currenciesBaseBadge => 'Базовая валюта';

  @override
  String currenciesRateOf(String rate, String code) {
    return '1 = $rate $code';
  }

  @override
  String get currencyAdd => 'Добавить валюту';

  @override
  String get currencySearchHint => 'Поиск по коду или названию';

  @override
  String get currencyAlreadyAdded => 'уже добавлена';

  @override
  String get currencyRateHint =>
      'Курс: сколько базовой валюты в одной единице этой валюты';

  @override
  String get currencyRateLabel => 'Курс к базовой';

  @override
  String get currencyRateInvalid =>
      'Введите курс больше нуля (до 6 знаков после разделителя).';

  @override
  String currencyRateDialogTitle(String code, String base) {
    return 'Курс $code → $base';
  }

  @override
  String get currencyRateRecalcNote => 'Отчёты пересчитаются по новому курсу.';

  @override
  String get currencyMakeBase => 'Сделать базовой';

  @override
  String currencyChangeBaseTitle(String code) {
    return 'Сделать $code базовой?';
  }

  @override
  String currencyChangeBaseBody(String code) {
    return 'Балансы счетов останутся в своих валютах. Курсы остальных валют будут пересчитаны относительно $code. Отчёты и лимиты бюджетов будут пересчитаны по новым курсам.';
  }

  @override
  String get currencyChangeBaseAction => 'Сделать базовой';

  @override
  String currencyDeleteTitle(String code) {
    return 'Удалить валюту $code из справочника?';
  }

  @override
  String get currencyDeleteBody => 'История операций не изменится.';

  @override
  String currencyDeleteBlockedBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Эту валюту используют $count счета.',
      many: 'Эту валюту используют $count счетов.',
      few: 'Эту валюту используют $count счёта.',
      one: 'Эту валюту использует $count счёт.',
    );
    return '$_temp0 Сначала удалите или перенесите их в другую валюту.';
  }

  @override
  String get currencyDeleteMenuAction => 'Удалить';

  @override
  String get transferAmountOut => 'Списано';

  @override
  String get transferAmountIn => 'Зачислено';

  @override
  String transferRateLine(String from, String rate, String to) {
    return 'По курсу 1 $from = $rate $to';
  }

  @override
  String get transferPrefillNote =>
      'Предзаполнено по текущему курсу — поправьте, если курс обмена отличался';

  @override
  String get themeSectionTitle => 'Тема';

  @override
  String get themeModeSystem => 'Системная';

  @override
  String get themeModeLight => 'Светлая';

  @override
  String get themeModeDark => 'Тёмная';

  @override
  String get themePresetsLabel => 'Пресеты';

  @override
  String get themePresetDefault => 'По умолчанию';

  @override
  String get themePresetOcean => 'Океан';

  @override
  String get themePresetSunset => 'Закат';

  @override
  String get themePresetAmethyst => 'Аметист';

  @override
  String get themePresetGraphite => 'Графит';

  @override
  String get themePresetRose => 'Роза';
}
