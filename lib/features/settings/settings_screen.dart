import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/data/export/backup_codec.dart';
import 'package:kopilka/data/export/backup_service.dart';
import 'package:kopilka/data/update/update_service.dart';
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
    final String backupDirectory = ref.watch(autoBackupDirectoryProvider);
    final bool autoCheckEnabled = ref.watch(autoUpdateCheckEnabledProvider);
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
          _SectionHeader(title: l10n.backupSectionTitle),
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
          const Divider(),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: Text(l10n.autoBackupTitle),
            subtitle: Text(
              backupDirectory.isEmpty
                  ? l10n.autoBackupDisabled
                  : backupDirectory,
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
  const _SectionHeader({required this.title});

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
