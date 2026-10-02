import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/months.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_plugin.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';
import 'package:kopilka/data/reminders/reminders_service.dart';
import 'package:kopilka/data/reminders/reminders_texts.dart';

// Связка механики напоминаний (M6/D-83) с живыми потоками DAO.
//
// Пересчёт расписания — при старте и при каждом изменении источников
// (живые счета и живые долги; D-81/D-83); это же закрывает перезапись
// расписания после импорта бэкапа (замена данных порождает события
// потоков drift). Оповещения о перерасходе (M7/D-118) живут в том же
// пересчёте: источники — прогресс бюджетов и план-факт, поэтому в
// подписках ещё два потока (они же ловят изменения операций и курсов).
// Жизненный цикл — контейнер провайдеров: закрытие контейнера гасит
// подписки (§7: контейнер раньше БД).
//
// Гонка «пересчёт ещё идёт — пришло новое изменение» не критична:
// пересчёт идемпотентен (полная перезапись расписания, дедуп оповещений),
// последний вызов даёт верный итог; interleaving-вызовы лишь избыточно
// перепишут то же расписание либо не покажут уже показанное.

/// Сервис напоминаний над opt-in настройкой и живым плагином (D-83);
/// тексты оповещений о перерасходе — черновые l10n-ключи (D-118).
final remindersServiceProvider = Provider<RemindersService>((ref) {
  return RemindersService(
    prefs: ref.watch(remindersPreferencesStoreProvider),
    plugin: FlNRemindersPlugin(),
    overBudgetBody:
        ({
          required String categoryName,
          required int remainingMinor,
          required int daysLeft,
        }) => overBudgetBodyFor(
          deviceLocalizations(),
          categoryName: categoryName,
          remainingMinor: remainingMinor,
          daysLeft: daysLeft,
        ),
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

  /// Пересчёт со всеми источниками: расписание и просроченные (D-83) плюс
  /// оповещения о перерасходе (D-118) — binding передаёт DAO бюджетов,
  /// планов и категорий.
  Future<void> _recalculate() => _service.recalculate(
    _ref.read(accountsDaoProvider),
    _ref.read(debtsDaoProvider),
    budgetsDao: _ref.read(budgetsDaoProvider),
    plansDao: _ref.read(plansDaoProvider),
    categoriesDao: _ref.read(categoriesDaoProvider),
  );

  /// Разовый пересчёт вне подписок (M6 шаг C, §7): явный запуск после
  /// включения настройки пользователем — идемпотентная перезапись расписания
  /// (D-83) и расчёт оповещений (D-118). Отказы канала глушит сервис.
  Future<void> recalculateNow() => _recalculate();

  Future<void> start() async {
    final AccountsDao accountsDao = _ref.read(accountsDaoProvider);
    final DebtsDao debtsDao = _ref.read(debtsDaoProvider);
    // Сигналы изменений для оповещений (D-118): прогресс бюджетов (читает
    // бюджеты, операции и курсы) и план-факт (планы, категории, операции) —
    // K меняется от каждой операции, показ немедленный, дедуп раз в сутки
    // гасит повторы. Месяц подписки — момент старта: триггер важнее окна,
    // сам пересчёт всегда считает по свежим часам.
    final DateTime monthMoment = monthStart(utcNow());
    final Stream<void> budgetChanges = _ref
        .read(budgetsDaoProvider)
        .watchProgress(moment: monthMoment);
    final Stream<void> planChanges = _ref
        .read(plansDaoProvider)
        .watchPlanVsFact(
          from: monthMoment,
          to: DateTime.utc(monthMoment.year, monthMoment.month + 13),
        );
    for (final Stream<void> changes in <Stream<void>>[
      accountsDao.watchAlive(),
      debtsDao.watchAlive(),
      budgetChanges,
      planChanges,
    ]) {
      _subscriptions.add(
        changes.listen(
          (_) => unawaited(
            _recalculate().then((_) {}, onError: (Object _) {}),
          ),
        ),
      );
    }
    await _recalculate().then((_) {}, onError: (Object _) {});
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
