import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/data/export/csv_import.dart';
import 'package:kopilka/features/settings/csv_import_controller.dart';
import 'package:kopilka/features/settings/csv_import_mapping_dialog.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Точка входа импорта CSV (пункт настроек «Импорт операций (CSV)»):
/// выбор файла → диалог маппинга → подтверждение с предупреждением merge
/// → запись к живой базе (бриф M4-шаг 3).
Future<void> runCsvImportFlow(BuildContext context, WidgetRef ref) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final CsvPickOutcome picked = await ref
      .read(csvImportControllerProvider.notifier)
      .pickDraft();
  if (!context.mounted) {
    return;
  }
  final CsvImportDraft? draft = switch (picked) {
    CsvPickCancelled() => null,
    CsvPickFailed(:final failure, :final line) => _reportPickFailure(
        context,
        l10n,
        failure,
        line,
      ),
    CsvPickLoaded(:final draft) => draft,
  };
  if (draft == null || !context.mounted) {
    return;
  }

  final CsvColumnMapping? mapping =
      await showCsvMappingDialog(context, draft: draft);
  if (mapping == null || !context.mounted) {
    return;
  }

  final bool confirmed =
      await _showCsvConfirmDialog(context, l10n, draft.rowCount);
  if (!confirmed || !context.mounted) {
    return;
  }

  final CsvImportOutcome outcome = await ref
      .read(csvImportControllerProvider.notifier)
      .importCsv(draft.csv, mapping);
  if (!context.mounted) {
    return;
  }
  switch (outcome) {
    case CsvImportCancelled():
      await showSnack(context, l10n.backupCancelled);
    case CsvImportSucceeded(:final imported):
      await showSnack(context, l10n.csvImportDone(imported));
    case CsvImportFailed(:final failure, :final line):
      await showSnack(context, csvImportFailureText(l10n, failure, line));
  }
}

/// Подтверждение записи: число операций и предупреждение, что операции
/// ДОБАВЛЯЮТСЯ к существующим, а дубли не отслеживаются (merge не upsert).
/// Свой диалог, а не showConfirmDialog: кнопка подтверждения —
/// «Импортировать», не «Удалить».
Future<bool> _showCsvConfirmDialog(
  BuildContext context,
  AppLocalizations l10n,
  int count,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(l10n.csvImportConfirmTitle),
      content: Text(l10n.csvImportMergeWarning(count)),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.csvImportConfirmAction),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Отказ чтения файла: тот же локализованный текст, что и у записи.
CsvImportDraft? _reportPickFailure(
  BuildContext context,
  AppLocalizations l10n,
  CsvImportFailure failure,
  int line,
) {
  showSnack(context, csvImportFailureText(l10n, failure, line));
  return null;
}

/// Локализованный текст отказа импорта по машиночитаемому виду слоя
/// (без стека и без «частичной загрузки»): номер строки — там, где слой
/// его даёт (invalidData/invalidFormat); дубли имён счетов/категорий
/// приходят с line 0 (D-40) — общий текст. Общий отказ файла (line 0) —
/// текст «нет строк данных» (Dz-2): теперь это единственный line-0-источник
/// invalidFormat — пустой файл и файл без строк данных.
String csvImportFailureText(
  AppLocalizations l10n,
  CsvImportFailure failure,
  int line,
) =>
    switch (failure) {
      CsvImportFailure.invalidFormat => line > 0
          ? l10n.errorCsvInvalidFormatLine(line)
          : l10n.errorCsvNoDataRows,
      CsvImportFailure.invalidMapping => l10n.errorCsvInvalidMapping,
      CsvImportFailure.invalidData => line > 0
          ? l10n.errorCsvInvalidDataLine(line)
          : l10n.errorCsvInvalidData,
    };
