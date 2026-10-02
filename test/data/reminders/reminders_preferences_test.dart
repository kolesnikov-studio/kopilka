// Тесты персиста настроек напоминаний (M6, D-83) — reminders-preferences.json
// по образцу D-43 (rate-sync/theme preferences) с замками T-2 (D-48):
// битый JSON / не-словарь = «молча выкл», запись атомарна через хелпер §8.в.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';

void main() {
  late Directory directory;
  late RemindersPreferencesStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('kopilka_rem_prefs_test');
    store = RemindersPreferencesStore(baseDirectory: directory);
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  group('RemindersPreferencesStore (D-43, D-83)', () {
    test(
      'файла нет — настройка «выкл» (по умолчанию выключена, D-83)',
      () async {
        expect(await store.readEnabled(), isFalse);
      },
    );

    test('writeEnabled(true) пишет файл и readEnabled читает', () async {
      await store.writeEnabled(true);

      expect(await store.readEnabled(), isTrue);
      final File file = File(
        '${directory.path}${Platform.pathSeparator}reminders-preferences.json',
      );
      expect(file.existsSync(), isTrue);
      expect(jsonDecode(file.readAsStringSync()), <String, dynamic>{
        'enabled': true,
      });
    });

    test('writeEnabled(false) после true — снова выкл', () async {
      await store.writeEnabled(true);
      await store.writeEnabled(false);

      expect(await store.readEnabled(), isFalse);
    });

    test('битый JSON — «молча выкл» (замок T-2, D-48)', () async {
      File(
        '${directory.path}${Platform.pathSeparator}reminders-preferences.json',
      ).writeAsStringSync('{битый json');

      expect(await store.readEnabled(), isFalse);
    });

    test('JSON-не-словарь (список) — «молча выкл» (§8.в)', () async {
      File(
        '${directory.path}${Platform.pathSeparator}reminders-preferences.json',
      ).writeAsStringSync('[1, 2, 3]');

      expect(await store.readEnabled(), isFalse);
    });

    test('значение не-bool — «молча выкл»', () async {
      File(
        '${directory.path}${Platform.pathSeparator}reminders-preferences.json',
      ).writeAsStringSync('{"enabled": "yes"}');

      expect(await store.readEnabled(), isFalse);
    });
  });

  group('состояние дедупа оповещений о перерасходе (D-118)', () {
    test('старого файла без поля нет — пустая карта (необязательное поле)',
        () async {
      File(
        '${directory.path}${Platform.pathSeparator}reminders-preferences.json',
      ).writeAsStringSync('{"enabled": true}');

      expect(await store.readAlertLastShown(), isEmpty);
      // Старое поле при этом цело (расширение не ломает прежний формат).
      expect(await store.readEnabled(), isTrue);
    });

    test('карта переживает запись, настройка enabled не теряется', () async {
      await store.writeEnabled(true);
      await store.writeAlertLastShown(<String, String>{
        'budget:cat-1:2026-10': '2026-10-15',
      });

      expect(await store.readAlertLastShown(), <String, String>{
        'budget:cat-1:2026-10': '2026-10-15',
      });
      expect(await store.readEnabled(), isTrue);
    });

    test('поле не карта или значения не строки — пусто, без падения',
        () async {
      for (final String raw in <String>[
        '{"alert_last_shown": [1, 2]}',
        '{"alert_last_shown": {"key": 5}}',
        '{"alert_last_shown": "строка"}',
      ]) {
        File(
          '${directory.path}${Platform.pathSeparator}reminders-preferences.json',
        ).writeAsStringSync(raw);

        expect(await store.readAlertLastShown(), isEmpty, reason: raw);
      }
    });
  });
}
