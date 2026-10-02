import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/db/dao/scheduled_transfers_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/scheduled/scheduled_transfers_service.dart';

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
final scheduledTransfersServiceProvider = Provider<ScheduledTransfersService>((
  ref,
) {
  return ScheduledTransfersService(
    db: ref.watch(appDatabaseProvider),
    scheduledDao: ref.watch(scheduledTransfersDaoProvider),
    transactionsDao: ref.watch(transactionsDaoProvider),
    onExecuted: (ScheduledTransfer transfer) => ref
        .read(remindersServiceProvider)
        .showNow(
          payload: '$scheduledTransferSource${transfer.id}',
          body: scheduledTransferExecutedBody,
        ),
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
