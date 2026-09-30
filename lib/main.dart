import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/app/theme.dart';
import 'package:kopilka/data/attachments_storage.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/reminders/reminders_preferences.dart';
import 'package:kopilka/features/settings/rate_sync_controller.dart';
import 'package:kopilka/features/settings/rate_sync_preferences.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/theme_preferences.dart';
import 'package:kopilka/features/settings/update_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // БД приложения открывается один раз на процесс и передаётся в Riverpod:
  // весь доступ к данным — только через провайдеры DAO (§2).
  final AppDatabase db = AppDatabase();

  // Справочники первого запуска: базовая валюта и системный предустановленный
  // набор категорий. Идемпотентно; падение означает негодную базу — падаем
  // сразу, а не работаем с пустым справочником.
  await seedDefaultsIfEmpty(db);

  // Каталог поддержки приложения: файлы настроек (каталог автобэкапа,
  // настройка проверки обновлений, настройка синхронизации курсов).
  final Directory supportDirectory = await getApplicationSupportDirectory();

  // Хранилище файлов вложений (v6, D-63): каталог `attachments/` рядом с
  // `kopilka.sqlite` — как у файлов настроек (D-43).
  final AttachmentsStorage attachmentsStorage = AttachmentsStorage(
    rootDirectory: Directory(p.join(supportDirectory.path, 'attachments')),
  );
  final AutoBackupDirectoryStore autoBackupStore = AutoBackupDirectoryStore(
    baseDirectory: supportDirectory,
  );
  final UpdatePreferencesStore updatePreferences = UpdatePreferencesStore(
    baseDirectory: supportDirectory,
  );
  final RateSyncPreferencesStore rateSyncPreferences =
      RateSyncPreferencesStore(baseDirectory: supportDirectory);
  final ThemePreferencesStore themePreferences =
      ThemePreferencesStore(baseDirectory: supportDirectory);

  // Автобэкап при запуске (§4): тихий, последние 10 файлов. Не блокирует
  // запуск: ошибка файловой системы игнорируется.
  await runAutoBackupOnLaunch(store: autoBackupStore, db: db);

  // Проверка обновлений (§5): сетевой вызов только при включённой
  // пользователем настройке и не чаще раза в 7 дней; ошибка сети не мешает
  // запуску. Контейнер нужен, чтобы выполнить проверку до первого кадра:
  // её результат (диалог) подхватит экран настроек из состояния контроллера.
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      attachmentsStorageProvider.overrideWithValue(attachmentsStorage),
      autoBackupDirectoryStoreProvider.overrideWithValue(autoBackupStore),
      updatePreferencesStoreProvider.overrideWithValue(updatePreferences),
      rateSyncPreferencesStoreProvider.overrideWithValue(rateSyncPreferences),
      themePreferencesStoreProvider.overrideWithValue(themePreferences),
      remindersPreferencesStoreProvider.overrideWithValue(
        RemindersPreferencesStore(baseDirectory: supportDirectory),
      ),
    ],
  );
  // Тема (M5, D-58): пресет и основа читаются из файла настроек до runApp
  // — стейт нужен до первого кадра; сбой файла молча даёт значения по
  // умолчанию (§4 спеки, образец D-43).
  try {
    await container.read(themeProvider.notifier).load();
  } on Exception {
    // Тема не критична для запуска: при недоступном файле — дефолт.
  }
  // Настройка синхронизации курсов (D-36) читается один раз при старте:
  // стейт глобальный, галочка в настройках его показывает и меняет.
  try {
    await container.read(rateSyncEnabledProvider.notifier).load();
  } on Exception {
    // Настройка не критична для запуска: при недоступном файле — выкл.
  }

  // Автосинхронизация курсов при запуске (D-36, M4-шаг 3): один тихий
  // fire-and-forget вызов при включённой opt-in-галочке (иначе ноль
  // сетевых вызовов): без снеков и без UI, исходы сети/источника сервис
  // уже перевёл в машиночитаемые значения (§2), непредвиденное падение
  // вызова проглатывается — запуск не зависит от сети (§5). Флаг занятости
  // и чтение настройки — внутри контроллера (syncOnLaunch): гонка
  // «запуск + кнопка» там же через AlreadyRunning.
  unawaited(
    container
        .read(rateSyncControllerProvider.notifier)
        .syncOnLaunch()
        .then((_) {}, onError: (Object _) {}),
  );

  // Механика напоминаний (M6, D-83): запускается после инициализации БД
  // и посева — пересчёт расписания при старте (opt-in: внутри сервиса
  // по файлу настроек) и при каждом изменении источников; это же закрывает
  // перезапись расписания после импорта бэкапа. Отказы канала/ФС глушит
  // сам сервис — запуск от уведомлений не зависит (D-43-дух). Подписка
  // живёт в контейнере и гасится при его закрытии (remindersBindingProvider).
  unawaited(
    container
        .read(remindersBindingProvider)
        .start()
        .then((_) {}, onError: (Object _) {}),
  );

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
