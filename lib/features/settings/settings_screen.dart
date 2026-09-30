import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kopilka/app/routes.dart';
import 'package:kopilka/app/theme.dart';
import 'package:kopilka/app/theme_presets.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/data/export/backup_codec.dart';
import 'package:kopilka/data/export/backup_service.dart';
import 'package:kopilka/data/rates/rate_sync_service.dart';
import 'package:kopilka/data/update/update_service.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/features/debts/debts_reminders.dart';
import 'package:kopilka/features/categories/categories_controller.dart';
import 'package:kopilka/features/settings/csv_import_flow.dart';
import 'package:kopilka/features/settings/currencies_controller.dart';
import 'package:kopilka/features/settings/rate_sync_controller.dart';
import 'package:kopilka/features/settings/settings_controller.dart';
import 'package:kopilka/features/settings/update_controller.dart';
import 'package:kopilka/features/settings/update_offer_dialog.dart';
import 'package:kopilka/features/settings/update_preferences.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Настройки»: бэкапы, экспорт, каталог автобэкапа.
/// Секция обновлений — по ARCHITECTURE.md §5.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(autoBackupDirectoryProvider.notifier).load();
      ref.read(autoUpdateCheckEnabledProvider.notifier).load();
      // Напоминания (M6 шаг C, §7): текущее opt-in состояние из файла
      // настроек (D-43) — в состояние тумблера секции.
      ref.read(remindersToggleProvider.notifier).load();
      ref.read(updateOfferControllerProvider.notifier).load().then((_) {
        if (mounted) {
          _maybeShowUpdateOffer();
        }
      });
    });
  }

  Future<void> _handle(Future<SettingsOutcome> action) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SettingsOutcome outcome = await action;
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case SettingsCancelled():
        await showSnack(context, l10n.backupCancelled);
      case SettingsImported():
        await showSnack(context, l10n.importDone);
      case SettingsFileSaved():
        await showSnack(context, l10n.backupExported);
      case SettingsFailure(:final BackupFailure failure):
        await showSnack(context, _failureText(l10n, failure));
    }
  }

  String _failureText(AppLocalizations l10n, BackupFailure failure) =>
      switch (failure) {
        BackupFailure.invalidFormat => l10n.errorBackupInvalidFormat,
        BackupFailure.tooNew => l10n.errorBackupTooNew,
        BackupFailure.tooOld => l10n.errorBackupTooOld,
        BackupFailure.invalidData => l10n.errorBackupInvalidData,
      };

  Future<void> _showImportWarning() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool confirmed = await showConfirmDialog(
      context: context,
      title: l10n.importConfirmTitle,
      body: l10n.importReplaceWarning,
    );
    if (confirmed) {
      await _handle(ref.read(settingsControllerProvider.notifier).importJson());
    } else if (mounted) {
      await showSnack(context, l10n.backupCancelled);
    }
  }

  Future<void> _runAutoBackup() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AutoBackupResult? result = await ref
        .read(settingsControllerProvider.notifier)
        .runAutoBackupNow();
    if (result == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    switch (result) {
      case AutoBackupCreated(:final file, :final removedOld):
        await showSnack(
          context,
          '${l10n.autoBackupDone(file.path.split('/').last.split('\\').last)}'
          '${removedOld > 0 ? l10n.autoBackupRemovedOld(removedOld) : ''}',
        );
      case AutoBackupFailed(:final reason):
        await showSnack(context, l10n.autoBackupFailed(reason));
    }
  }

  Future<void> _pickAutoBackupDirectory() async {
    final String? directory = await ref
        .read(settingsControllerProvider.notifier)
        .pickDirectory();
    if (directory != null) {
      await ref
          .read(autoBackupDirectoryProvider.notifier)
          .setDirectory(directory);
    }
  }

  /// Диалог найденного обновления (§5): версия, чейнджлог, кнопка
  /// «Открыть страницу релиза». Скачивание/установка — руками пользователя.
  Future<void> _showUpdateDialog(UpdateAvailable update) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(l10n.updateFoundTitle(update.version)),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Text(
              update.changelog.isEmpty
                  ? l10n.updateFoundNoChangelog
                  : update.changelog,
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancelAction),
          ),
          FilledButton.icon(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final bool opened = await ref
                  .read(updateControllerProvider.notifier)
                  .openReleasePage(update.releaseUrl);
              if (!opened && mounted) {
                await showSnack(context, l10n.updateOpenFailed);
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.updateFoundOpenRelease),
          ),
        ],
      ),
    );
  }

  /// Ручная проверка обновлений (кнопка «Проверить сейчас»).
  Future<void> _checkForUpdates() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final UpdateActionOutcome outcome = await ref
        .read(updateControllerProvider.notifier)
        .checkNow();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case UpdateActionFound(:final update):
        await _showUpdateDialog(update);
      case UpdateActionUpToDate():
        await showSnack(context, l10n.updateUpToDate);
      case UpdateActionUnavailable():
        await showSnack(context, l10n.updateUnavailable);
    }
  }

  /// Ручная синхронизация курсов (кнопка «Обновить сейчас», D-36):
  /// исход [RateSyncResult] машиночитаемый — текст подбирает экран.
  Future<void> _syncRatesNow() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RateSyncResult outcome = await ref
        .read(rateSyncControllerProvider.notifier)
        .syncNow();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case RateSyncUpdated(:final updatedCount):
        await showSnack(
          context,
          updatedCount > 0
              ? l10n.rateSyncUpdated(updatedCount)
              : l10n.rateSyncUnchanged,
        );
      case RateSyncOffline():
        await showSnack(context, l10n.rateSyncOffline);
      case RateSyncFailed():
        await showSnack(context, l10n.rateSyncFailed);
      case RateSyncDisabled():
        await showSnack(context, l10n.rateSyncDisabled);
      case RateSyncAlreadyRunning():
        await showSnack(context, l10n.rateSyncAlreadyRunning);
    }
  }

  /// Предложение первого запуска (§5): показать один раз, до выбора.
  Future<void> _maybeShowUpdateOffer() async {
    if (!ref.read(updateOfferControllerProvider)) {
      return;
    }
    final bool enable = await showUpdateOfferDialog(context);
    await ref.read(updateOfferControllerProvider.notifier).dismiss();
    if (enable) {
      await ref
          .read(autoUpdateCheckEnabledProvider.notifier)
          .setEnabled(true);
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    // Скрытые категории (M5, D-54 идея 3): через select — пересборка настроек
    // только при смене самого счётчика, не на каждое изменение категорий.
    final int hiddenCount = ref.watch(
      hiddenSystemCategoriesProvider.select(
        (AsyncValue<List<Category>> state) => state.value?.length ?? 0,
      ),
    );
    final String backupDirectory = ref.watch(autoBackupDirectoryProvider);
    final bool autoCheckEnabled = ref.watch(autoUpdateCheckEnabledProvider);
    final bool rateSyncEnabled = ref.watch(rateSyncEnabledProvider);
    final bool rateSyncing = ref.watch(
      rateSyncControllerProvider.select((RateSyncState state) => state.syncing),
    );
    final bool checking = ref.watch(
      updateControllerProvider.select((UpdateCheckState state) => state.checking),
    );
    final UpdateAvailable? autoFound = ref.watch(
      updateControllerProvider
          .select((UpdateCheckState state) => state.foundUpdate),
    );
    if (autoFound != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(updateControllerProvider.notifier).consumeFoundUpdate();
        _showUpdateDialog(autoFound);
      });
    }

    return Scaffold(
      body: ListView(
        children: <Widget>[
          const SizedBox(height: 8),
          // Тема (M5, D-58): первая секция — самый наглядный эффект; пресет
          // и основа применяются ко всему приложению немедленно, без снека.
          _SectionHeader(title: l10n.themeSectionTitle),
          const ThemeSection(),
          const Divider(),
          // Валюты (B1): отдельный пункт-строка с счётчиком живых валют —
          // выше секции бэкапа; внутри экрана три активных действия.
          ListTile(
            leading: const Icon(Icons.currency_exchange),
            title: Text(l10n.currenciesScreenTitle),
            subtitle: Text(
              l10n.currenciesSettingsSubtitle(
                ref.watch(currenciesListProvider).value?.length ?? 0,
              ),
            ),
            onTap: () => context.push(AppRoutes.currencies),
          ),
          // Скрытые категории (M5, D-54 идея 3): пункт виден только когда
          // есть что возвращать — строка с «0 скрытых» была бы шумом.
          if (hiddenCount > 0)
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(l10n.hiddenCategoriesTitle),
              subtitle: Text(l10n.hiddenCategoriesTileSubtitle(hiddenCount)),
              onTap: () => context.push(AppRoutes.hiddenCategories),
            ),
          // Синхронизация курсов (D-36): opt-in галочка и ручная кнопка —
          // рядом с пунктом «Валюты», до секции бэкапа. Кнопка активна
          // только при включённой галочке и без идущего запроса (повторный
          // вызов во время запроса отклонён контроллером, §2).
          _SectionHeader(title: l10n.rateSyncSectionTitle),
          SwitchListTile(
            key: const ValueKey<String>('rateSyncEnabledTile'),
            secondary: const Icon(Icons.sync_outlined),
            title: Text(l10n.rateSyncEnabled),
            subtitle: Text(l10n.rateSyncEnabledHint),
            value: rateSyncEnabled,
            onChanged: (bool value) async {
              await ref.read(rateSyncEnabledProvider.notifier).setEnabled(value);
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                key: const ValueKey<String>('rateSyncNowButton'),
                onPressed:
                    (rateSyncEnabled && !rateSyncing) ? _syncRatesNow : null,
                icon: rateSyncing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(rateSyncing ? l10n.rateSyncing : l10n.rateSyncNow),
              ),
            ),
          ),
          const Divider(),
          // Секция «Напоминания» (M6 шаг C, §7): после «Синхронизации
          // курсов», тумблер + подписи времени и Linux-ограничения. Включение
          // из тумблера — тот же UX-поток с запросом разрешения (D-88.1);
          // выключение — setEnabled(false), без запросов.
          _SectionHeader(title: l10n.remindersSectionTitle),
          SwitchListTile(
            key: const ValueKey<String>('remindersToggleTile'),
            secondary: const Icon(Icons.notifications_none),
            title: Text(l10n.remindersToggle),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(l10n.remindersTimeNote),
                if (Theme.of(context).platform == TargetPlatform.linux)
                  Text(l10n.remindersLinuxHint),
              ],
            ),
            value: ref.watch(remindersToggleProvider),
            onChanged: (bool value) async {
              final RemindersToggleController controller =
                  ref.read(remindersToggleProvider.notifier);
              if (value) {
                await controller.enable(context);
              } else {
                await controller.disable();
              }
              if (mounted) {
                setState(() {});
              }
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: Text(l10n.exportJsonAction),
            onTap: () => _handle(
              ref.read(settingsControllerProvider.notifier).exportJson(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: Text(l10n.importJsonAction),
            onTap: _showImportWarning,
          ),
          ListTile(
            leading: const Icon(Icons.table_view_outlined),
            title: Text(l10n.exportCsvAction),
            onTap: () => _handle(
              ref.read(settingsControllerProvider.notifier).exportCsv(),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: Text(l10n.importCsvAction),
            onTap: () => runCsvImportFlow(context, ref),
          ),
          const Divider(),
          _SectionHeader(
            key: const ValueKey<String>('backupSection'),
            title: l10n.backupSectionTitle,
          ),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: Text(l10n.autoBackupTitle),
            subtitle: Text(
              backupDirectory.isEmpty
                  ? l10n.autoBackupDisabled
                  : backupDirectory,
              // U6: длинный путь Windows не должен растягивать строку —
              // ellipsis с показом начала пути.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _pickAutoBackupDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.autoBackupPickFolder),
                ),
                OutlinedButton.icon(
                  onPressed: backupDirectory.isEmpty ? null : _runAutoBackup,
                  icon: const Icon(Icons.backup_outlined),
                  label: Text(l10n.autoBackupRunNow),
                ),
              ],
            ),
          ),
          const Divider(),
          _SectionHeader(title: l10n.updateSectionTitle),
          SwitchListTile(
            secondary: const Icon(Icons.autorenew_outlined),
            title: Text(l10n.updateAutoCheck),
            subtitle: Text(l10n.updateAutoCheckHint),
            value: autoCheckEnabled,
            onChanged: (bool value) async {
              await ref
                  .read(autoUpdateCheckEnabledProvider.notifier)
                  .setEnabled(value);
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                onPressed: checking ? null : _checkForUpdates,
                icon: checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                label: Text(checking ? l10n.updateChecking : l10n.updateCheckNow),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
      );
}

/// Секция «Тема» (M5, D-58 §1): сегменты основы (Системная/Светлая/Тёмная)
/// и сетка 2 колонки карточек-пресетов. Тап применяет пресет немедленно;
/// выбранный — обводка seed + галочка. Снек «применено» не нужен —
/// перекрас всего приложения виден сразу (D-58).
class ThemeSection extends ConsumerWidget {
  const ThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeMode mode = ref.watch(themeModeProvider);
    final ThemePreset selected = ref.watch(
      themeProvider.select((ThemeState state) => state.preset),
    );
    final ThemeController controller = ref.read(themeProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: SegmentedButton<ThemeMode>(
            key: const ValueKey<String>('themeModeSegments'),
            segments: <ButtonSegment<ThemeMode>>[
              ButtonSegment<ThemeMode>(
                value: ThemeMode.system,
                icon: const Icon(Icons.brightness_auto_outlined),
                label: Text(l10n.themeModeSystem),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.light,
                icon: const Icon(Icons.light_mode_outlined),
                label: Text(l10n.themeModeLight),
              ),
              ButtonSegment<ThemeMode>(
                value: ThemeMode.dark,
                icon: const Icon(Icons.dark_mode_outlined),
                label: Text(l10n.themeModeDark),
              ),
            ],
            selected: <ThemeMode>{mode},
            onSelectionChanged: (Set<ThemeMode> selection) {
              // SegmentedButton пустым не бывает (emptySelectionAllowed
              // не включён), но guard не мешает.
              if (selection.isNotEmpty) {
                controller.setMode(selection.first);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(l10n.themePresetsLabel,
              style: Theme.of(context).textTheme.bodyMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // Сетка 2 колонки карточек-превью (D-58 §1): фиксированные
          // карточки ~72×48 — превью показывает честную палитру пресета,
          // а не растягивается на всю ширину окна.
          child: Column(
            children: <Widget>[
              for (int i = 0; i < themePresets.length; i += 2)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: <Widget>[
                      _ThemePresetCard(
                        key: ValueKey<String>(
                          'themePreset-${themePresets[i].id}',
                        ),
                        preset: themePresets[i],
                        selected: identical(themePresets[i], selected),
                        onSelected: () => controller.setPreset(themePresets[i]),
                      ),
                      if (i + 1 < themePresets.length) ...<Widget>[
                        const SizedBox(width: 8),
                        _ThemePresetCard(
                          key: ValueKey<String>(
                            'themePreset-${themePresets[i + 1].id}',
                          ),
                          preset: themePresets[i + 1],
                          selected: identical(themePresets[i + 1], selected),
                          onSelected: () =>
                              controller.setPreset(themePresets[i + 1]),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Карточка-превью пресета (D-58 §1): скруглённый прямоугольник ~72×48 —
/// фон surface пресета, кружок seed, полоска primaryContainer, строка
/// onSurface; подпись — имя пресета (l10n-ключ по id, D-58 §3).
class _ThemePresetCard extends StatelessWidget {
  const _ThemePresetCard({
    super.key,
    required this.preset,
    required this.selected,
    required this.onSelected,
  });

  final ThemePreset preset;

  final bool selected;

  final VoidCallback onSelected;

  /// Честные swatch-цвета пресета из §2 спеки (не текущей темы экрана):
  /// превью показывает палитру пресета, даже когда он не выбран.
  Color get _surface =>
      preset.lightSurface ?? ColorScheme.fromSeed(seedColor: preset.seed).surface;

  Color get _onSurface =>
      preset.lightOnSurface ??
      ColorScheme.fromSeed(seedColor: preset.seed).onSurface;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final BorderSide border = selected
        ? BorderSide(color: preset.seed, width: 2)
        : BorderSide(color: scheme.outlineVariant);
    // Имя пресета — l10n-ключ по id (D-56: id — не интерфейсный текст).
    final String name = switch (preset.id) {
      'default' => l10n.themePresetDefault,
      'ocean' => l10n.themePresetOcean,
      'sunset' => l10n.themePresetSunset,
      'amethyst' => l10n.themePresetAmethyst,
      'graphite' => l10n.themePresetGraphite,
      'rose' => l10n.themePresetRose,
      _ => preset.id,
    };

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: _surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: border,
      ),
      // ~72×48 по спеке (§1): фиксированный размер, содержимое внутри;
      // у выбранного — галочка в правом верхнем углу.
      child: SizedBox(
        width: 72,
        height: 48,
        child: Semantics(
          selected: selected,
          button: true,
          child: InkWell(
            onTap: onSelected,
            child: Stack(
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: preset.seed,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Container(
                              height: 5,
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: _onSurface),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Icon(
                      Icons.check_circle,
                      size: 14,
                      color: preset.seed,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
