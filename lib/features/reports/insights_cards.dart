import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kopilka/core/advice_catalog.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/accounts/account_form_dialog.dart';
import 'package:kopilka/features/insights/insights_providers.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

// Карточки дашборда M6-шага D (спека §3–§4, D-92): напоминание о
// процентах по накопительному счёту и совет «неснижаемый остаток».
// Триггеры — живые потоки DAO (линзы без кэша, D-16/D-18); скрытие
// «Не сейчас» — только в памяти до конца сессии (D-89.2); loading/
// error/«нет условий» — карточка не рисуется (errorGeneric не заводим,
// дашборд не роняем).

/// Дата напоминания из UTC-строки колонки v7; битая строка — нет даты
/// (та же терпимость схемы, что в RemindersService — напоминание молча
/// не показывается).
DateTime? _parseUtcDate(String? iso) {
  if (iso == null || iso.isEmpty) {
    return null;
  }
  return DateTime.tryParse(iso)?.toUtc();
}

/// Дата напоминания ≤ сегодня по календарной дате UTC (спека §3):
/// напоминание живо весь сегодняшний день UTC, уходит при переносе
/// даты. Независимо от opt-in напоминаний — экранный канал и честный
/// fallback Linux (D-88.3: расписание не ставится, карточка работает всюду).
bool _isDueTodayOrEarlier(DateTime date, DateTime nowUtc) =>
    !date.isAfter(DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day, 23, 59,
        59, 999));

/// Живые счёта накопительные с датой напоминания ≤ сегодня (UTC),
/// для карточки-напоминания (спека §3): линза над потоком
/// [AccountsDao.watchBalances] без хранения (D-16/D-18).
final interestReminderAccountsProvider =
    StreamProvider.autoDispose<List<AccountBalance>>((ref) {
  return ref.watch(accountsDaoProvider).watchBalances().map(
        (List<AccountBalance> rows) => rows
            .where((AccountBalance row) {
              final DateTime? date =
                  _parseUtcDate(row.account.interestReminderDate);
              return date != null && _isDueTodayOrEarlier(date, utcNow());
            })
            .toList(),
      );
});

/// Есть ли живой накопительный счёт — UI-фильтр совета (спека §4,
/// D-92.2): совет скрыт, пока жив хотя бы один накопительный счёт,
/// иначе текст и CTA «создать накопительный счёт» лгут владельцу.
/// Дескриптор справочника не трогается (данные, не код, §8.е).
final hasSavingsAccountProvider = StreamProvider.autoDispose<bool>((ref) {
  return ref.watch(accountsDaoProvider).watchBalances().map(
        (List<AccountBalance> rows) => rows.any(
          (AccountBalance row) =>
              _parseUtcDate(row.account.interestReminderDate) != null,
        ),
      );
});

/// Первая карточка колонки «Отчётов», над балансом (спека §3): Card с
/// фоном `secondaryContainer`, тапабельна целиком. Содержимое — имя счёта
/// с самым ранним сроком + локальная дата; несколько счетов — надпись
/// «и ещё N». Тап — ветка «Счета» (дату правят в форме, карточка исчезает
/// по живому потоку). Кнопка «Не сейчас» — скрытие до конца сессии.
class InterestReminderCard extends ConsumerStatefulWidget {
  const InterestReminderCard({super.key});

  @override
  ConsumerState<InterestReminderCard> createState() =>
      _InterestReminderCardState();
}

class _InterestReminderCardState extends ConsumerState<InterestReminderCard> {
  /// Скрытие до конца сессии (D-89.2): без персиста отказа; вернётся
  /// в следующем запуске, пока дата не перенесена.
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<AccountBalance>? rows =
        ref.watch(interestReminderAccountsProvider).value;
    // Loading/error/нет условий — карточка не рисуется (спека §8).
    if (_dismissed || rows == null || rows.isEmpty) {
      return const SizedBox.shrink();
    }
    // Самый ранний срок (спека §3): сравнение UTC-моментов.
    AccountBalance earliest = rows.first;
    for (final AccountBalance row in rows) {
      final DateTime? candidate =
          _parseUtcDate(row.account.interestReminderDate);
      final DateTime? current =
          _parseUtcDate(earliest.account.interestReminderDate);
      if (candidate != null &&
          (current == null || candidate.isBefore(current))) {
        earliest = row;
      }
    }
    final DateTime? date =
        _parseUtcDate(earliest.account.interestReminderDate)?.toLocal();

    return Card(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.go('/accounts'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      l10n.dashboardInterestCardTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _dismissed = true),
                    child: Text(l10n.remindersDismissAction),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l10n.dashboardInterestCardBody(
                  earliest.account.name,
                  MaterialLocalizations.of(context).formatMediumDate(date!),
                ),
              ),
              if (rows.length > 1)
                Text(
                  l10n.dashboardInterestMore(rows.length - 1),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Вторая карточка колонки (спека §4): совет D-84 из
/// [activeAdvicesProvider] с UI-фильтром [hasSavingsAccountProvider].
/// Действие — форма счёта с преселектом тумблера «Накопительный» и
/// дефолтной даты (D-92.3); «Не сейчас» — скрытие до конца сессии
/// (D-89.2). loading/error/фильтр — карточка не рисуется.
class AdviceCard extends ConsumerStatefulWidget {
  const AdviceCard({super.key});

  @override
  ConsumerState<AdviceCard> createState() => _AdviceCardState();
}

class _AdviceCardState extends ConsumerState<AdviceCard> {
  /// Скрытие до конца сессии (D-89.2), без персиста.
  bool _dismissed = false;

  /// Тексты совета берутся из .arb по l10n-ключам дескриптора (D-84);
  /// пока справочник содержит один совет — ключи известны константно,
  /// совет вне известного набора не рисуем (честное отсутствие).
  static const String _knownAdviceId = 'min-balance-interest';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Advice>? advices = ref.watch(activeAdvicesProvider).value;
    final bool savingsAlive =
        ref.watch(hasSavingsAccountProvider).value ?? true;
    // Нет данных / нет активных советов / фильтр «есть накопительный» /
    // скрыто до конца сессии — карточка не рисуется (спека §8).
    if (_dismissed || advices == null || advices.isEmpty || savingsAlive) {
      return const SizedBox.shrink();
    }
    final Advice advice = advices.first;
    if (advice.id != _knownAdviceId) {
      return const SizedBox.shrink();
    }

    return Card(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.adviceMinBalanceTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _dismissed = true),
                  child: Text(l10n.remindersDismissAction),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(l10n.adviceMinBalanceBody),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () =>
                    showAccountFormDialog(context, savingsPreset: true),
                child: Text(l10n.adviceMinBalanceAction),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
