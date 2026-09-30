import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;

/// Шов запроса Android-разрешения POST_NOTIFICATIONS (D-88.1): запрос —
/// в UX-потоке включения шага C, НЕ в `setEnabled` (решение приёмки D-88).
/// Отдельный шов — чтобы виджет-тесты потока включения не дёргали
/// платформенный канал (§7): в тестах подменяется фейком.
abstract class RemindersPermission {
  /// Запрашивает разрешение; true — выдано. На платформах без разрешения
  /// (Windows/Linux, Android < 13) — true без запроса.
  Future<bool> request();
}

/// Живая реализация над плагином: Android 13+ — системный диалог,
/// ответ платформы; Windows/Linux — разрешения нет, true.
class FlNRemindersPermission implements RemindersPermission {
  @override
  Future<bool> request() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      // Windows/Linux: разрешения нет — «запрос» считается выданным
      // (D-88.1/D-83).
      return true;
    }
    // Android: через типизированный фасад плагина (D-83: тот же пакет).
    final fln.FlutterLocalNotificationsPlugin plugin =
        fln.FlutterLocalNotificationsPlugin();
    final bool? granted =
        await plugin
            .resolvePlatformSpecificImplementation<
              fln.AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
    return granted ?? false;
  }
}

/// Провайдер шва; в тестах подменяется фейком.
final remindersPermissionProvider = Provider<RemindersPermission>(
  (ref) => FlNRemindersPermission(),
);
