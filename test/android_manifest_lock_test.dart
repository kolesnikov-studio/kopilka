// Замок на Android-манифест (D-111, находки A и D).
//
// Без receiver'ов плагина в манифесте приложения AlarmManager будильников
// flutter_local_notifications срабатывает «в пустоту»: уведомление по
// расписанию (zonedSchedule) не приходит никогда, зелёная сборка этого
// не показывает. Тест читает манифест как файл и краснеет, если из
// него пропали receiver'ы или разрешение на перепланирование после
// перезагрузки; POST_NOTIFICATIONS приходит из манифеста самого
// плагина (при слиянии манифестов) — проверяем его там, чтобы апгрейд
// плагина не потерял разрешение молча.
//
// Текст receiver'ов — из README плагина flutter_local_notifications
// 22.3.1, раздел «Gradle setup», строки 384–393.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android-манифест приложения (относительно корня пакета — оттуда
/// flutter test гоняет тесты).
final File _appManifest = File('android/app/src/main/AndroidManifest.xml');

/// Корень пакета [name] из .dart_tool/package_config.json: rootUri
/// относителен к .dart_tool/ для path-зависимостей и абсолютен
/// (file://…) для пакетов из pub-cache, resolveUri обрабатывает оба.
String _packageRoot(String name) {
  final Map<String, dynamic> packageConfig = jsonDecode(
    File('.dart_tool/package_config.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final Map<String, dynamic> entry =
      (packageConfig['packages'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (Map<String, dynamic> package) => package['name'] == name,
            orElse: () => throw StateError('Пакет $name нет в package_config'),
          );
  return Directory('.dart_tool').uri
      .resolveUri(Uri.parse(entry['rootUri'] as String))
      .toFilePath();
}

String _manifestOf(String packageRoot) =>
    '$packageRoot${Platform.pathSeparator}android${Platform.pathSeparator}src'
    '${Platform.pathSeparator}main${Platform.pathSeparator}AndroidManifest.xml';

void main() {
  test('манифест приложения читается', () {
    expect(
      _appManifest.existsSync(),
      isTrue,
      reason: 'android/app/src/main/AndroidManifest.xml должен существовать',
    );
  });

  test('в манифесте приложения объявлены оба receiver-а напоминаний', () {
    final String manifest = _appManifest.readAsStringSync();
    expect(
      manifest,
      contains(
        'android:name="com.dexterous.flutterlocalnotifications'
        '.ScheduledNotificationReceiver"',
      ),
      reason:
          'ScheduledNotificationReceiver показывает запланированное '
          'уведомление — без него будильник AlarmManager срабатывает в пустоту',
    );
    expect(
      manifest,
      contains(
        'android:name="com.dexterous.flutterlocalnotifications'
        '.ScheduledNotificationBootReceiver"',
      ),
      reason:
          'ScheduledNotificationBootReceiver перепланирует напоминания '
          'после перезагрузки устройства и обновления приложения',
    );
  });

  test('у boot-receiver-а intent-filter на перезагрузку и обновление', () {
    final String manifest = _appManifest.readAsStringSync();
    for (final String action in <String>[
      'android.intent.action.BOOT_COMPLETED',
      'android.intent.action.MY_PACKAGE_REPLACED',
      'android.intent.action.QUICKBOOT_POWERON',
      'com.htc.intent.action.QUICKBOOT_POWERON',
    ]) {
      expect(
        manifest,
        contains('android:name="$action"'),
        reason: 'boot-receiver не поймает $action без action в intent-filter',
      );
    }
  });

  test('в манифесте приложения есть разрешение RECEIVE_BOOT_COMPLETED', () {
    final String manifest = _appManifest.readAsStringSync();
    expect(
      manifest,
      contains('android.permission.RECEIVE_BOOT_COMPLETED'),
      reason: 'без разрешения плагин не узнаёт о перезагрузке устройства',
    );
  });

  test('в манифесте плагина осталось разрешение POST_NOTIFICATIONS', () {
    final String pluginManifest = File(
      _manifestOf(_packageRoot('flutter_local_notifications')),
    ).readAsStringSync();
    expect(
      pluginManifest,
      contains('android.permission.POST_NOTIFICATIONS'),
      reason:
          'разрешение приходит в merged-манифест из манифеста '
          'flutter_local_notifications — его потерля ломает уведомления '
          'на Android 13+',
    );
  });
}
