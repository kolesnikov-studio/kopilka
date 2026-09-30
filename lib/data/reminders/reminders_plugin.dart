import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:timezone/timezone.dart' as tz;

import 'package:kopilka/core/scheduled_dates.dart';

/// Одна запись расписания напоминаний (D-83): id, дата и тексты (тексты —
/// константы механики; финальные — спека дизайнера шага D, шов оставлен).
class ReminderScheduleEntry {
  const ReminderScheduleEntry({
    required this.notificationId,
    required this.reminderDate,
    required this.title,
    required this.body,
    required this.payload,
  });

  /// Стабильный числовой id уведомления (stable id — D-83/§3-дух).
  final int notificationId;

  /// Дата напоминания (UTC-момент из БД, D-81/D-83).
  final DateTime reminderDate;

  /// Заголовок уведомления (константа механики до спеки шага D).
  final String title;

  /// Текст уведомления (константа механики до спеки шага D).
  final String body;

  /// Payload с ключом источника (`account:`/`debt:`).
  final String payload;
}

/// Шов над плагином уведомлений (D-83): тест-замок пересчёта расписания
/// подменяет реализацию фейком и проверяет расписание без платформенных
/// каналов (образец шва formClock — D-78, Б2).
abstract class RemindersPlugin {
  /// Инициализация плагина; [RemindersChannelError] — штатный платформенный
  /// отказ (канал/платформа не готовы), сервис глушит его как «напоминания
  /// недоступны», не роняя запуск (настройка не критична, D-43).
  Future<RemindersChannelError?> initialize();

  /// Перезаписывает расписание целиком (cancelAll + schedule каждого
  /// элемента). Идемпотентность пересчёта — в сервисе, плагин — исполнитель.
  Future<RemindersChannelError?> replaceAll(
    List<ReminderScheduleEntry> entries,
  );

  /// Показывает уведомление сейчас (просроченные — при ближайшем запуске,
  /// D-83). Отказ — [RemindersChannelError], как выше.
  Future<RemindersChannelError?> show(
    int notificationId, {
    required String title,
    required String body,
    required String payload,
  });
}

/// Отказ платформенного канала напоминаний: машиночитаемая причина
/// ('initialization' | 'replaceSchedule' | 'show' | 'permission').
class RemindersChannelError {
  const RemindersChannelError(this.reason);

  /// Причина отказа.
  final String reason;
}

/// Живая реализация шва над flutter_local_notifications (D-83: один пакет
/// на Android/Windows/Linux — обоснование в §1 ARCHITECTURE).
///
/// Особенности платформ (по исходникам плагина 22.3.1):
/// - Linux: планирование не поддерживается (нет scheduler API в Desktop
///   Notifications Specification) — zonedSchedule бросает UnimplementedError;
///   сервис принимает это: расписание на Linux остаётся пустым, а
///   просроченные напоминания всё равно показываются прямым show()
///   при ближайшем запуске (D-83);
/// - Windows: zonedSchedule поддержан; повторов нет — и не нужно
///   (расписание одноразовое, D-83);
/// - Android 13+: POST_NOTIFICATIONS запрашивается отдельно при включении
///   пользователем (RemindersService.ensurePermissions), initialize не
///   требует; режим планирования inexactAllowWhileIdle — без разрешения
///   SCHEDULE_EXACT_ALARM, «по мере необходимости» (D-54.6/D-83).
///
/// Таймзона: база tzdatabase в приложение не включается (вес + зависимость
/// flutter_timezone ради одного вызова — против принципа §1), поэтому
/// [tz.local] строится с фиксированным текущим смещением устройства.
/// Следствие: напоминания, расставленные до пересечения летнего времени,
/// после перевода часов уйдут на час — лечится штатным пересчётом при
/// следующем запуске; финальное поведение может уточнить спека шага D.
class FlNRemindersPlugin implements RemindersPlugin {
  FlNRemindersPlugin();

  final fln.FlutterLocalNotificationsPlugin _plugin =
      fln.FlutterLocalNotificationsPlugin();

  /// Локальная зона = текущее UTC-смещение устройства (см. док-класс).
  static tz.Location deviceLocation() {
    final DateTime now = DateTime.now();
    final Duration offset = now.timeZoneOffset;
    final bool negative = offset.isNegative;
    final int hours = offset.inHours.abs();
    final int minutes = offset.inMinutes.abs() % 60;
    final String sign = negative ? '-' : '+';
    return tz.Location(
      'device',
      const <int>[tz.minTime],
      const <int>[0],
      <tz.TimeZone>[
        tz.TimeZone(
          offset,
          isDst: false,
          abbreviation: 'UTC$sign${hours.toString().padLeft(2, '0')}:'
              '${minutes.toString().padLeft(2, '0')}',
        ),
      ],
    );
  }

  static fln.NotificationDetails get _details => const fln.NotificationDetails(
        android: fln.AndroidNotificationDetails(
          'reminders',
          'Kopilka reminders',
          channelDescription: 'Напоминания о процентах и долгах',
        ),
      );

  @override
  Future<RemindersChannelError?> initialize() async {
    try {
      final bool? ok = await _plugin.initialize(
        settings: const fln.InitializationSettings(
          // Иконка-ресурс шаблона проекта (android/app/src/main/res).
          android: fln.AndroidInitializationSettings('@mipmap/ic_launcher'),
          linux: fln.LinuxInitializationSettings(
            defaultActionName: 'Открыть Kopilka',
          ),
          // Стабильные строки приложения (guid — id канала уведомлений).
          windows: fln.WindowsInitializationSettings(
            appName: 'Kopilka',
            appUserModelId: 'io.github.kopilka.Kopilka',
            guid: 'F6D9A6E2-4C0B-4E3A-9E8F-1D2C3B4A5F6E',
          ),
        ),
      );
      if (ok == false) {
        return const RemindersChannelError('initialization');
      }
      return null;
    } on Exception {
      return const RemindersChannelError('initialization');
    }
  }

  @override
  Future<RemindersChannelError?> replaceAll(
    List<ReminderScheduleEntry> entries,
  ) async {
    try {
      await _plugin.cancelAll();
      final tz.Location location = deviceLocation();
      for (final ReminderScheduleEntry entry in entries) {
        // 09:00 локального времени устройства на дату напоминания (D-83).
        await _plugin.zonedSchedule(
          id: entry.notificationId,
          title: entry.title,
          body: entry.body,
          payload: entry.payload,
          scheduledDate: tz.TZDateTime.from(
            reminderMoment(entry.reminderDate),
            location,
          ),
          notificationDetails: _details,
          androidScheduleMode: fln.AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
      return null;
    } on Exception {
      // В том числе UnimplementedError → нет; Error (Linux) глушится
      // в RemindersService поверх этого метода (см. там).
      return const RemindersChannelError('replaceSchedule');
    }
  }

  @override
  Future<RemindersChannelError?> show(
    int notificationId, {
    required String title,
    required String body,
    required String payload,
  }) async {
    try {
      await _plugin.show(
        id: notificationId,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: _details,
      );
      return null;
    } on Exception {
      return const RemindersChannelError('show');
    }
  }
}
