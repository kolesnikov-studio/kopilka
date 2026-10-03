import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/money_format.dart';
import 'package:kopilka/data/db/dao/scheduled_transfers_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/reminders/reminders_texts.dart';
import 'package:kopilka/data/scheduled/scheduled_transfers_service.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

// Связка исполнения отложенных переводов (M7/D-119) с живыми данными:
// исполнение — при старте приложения и после любой записи в
// scheduled_transfers (новые pending-строки; это же закрывает исполнение
// после импорта бэкапа — замена данных порождает события потока drift).
// Жизненный цикл — контейнер провайдеров: закрытие контейнера гасит
// подписку (§7: контейнер раньше БД).
//
// Сам исполняющий код пишет в scheduled_transfers (markExecuted) — подписка
// получит и это событие: следующий проход увидит пустой список назревших
// и завершится no-op (идемпотентность D-119), сходимость гарантирована.

/// Сервис исполнения над живыми DAO (D-119); уведомление «исполнен
/// отложенный перевод» — через RemindersService при общем opt-in (D-83).
/// Тексты шага D (D-130 §2): заголовок — единый `reminderTitle`, тело —
/// `scheduledTransferExecutedBody` с деталями: сумма списания в валюте
/// счёта списания (не в базовой — это другой шов, D-118) и имя счёта
/// зачисления, прочитанные здесь же через AccountsDao/справочник валют.
final scheduledTransfersServiceProvider = Provider<ScheduledTransfersService>((
  ref,
) {
  return ScheduledTransfersService(
    db: ref.watch(appDatabaseProvider),
    scheduledDao: ref.watch(scheduledTransfersDaoProvider),
    transactionsDao: ref.watch(transactionsDaoProvider),
    onExecuted: (ScheduledTransfer transfer) async {
      final AppLocalizations l10n = deviceLocalizations();
      final List<Account> accounts = await ref
          .read(accountsDaoProvider)
          .watchAlive()
          .first;
      Account? from;
      Account? to;
      for (final Account account in accounts) {
        if (account.id == transfer.accountId) {
          from = account;
        }
        if (account.id == transfer.targetAccountId) {
          to = account;
        }
      }
      // Счёт мог быть удалён после исполнения (D-122.б блокирует только
      // живые строки) — пустые символ/код не роняют уведомление.
      final Currency? currency = from == null
          ? null
          : await ref.read(currenciesDaoProvider).findAlive(from.currencyCode);
      final String amount = formatMoneyMinor(
        transfer.amountMinor,
        symbol: currency?.symbol ?? (from?.currencyCode ?? ''),
        locale: l10n.localeName,
        exponent: currencyExponentByCode(from?.currencyCode ?? ''),
      );
      await ref
          .read(remindersServiceProvider)
          .showNow(
            payload: '$scheduledTransferSource${transfer.id}',
            title: l10n.reminderTitle,
            body: l10n.scheduledTransferExecutedBody(amount, to?.name ?? '…'),
          );
    },
  );
});

/// Запуск и держание исполнения: start() подписывается на изменения
/// отложенных переводов и возвращает управление после первого прохода.
class ScheduledTransfersBinding {
  ScheduledTransfersBinding(this._ref, this._service);

  final Ref _ref;
  final ScheduledTransfersService _service;
  final List<StreamSubscription<void>> _subscriptions =
      <StreamSubscription<void>>[];

  Future<void> start() async {
    final ScheduledTransfersDao dao = _ref.read(scheduledTransfersDaoProvider);
    _subscriptions.add(
      dao.watchAlive().listen(
        (_) => unawaited(
          _service.executeDue().then((_) {}, onError: (Object _) {}),
        ),
      ),
    );
    await _service.executeDue().then((_) {}, onError: (Object _) {});
  }

  void dispose() {
    for (final StreamSubscription<void> subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }
}

final scheduledTransfersBindingProvider = Provider<ScheduledTransfersBinding>((
  ref,
) {
  final ScheduledTransfersBinding binding = ScheduledTransfersBinding(
    ref,
    ref.watch(scheduledTransfersServiceProvider),
  );
  ref.onDispose(binding.dispose);
  return binding;
});
