import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/update/update_service.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Провайдер сервиса проверки обновлений; в тестах подменяется сервисом
/// с фейковым http-клиентом.
final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(),
);

/// Загрузчик текущей версии приложения. По умолчанию — платформенный
/// канал package_info_plus; тесты подменяют строкой (в чистых dart-тестах
/// канала нет).
final currentVersionLoaderProvider = Provider<Future<String> Function()>(
  (ref) => () async => (await PackageInfo.fromPlatform()).version,
);

/// Машиночитаемый исход ручной проверки — экран подбирает текст.
sealed class UpdateActionOutcome {
  const UpdateActionOutcome();
}

/// Обновление найдено: показать диалог с чейнджлогом и ссылкой.
class UpdateActionFound extends UpdateActionOutcome {
  const UpdateActionFound(this.update);

  final UpdateAvailable update;
}

/// Версия актуальна.
class UpdateActionUpToDate extends UpdateActionOutcome {
  const UpdateActionUpToDate();
}

/// Проверить не удалось (сеть, API).
class UpdateActionUnavailable extends UpdateActionOutcome {
  const UpdateActionUnavailable();
}

/// Контроллер проверки обновлений (§5): ручная проверка из настроек и
/// автопроверка раз в 7 дней при включённой настройке.
class UpdateController extends Notifier<UpdateCheckState> {
  @override
  UpdateCheckState build() => const UpdateCheckState(
        checking: false,
        checkingAutomatically: false,
      );

  UpdateService get _service => ref.read(updateServiceProvider);

  /// Текущая версия приложения (провайдер-загрузчик, см. выше).
  Future<String> get _currentVersion => ref.read(currentVersionLoaderProvider)();

  /// Ручная проверка (кнопка в настройках).
  Future<UpdateActionOutcome> checkNow() async {
    if (state.checking) {
      return const UpdateActionUnavailable();
    }
    state = const UpdateCheckState(
      checking: true,
      checkingAutomatically: false,
    );
    try {
      final String version = await _currentVersion;
      final UpdateCheckResult result =
          await _service.check(currentVersion: version);
      return switch (result) {
        UpdateFound(:final update) => UpdateActionFound(update),
        UpdateNotNeeded() => const UpdateActionUpToDate(),
        UpdateCheckOffline() => const UpdateActionUnavailable(),
        UpdateCheckFailed() => const UpdateActionUnavailable(),
      };
    } finally {
      state = const UpdateCheckState(
        checking: false,
        checkingAutomatically: false,
      );
    }
  }

  /// Автопроверка при запуске: выполняется только при включённой настройке
  /// и не раньше чем через 7 дней после предыдущей. Результат поднимает
  /// [state.foundUpdate] — экран показывает диалог; ошибка сети тихая
  /// (запуск не зависит от сети, §5).
  Future<void> checkOnLaunch({
    DateTime Function() clock = utcNow,
  }) async {
    if (state.checkingAutomatically) {
      return;
    }
    final UpdatePreferencesStore store =
        ref.read(updatePreferencesStoreProvider);
    final bool enabled = await store.readEnabled();
    if (!enabled) {
      return;
    }
    final DateTime? last = await store.readLastAutoCheck();
    final DateTime now = clock();
    if (!isAutoCheckDue(enabled: enabled, lastCheck: last, now: now)) {
      return;
    }
    state = const UpdateCheckState(
      checking: false,
      checkingAutomatically: true,
    );
    try {
      final String version = await _currentVersion;
      final UpdateCheckResult result =
          await _service.check(currentVersion: version);
      await store.writeLastAutoCheck(now);
      if (result is UpdateFound) {
        state = UpdateCheckState(
          checking: false,
          checkingAutomatically: false,
          foundUpdate: result.update,
        );
      } else {
        state = const UpdateCheckState(
          checking: false,
          checkingAutomatically: false,
        );
      }
    } on Exception {
      // Сеть недоступна: тихо, автопроверка повторится через 7 дней.
      state = const UpdateCheckState(
        checking: false,
        checkingAutomatically: false,
      );
    }
  }

  /// Экран показал диалог автопроверки — сбросить флаг.
  void consumeFoundUpdate() {
    state = UpdateCheckState(
      checking: state.checking,
      checkingAutomatically: state.checkingAutomatically,
    );
  }

  /// Открывает страницу релиза (§5: скачивание/установка — руками
  /// пользователя). Не удалось открыть — исход для снека.
  Future<bool> openReleasePage(String url) => launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
}

/// Состояние проверки обновлений.
class UpdateCheckState {
  const UpdateCheckState({
    required this.checking,
    required this.checkingAutomatically,
    this.foundUpdate,
  });

  /// Идёт ручная проверка (кнопка крутится).
  final bool checking;

  /// Идёт автопроверка при запуске (UI не блокирует).
  final bool checkingAutomatically;

  /// Найденное автопроверкой обновление (показать диалог и сбросить).
  final UpdateAvailable? foundUpdate;
}

/// Провайдер состояния проверки обновлений.
final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateCheckState>(
  UpdateController.new,
);
