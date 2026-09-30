import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/data/reminders/reminders_binding.dart';
import 'package:kopilka/data/reminders/reminders_permission.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Состояние потока включения напоминаний (§7): результат тапа «Включить».
enum RemindersEnableOutcome {
  /// Включено (разрешение выдано или не требуется) — снек «включены».
  enabled,

  /// Разрешение не выдано (Android 13+) — настройка НЕ включается.
  permissionDenied,

  /// Пользователь скрыл баннер («Не сейчас») — до конца сессии.
  dismissed,
}

/// Контроллер включения/выключения напоминаний (§7): UI-поток вокруг швов
/// `RemindersService` (D-88). Запрос POST_NOTIFICATIONS — здесь, до
/// `setEnabled(true)` (D-88.1); отказ — настройка не включается. После
/// записи настройки расписание пересчитывается binding'ом сам: источники
/// (счета/долги) не менялись, поэтому запускаем пересчёт явно — та же
/// идемпотентная перезапись (D-83).
class RemindersToggleController extends Notifier<bool> {
  @override
  bool build() => false;

  /// Читает файл настроек (D-43): молча-дефолты §8 — битый/чужой JSON = выкл.
  Future<void> load() async {
    state = await ref.read(remindersServiceProvider).readEnabled();
  }

  /// Включение из UX-потока (баннер или настройки): запрос разрешения →
  /// `setEnabled(true)` → пересчёт расписания → снек. При отказе в
  /// разрешении настройка не включается (D-88.1/D-89 §7).
  Future<RemindersEnableOutcome> enable(BuildContext context) async {
    final bool granted =
        await ref.read(remindersPermissionProvider).request();
    if (!granted) {
      if (context.mounted) {
        await showSnack(
          context,
          AppLocalizations.of(context).remindersPermissionDenied,
        );
      }
      return RemindersEnableOutcome.permissionDenied;
    }
    await _setEnabled(true);
    if (context.mounted) {
      await showSnack(
        context,
        AppLocalizations.of(context).remindersEnabledSnackbar,
      );
    }
    return RemindersEnableOutcome.enabled;
  }

  /// Выключение (настройки): `setEnabled(false)` — расписание сбрасывается,
  /// без запросов (§7).
  Future<void> disable() => _setEnabled(false);

  Future<void> _setEnabled(bool enabled) async {
    await ref.read(remindersServiceProvider).setEnabled(enabled);
    state = enabled;
    // Пересчёт/сброс расписания — механика сама; при включении запускаем
    // явный пересчёт (изменение настройки — повод перезаписать расписание,
    // D-83), отказы канала сервис глушит.
    if (enabled) {
      await ref
          .read(remindersBindingProvider)
          .recalculateNow()
          .then((_) {}, onError: (Object _) {});
    }
  }
}

final remindersToggleProvider =
    NotifierProvider<RemindersToggleController, bool>(
  RemindersToggleController.new,
);

/// MaterialBanner-приглашение над секциями списка долгов (§7): показывается,
/// пока напоминания выключены и пользователь не скрыл баннер в этой сессии
/// («Не сейчас» — не отказ, без персиста, D-89). На Linux показывается так
/// же: подпись `remindersLinuxHint` видна до тапа — обманутого ожидания нет.
class RemindersBanner extends ConsumerStatefulWidget {
  const RemindersBanner({super.key});

  @override
  ConsumerState<RemindersBanner> createState() => _RemindersBannerState();
}

class _RemindersBannerState extends ConsumerState<RemindersBanner> {
  /// Скрытие до конца сессии (§7): без персиста отказа.
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    ref.read(remindersToggleProvider.notifier).load();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool enabled = ref.watch(remindersToggleProvider);
    if (enabled || _dismissed) {
      return const SizedBox.shrink();
    }
    final bool isLinux =
        Theme.of(context).platform == TargetPlatform.linux;
    return MaterialBanner(
      // Баннер над секциями списка (§7) — внутри тела экрана, не
      // ScaffoldMessenger: экраны-вкладки живут в своих ветках.
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.notifications_none),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l10n.remindersBannerTitle),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l10n.remindersBannerBody,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          if (isLinux)
            Text(
              l10n.remindersLinuxHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
        ],
      ),
      leading: const Icon(Icons.notifications_none),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            setState(() => _dismissed = true);
          },
          child: Text(l10n.remindersDismissAction),
        ),
        TextButton(
          onPressed: () async {
            await ref
                .read(remindersToggleProvider.notifier)
                .enable(context);
          },
          child: Text(l10n.remindersEnableAction),
        ),
      ],
    );
  }
}
