import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/db/database.dart';
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
  /// и меняет состояние, D-36: будущая автосинхронизация «при запуске»
  /// тоже будет читать этот стейт на старте).
  Future<void> load() async {
    state = await ref.read(rateSyncPreferencesStoreProvider).readEnabled();
  }
}

/// Контроллер синхронизации курсов: запуск обновления из настроек
/// (шаг 2) и будущая автосинхронизация. Состояние — флаг идущего запроса
/// (кнопка крутится); исход последнего запуска поднимается возвращаемым
/// значением, как у `UpdateController.checkNow`.
class RateSyncController extends Notifier<RateSyncState> {
  @override
  RateSyncState build() => const RateSyncState();

  RateSyncService get _service => ref.read(rateSyncServiceProvider);

  /// Запуск синхронизации из UI (кнопка «Обновить сейчас», шаг 2).
  ///
  /// Фича выключена — [RateSyncDisabled] без сетевых вызовов (opt-in, D-36).
  /// Повторный вызов во время идущего запроса игнорируется с обычным
  /// исходом отключённого состояния: UI-кнопка в этот момент неактивна.
  Future<RateSyncResult> syncNow() async {
    if (!ref.read(rateSyncEnabledProvider)) {
      return const RateSyncDisabled();
    }
    if (state.syncing) {
      return const RateSyncDisabled();
    }
    state = const RateSyncState(syncing: true);
    try {
      final RateSyncResult result =
          await _service.syncNow(ref.read(currenciesDaoProvider));
      return result;
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
