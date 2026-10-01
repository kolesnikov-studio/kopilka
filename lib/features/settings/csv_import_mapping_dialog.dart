import 'package:flutter/material.dart';
import 'package:kopilka/data/export/csv_import.dart';
import 'package:kopilka/features/settings/csv_import_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Подпись поля импорта для выпадающих списков диалога маппинга.
String csvFieldLabel(AppLocalizations l10n, CsvField field) => switch (field) {
  CsvField.date => l10n.csvFieldDate,
  CsvField.type => l10n.csvFieldType,
  CsvField.account => l10n.csvFieldAccount,
  CsvField.amount => l10n.csvFieldAmount,
  CsvField.currency => l10n.csvFieldCurrency,
  CsvField.targetAccount => l10n.csvFieldTargetAccount,
  CsvField.targetAmount => l10n.csvFieldTargetAmount,
  CsvField.category => l10n.csvFieldCategory,
  CsvField.note => l10n.csvFieldNote,
};

/// Диалог сопоставления колонок CSV-файла полям импорта.
///
/// Состояние диалога локальное (бриф M4-шаг 3): привязка «колонка → поле»
/// правится выпадающими списками, дефолт — [csvMappingFromExportV03].
/// Клиентская валидация повторяет правила слоя (без дублей полей, все
/// обязательные, колонки существуют): с ошибкой кнопка «Продолжить»
/// неактивна. Слой данных всё равно проверит маппинг ещё раз (D-25).
///
/// Возвращает маппинг или null (отмена/дисмисс).
Future<CsvColumnMapping?> showCsvMappingDialog(
  BuildContext context, {
  required CsvImportDraft draft,
}) {
  return showDialog<CsvColumnMapping>(
    context: context,
    builder: (BuildContext dialogContext) => _CsvMappingDialog(draft: draft),
  );
}

class _CsvMappingDialog extends StatefulWidget {
  const _CsvMappingDialog({required this.draft});

  final CsvImportDraft draft;

  @override
  State<_CsvMappingDialog> createState() => _CsvMappingDialogState();
}

class _CsvMappingDialogState extends State<_CsvMappingDialog> {
  late final CsvColumnMapping _mapping = csvMappingFromExportV03();

  /// Текст ошибки маппинга или null, если подтверждение возможно.
  String? _problem(AppLocalizations l10n) {
    final List<int> indexes = _mapping.keys.toList()..sort();
    if (indexes.isNotEmpty && indexes.last >= widget.draft.header.length) {
      return l10n.csvMappingColumnMissing(indexes.last + 1);
    }
    final Set<CsvField> fields = <CsvField>{};
    for (final CsvField field in _mapping.values) {
      if (!fields.add(field)) {
        return l10n.csvMappingDuplicateField;
      }
    }
    const Set<CsvField> required = <CsvField>{
      CsvField.date,
      CsvField.type,
      CsvField.account,
      CsvField.amount,
      CsvField.currency,
    };
    final Set<CsvField> missing = required.difference(fields);
    if (missing.isNotEmpty) {
      final String names = missing
          .map((CsvField field) => csvFieldLabel(l10n, field))
          .join(', ');
      return l10n.csvMappingMissingRequired(names);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? problem = _problem(l10n);
    return AlertDialog(
      title: Text(l10n.csvImportMappingTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                l10n.csvMappingHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(l10n.csvImportRowCount(widget.draft.rowCount)),
              const SizedBox(height: 8),
              for (int i = 0; i < widget.draft.header.length; i++)
                _columnRow(l10n, i),
              if (problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    problem,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: problem == null
              ? () => Navigator.of(context).pop(Map<int, CsvField>.of(_mapping))
              : null,
          child: Text(l10n.csvMappingNextAction),
        ),
      ],
    );
  }

  Widget _columnRow(AppLocalizations l10n, int index) {
    final String cell = widget.draft.header[index].trim();
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            cell.isEmpty ? l10n.csvImportColumnName(index + 1) : cell,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownButton<CsvField?>(
          key: ValueKey<String>('csv-mapping-dropdown-$index'),
          value: _mapping[index],
          isDense: true,
          underline: const SizedBox.shrink(),
          items: <DropdownMenuItem<CsvField?>>[
            DropdownMenuItem<CsvField?>(
              value: null,
              child: Text(l10n.csvColumnUnused),
            ),
            for (final CsvField field in CsvField.values)
              DropdownMenuItem<CsvField?>(
                value: field,
                child: Text(csvFieldLabel(l10n, field)),
              ),
          ],
          onChanged: (CsvField? field) => setState(() {
            if (field == null) {
              _mapping.remove(index);
            } else {
              _mapping[index] = field;
            }
          }),
        ),
      ],
    );
  }
}
