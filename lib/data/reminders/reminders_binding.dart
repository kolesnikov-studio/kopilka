import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';

// Связка механики напоминаний (M6/D-83) с живыми потоками DAO.
//
// Пересчёт расписания — при старте и при каждом изменении источников
// (живые счета и живые долги; D-81/D-83); это же закрывает перезапись
// расписания после импорта бэкапа (замена данных порождает события
// потоков drift). Жизненный цикл — контейнер провайдеров: закрытие
// контейнера гасит подписки (§7: контейнер раньше БД).
//
// Гонка «пересчёт ещё идёт — пришло новое изменение» не критична:
// пересчёт идемпотентен (полная перезапись расписания), последний
// вызов даёт верный итог; interleaving-вызовы лишь избыточно перепишут
// то же расписание.

/// Сервис напоминаний над opt-in настройкой и живым плагином (D-83).
final remindersServiceProvider = Provider<RemindersService>((ref) {
  return RemindersService(
    prefs: ref.watch(remindersPreferencesStoreProvider),
    plugin: FlNRemindersPlugin(),
  );
});

/// Запуск и держание пересчёта: start() подписывается на изменения
/// источников и возвращает управление после первого (стартового) пересчёта.
class RemindersBinding {
  RemindersBinding(this._ref, this._service);

  final Ref _ref;
  final RemindersService _service;
  final List<StreamSubscription<void>> _subscriptions =
      <StreamSubscription<void>>[];

  /// Разовый пересчёт вне подписок (M6 шаг C, §7): явный запуск после
  /// включения настройки пользователем — идемпотентная перезапись расписания
  /// (D-83). Отказы канала глушит сервис.
  Future<void> recalculateNow() => _service.recalculate(
        _ref.read(accountsDaoProvider),
        _ref.read(debtsDaoProvider),
      );

  Future<void> start() async {
    final AccountsDao accountsDao = _ref.read(accountsDaoProvider);
    final DebtsDao debtsDao = _ref.read(debtsDaoProvider);
    for (final Stream<void> changes in <Stream<void>>[
      accountsDao.watchAlive(),
      debtsDao.watchAlive(),
    ]) {
      _subscriptions.add(
        changes.listen(
          (_) => unawaited(
            _service
                .recalculate(
                  _ref.read(accountsDaoProvider),
                  _ref.read(debtsDaoProvider),
                )
                .then((_) {}, onError: (Object _) {}),
          ),
        ),
      );
    }
    await _service
        .recalculate(_ref.read(accountsDaoProvider), debtsDao)
        .then((_) {}, onError: (Object _) {});
  }

  void dispose() {
    for (final StreamSubscription<void> subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }
}

final remindersBindingProvider = Provider<RemindersBinding>((ref) {
  final RemindersBinding binding = RemindersBinding(
    ref,
    ref.watch(remindersServiceProvider),
  );
  ref.onDispose(binding.dispose);
  return binding;
});
