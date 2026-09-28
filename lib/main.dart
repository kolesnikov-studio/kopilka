import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/rate_sync_controller.dart';
import 'package:kopilka/features/settings/rate_sync_preferences.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // БД приложения открывается один раз на процесс и передаётся в Riverpod:
  // весь доступ к данным — только через провайдеры DAO (§2).
  final AppDatabase db = AppDatabase();

  // Справочники первого запуска: базовая валюта и системный предустановленный
  // набор категорий. Идемпотентно; падение означает негодную базу — падаем
  // сразу, а не работаем с пустым справочником.
  await seedDefaultsIfEmpty(db);  // Каталог поддержки приложения: файлы настроек (каталог автобэкапа,
  // настройка проверки обновлений, настройка синхронизации курсов).
  final Directory supportDirectory = await getApplicationSupportDirectory();
  final AutoBackupDirectoryStore autoBackupStore = AutoBackupDirectoryStore(
    baseDirectory: supportDirectory,
  );
  final UpdatePreferencesStore updatePreferences = UpdatePreferencesStore(
    baseDirectory: supportDirectory,
  );
  final RateSyncPreferencesStore rateSyncPreferences =
      RateSyncPreferencesStore(baseDirectory: supportDirectory);

  // Автобэкап при запуске (§4): тихий, последние 10 файлов. Не блокирует
  // запуск: ошибка файловой системы игнорируется.
  await runAutoBackupOnLaunch(store: autoBackupStore, db: db);

  // Проверка обновлений (§5): сетевой вызов только при включённой
  // пользователем настройке и не чаще раза в 7 дней; ошибка сети не мешает
  // запуску. Автосинхронизация курсов при запуске не выполняется (D-36,
  // §5.1: сетевой запрос — только по кнопке в настройках при включённой
  // opt-in-галочке; отдельное решение о запросе при старте — через
  // тимлида). Контейнер нужен, чтобы выполнить проверку до первого кадра:
  // её результат (диалог) подхватит экран настроек из состояния контроллера.
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider.overrideWithValue(autoBackupStore),
      updatePreferencesStoreProvider.overrideWithValue(updatePreferences),
      rateSyncPreferencesStoreProvider.overrideWithValue(rateSyncPreferences),
    ],
  );
  // Настройка синхронизации курсов (D-36) читается один раз при старте:
  // стейт глобальный, галочка в настройках его показывает и меняет.
  // Автосинхронизация при запуске не выполняется (§5.1) — сетевых вызовов
  // от этой фичи на старте нет.
  try {
    await container.read(rateSyncEnabledProvider.notifier).load();
  } on Exception {
    // Настройка не критична для запуска: при недоступном файле — выкл.
  }

  try {
    await container.read(updateControllerProvider.notifier).checkOnLaunch();
  } on Exception {
    // Запуск не зависит от сети (§5).
  }

  runZonedGuarded(
    () => runApp(
      UncontrolledProviderScope(
        container: container,
        child: const KopilkaApp(),
      ),
    ),
    (Object error, StackTrace stackTrace) {
      // Глобальные ошибки уже не роняют приложение; логирования нет —
      // телеметрии нет.
    },
  );
}
