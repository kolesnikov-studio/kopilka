// Общий харнесс виджет-тестов диалогов (S2): подмена БД на in-memory,
// RU-локаль, временные каталоги настроек и запуск KopilkaApp.
//
// Раньше _pumpDialogHarness (счета) и _pumpTransactionHarness (операции)
// дублировали этот помп почти дословно; третий копипаст prevention —
// форма перевода M3-шага 4. Размер окна — параметр: окно 600×1000
// оставлено тесту U9 (при показе ошибки валидации в узких 400px dropdown
// категории давал RenderFlex-overflow, не связанный с сутью теста —
// U9).
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/app.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Всё, что нужно тесту диалога: контейнер провайдеров, БД и строки локали.
class AppHarness {
  AppHarness(this.container, this.db, this.l10n);

  final ProviderContainer container;
  final AppDatabase db;
  final AppLocalizations l10n;
}

/// Запускает KopilkaApp над in-memory БД в RU-локали и окне [size],
/// возвращает харнесс с загруженными русскими строками.
///
/// Демонтаж регистрируется через addTearDown в порядке, важном для
/// fake_async (§7): сперва контейнер (останавливает потоки drift), потом БД;
/// каталоги настроек — во временном каталоге, их создание — реальный
/// файловый I/O, поэтому через runAsync.
Future<AppHarness> pumpDialogApp(
  WidgetTester tester, {
  Size size = const Size(400, 800),
  String tempDirPrefix = 'kopilka_dialog_test',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  // Локаль задаётся явно: платформенная по умолчанию в тестах — en, а строки
  // ниже берутся из загруженного экземпляра (эталон — сама локализация).
  tester.platformDispatcher.localeTestValue = const Locale('ru');
  tester.platformDispatcher.localesTestValue = const <Locale>[Locale('ru')];
  addTearDown(tester.platformDispatcher.clearLocaleTestValue);
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  final AppLocalizations l10n =
      await AppLocalizations.delegate.load(const Locale('ru'));

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await seedDefaultsIfEmpty(db);

  final Directory baseDir = (await tester.runAsync(
    () => Directory.systemTemp.createTemp(tempDirPrefix),
  ))!;
  addTearDown(() => tester.runAsync(() => baseDir.delete(recursive: true)));

  final ProviderContainer container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      autoBackupDirectoryStoreProvider
          .overrideWithValue(AutoBackupDirectoryStore(baseDirectory: baseDir)),
      updatePreferencesStoreProvider
          .overrideWithValue(UpdatePreferencesStore(baseDirectory: baseDir)),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const KopilkaApp(),
    ),
  );
  await tester.pumpAndSettle();
  return AppHarness(container, db, l10n);
}
