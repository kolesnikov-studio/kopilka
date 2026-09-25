import 'package:flutter/material.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог предложения первого запуска (§5): включить автопроверку
/// обновлений или отложить. Возвращает true, если пользователь включил.
Future<bool> showUpdateOfferDialog(BuildContext context) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final bool? enable = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(l10n.updateOfferTitle),
      content: Text(l10n.updateOfferBody),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.updateOfferLater),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.updateOfferEnable),
        ),
      ],
    ),
  );
  return enable ?? false;
}
