import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/rates/rate_sync_service.dart';
import 'package:kopilka/features/settings/rate_sync_preferences.dart';

// Контроллер синхронизации курсов (D-36, M4-шаг 1 — слой данных).
//
// Исходы — машиночитаемые [RateSyncResult]; тексты подбирает экран (шаг 2).
// UI не ловит try/catch (§2): все отказы сети и источника уже переведены
// сервисом в исходы.

/// Провайдер сервиса синхронизации; в тестах подменяется сервисом
/// с фейковым http-клиентом (шов как у [updateServiceProvider]).
final rateSyncServiceProvider = Provider<RateSyncService>(
  (ref) => RateSyncService(),
);

/// Настройка «синхронизировать курсы» (opt-in, D-36: по умолчанию выкл).
///
/// Персист в файл настроек — [RateSyncPreferencesStore] из
/// `rate_sync_preferences.dart` (по образцу `UpdatePreferencesStore`):
/// [load] читает файл (вызывается экраном при старте), [setEnabled] пишет.
/// До загрузки и до переключения состояние — выкл (D-36).
final rateSyncEnabledProvider = NotifierProvider<RateSyncEnabledController, bool>(
  RateSyncEnabledController.new,
);

class RateSyncEnabledController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Устанавливает настройку и сохраняет её в файл настроек.
  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await ref.read(rateSyncPreferencesStoreProvider).writeEnabled(enabled);
  }

  /// Загружает настройку из хранилища — один раз при старте приложения
  /// из `main` (хранилище там создано; экран настройки только показывает
  /// и меняет состояние, D-36: автосинхронизация «при запуске» — шаг 3 —
  /// читает этот же стейт на старте).
  Future<void> load() async {
    state = await ref.read(rateSyncPreferencesStoreProvider).readEnabled();
  }
}

/// Контроллер синхронизации курсов: ручной запуск из настроек (шаг 2)
/// и автосинхронизация при запуске приложения (шаг 3). Состояние — флаг
/// идущего запроса (крутится кнопка; автозапуск гоняет тот же флаг —
/// гонка «запуск + кнопка» попадает в [RateSyncAlreadyRunning], D-42.в);
/// исход последнего запуска поднимается возвращаемым значением, как у
/// `UpdateController.checkNow`.
class RateSyncController extends Notifier<RateSyncState> {
  @override
  RateSyncState build() => const RateSyncState();

  RateSyncService get _service => ref.read(rateSyncServiceProvider);

  /// Запуск синхронизации из UI (кнопка «Обновить сейчас», шаг 2).
  ///
  /// Фича выключена — [RateSyncDisabled] без сетевых вызовов (opt-in, D-36).
  /// Повторный вызов во время идущего запроса — [RateSyncAlreadyRunning]
  /// (D-42.в): UI-кнопка в этот момент неактивна, исход различает
  /// «уже идёт» и «фича выключена» вместо ложного снека об отключённой фиче.
  Future<RateSyncResult> syncNow() {
    if (!ref.read(rateSyncEnabledProvider)) {
      return Future<RateSyncResult>.value(const RateSyncDisabled());
    }
    return _runSync(() => _service.syncNow(ref.read(currenciesDaoProvider)));
  }

  /// Автосинхронизация при запуске приложения (шаг 3, D-36): один тихий
  /// вызов [RateSyncService.syncForBase] с базовой из справочника — шов
  /// из D-42. Вызывается из `main` fire-and-forget: без снеков и без UI
  /// (пользователь увидит курсы на экранах), первый кадр вызов не
  /// блокирует. Включённость — по файлу настроек, как у
  /// `UpdateController.checkOnLaunch` (не по стейту галочки: на старте
  /// стейт может быть ещё не загружен, а файл — истина); при выключенной
  /// галочке — [RateSyncDisabled] без сетевых вызовов. Пустой справочник
  /// (до посева) — тихий отказ сети, как в [RateSyncService.syncNow].
  /// Флаг `syncing` общий с [syncNow]: нажатие кнопки во время
  /// автозапуска — [RateSyncAlreadyRunning], отдельной логики гонки не
  /// нужно.
  Future<RateSyncResult> syncOnLaunch() {
    return _runSync(() async {
      if (!await ref.read(rateSyncPreferencesStoreProvider).readEnabled()) {
        return const RateSyncDisabled();
      }
      final CurrenciesDao dao = ref.read(currenciesDaoProvider);
      final Currency? base = await dao.baseCurrency();
      return base == null
          ? const RateSyncOffline()
          : _service.syncForBase(dao, base.code);
    });
  }

  /// Общий ход обоих запусков: защита от повторного запуска (D-42.в) и
  /// флаг на время запроса. Флаг ставится синхронно до первого await —
  /// гонка ловится сразу после вызова.
  Future<RateSyncResult> _runSync(
    Future<RateSyncResult> Function() action,
  ) async {
    if (state.syncing) {
      return const RateSyncAlreadyRunning();
    }
    state = const RateSyncState(syncing: true);
    try {
      return await action();
    } finally {
      state = const RateSyncState();
    }
  }

  /// Применить готовый словарь курсов в единицах rate_to_base — «база за
  /// единицу валюты» (USD: 90 при базе RUB; НЕ единицы источника — их
  /// разворачивает сервис на сетевой границе, D-42): сеть не трогается,
  /// DAO — да. Базовая берётся из справочника; пустой справочник (до
  /// посева) — тихий отказ сети, как в [RateSyncService.syncNow].
  Future<RateSyncResult> applyRates(Map<String, double> rates) async {
    final Currency? base =
        await ref.read(currenciesDaoProvider).baseCurrency();
    if (base == null) {
      return const RateSyncOffline();
    }
    return _service.applyRates(
      ref.read(currenciesDaoProvider),
      rates,
      baseCode: base.code,
    );
  }
}

/// Состояние синхронизации: идёт ли запрос (шаг 2 крутит индикатор).
class RateSyncState {
  const RateSyncState({this.syncing = false});

  final bool syncing;
}

/// Провайдер контроллера синхронизации курсов.
final rateSyncControllerProvider =
    NotifierProvider<RateSyncController, RateSyncState>(RateSyncController.new);
