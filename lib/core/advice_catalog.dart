// Чек-лист советов-инсайтов (M6, D-84): «данные, не код» — по духу §8.е
// ARCHITECTURE. Новый совет = строка справочника + ключи l10n +
// дескриптор-функция, без смены схемы и правок существующих советов.
//
// Справочник живёт в core (машинный код + условия, не интерфейсный текст —
// граница D-23/D-58); заголовок/текст/действие берутся из .arb по
// l10n-ключам (EN с @description, RU без; шаг D).
//
// Признаки — линзы просмотра (D-16/D-18): ничего не кэшируем и не храним,
// объёмы персонального учёта малы. Сетевых вызовов нет (§5).
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';

/// Совет: id, l10n-ключи и дескриптор-условие (D-84).
class Advice {
  const Advice({
    required this.id,
    required this.titleKey,
    required this.bodyKey,
    required this.actionKey,
    required this.descriptor,
  });

  /// Стабильный машинный id совета (после выпуска не переименовывается —
  /// прецедент D-55.3/D-58: id — константа-имя).
  final String id;

  /// l10n-ключи заголовка/текста/действия (тексты — шаг D).
  final String titleKey;
  final String bodyKey;
  final String actionKey;

  /// Условие показа: истинно на живых потоках DAO (D-84).
  final AdviceDescriptor descriptor;
}

/// Критерий «подходящего» счёта для совета о неснижаемом остатке (D-84).
///
/// Порог и критерий — решение дизайнера шага D (спека), механике порог
/// не зашит: дескриптор — параметр (бриф «Не делать»). [Advice.suitability]
/// подставляет фактический критерий при сборке справочника.
typedef AccountSuitability = bool Function(Account account, int balanceMinor);

/// Проверка показа совета: истина на живых потоках DAO (D-84).
typedef AdviceDescriptor = Future<bool> Function(
  AccountsDao accountsDao,
  DebtsDao debtsDao,
);

/// Значение по умолчанию: критерий не задан дизайнером (шаг D) — совет
/// не показывается никому (честное «нет решения», а не чужой порог).
bool noSuitability(Account account, int balanceMinor) => false;

/// Оценки живых счетов с балансами — вход дескриптора (линза D-16/D-18:
/// считается на лету, без кэша).
Future<List<AccountBalance>> aliveBalances(AccountsDao accountsDao) =>
    accountsDao.watchBalances().first;

/// Первый совет — «неснижаемый остаток и проценты» (D-54.10/D-84):
/// карточка появляется, когда среди живых счетов есть подходящий под
/// неснижаемый остаток счёт без флага накопительного (интересная дата
/// NULL = обычный счёт, D-81), с действием «создать накопительный счёт».
///
/// Дескриптор принимает критерий «подходящего» [suitability] параметром:
/// порог выбирает дизайнер шага D, механике порог не зашит (бриф).
Future<bool> minBalanceAdviceDescriptor(
  AccountsDao accountsDao,
  DebtsDao debtsDao, {
  required AccountSuitability suitability,
}) async {
  final List<AccountBalance> balances = await aliveBalances(accountsDao);
  return balances.any(
    (AccountBalance entry) =>
        entry.account.interestReminderDate == null &&
        suitability(entry.account, entry.balanceMinor),
  );
}

/// Критерий дизайнера шага D (D-92): подходящий счёт — с любой лежащей
/// суммой (`balanceMinor > 0`). Абсолютный порог отвергнут спекой §4:
/// многовалютность потребовала бы конвертации ради одного порога.
/// Совет скрыт в UI, пока жив накопительный счёт (фильтр карточки,
/// D-92.2) — дескриптор остаётся истинным по D-84, UI потребляет.
bool positiveBalanceSuitability(Account account, int balanceMinor) =>
    balanceMinor > 0;

/// Чек-лист советов (D-84): константный справочник.
///
/// Шаг D (D-92) подставил критерий дизайнера [positiveBalanceSuitability]
/// правкой дескриптора — «данные, не код», §8.е (шов справочника
/// оставлял [noSuitability] до спеки).
const List<Advice> adviceCatalog = <Advice>[
  Advice(
    id: 'min-balance-interest',
    titleKey: 'adviceMinBalanceTitle',
    bodyKey: 'adviceMinBalanceBody',
    actionKey: 'adviceMinBalanceAction',
    descriptor: _minBalanceAdviceDesigner,
  ),
];

Future<bool> _minBalanceAdviceDesigner(
  AccountsDao accountsDao,
  DebtsDao debtsDao,
) => minBalanceAdviceDescriptor(
  accountsDao,
  debtsDao,
  suitability: positiveBalanceSuitability,
);

/// Советы, показываемые сейчас: дескриптор истинен на живых потоках
/// (D-84). Порядок — порядок справочника.
Future<List<Advice>> activeAdvices(
  AccountsDao accountsDao,
  DebtsDao debtsDao, {
  List<Advice> catalog = adviceCatalog,
}) async {
  final List<Advice> result = <Advice>[];
  for (final Advice advice in catalog) {
    if (await advice.descriptor(accountsDao, debtsDao)) {
      result.add(advice);
    }
  }
  return result;
}
