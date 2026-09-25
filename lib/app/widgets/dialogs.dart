import 'package:flutter/material.dart';
import 'package:kopilka/app/widgets/error_localization.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Диалог подтверждения (в M1 — удаление). Возвращает true, если пользователь
/// подтвердил действие.
Future<bool> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.deleteAction),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Показывает локализованное объяснение отказа слоя данных.
///
/// UI обязан объяснять пользователю отказы DAO (M1: удаление — только
/// soft delete и запрещено при связанных живых данных).
Future<void> showDataFailureSnack(
  BuildContext context,
  DataFailure failure,
) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return showSnack(context, localizedError(l10n, failure));
}

/// Показывает текстовое уведомление внизу экрана.
Future<void> showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  return Future<void>.value();
}
