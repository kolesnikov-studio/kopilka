import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/data/export/csv_import.dart';
import 'package:kopilka/data/providers.dart';

/// Исход шага выбора CSV-файла (до диалога маппинга).
sealed class CsvPickOutcome {
  const CsvPickOutcome();
}

/// Пользователь отменил диалог выбора файла.
class CsvPickCancelled extends CsvPickOutcome {
  const CsvPickCancelled();
}

/// Файл выбран и разобран: черновик готов для диалога маппинга.
class CsvPickLoaded extends CsvPickOutcome {
  const CsvPickLoaded(this.draft);

  final CsvImportDraft draft;
}

/// Файл не читается или не является CSV.
class CsvPickFailed extends CsvPickOutcome {
  const CsvPickFailed(this.failure, {required this.line});

  final CsvImportFailure failure;

  /// Номер строки файла (0 — проблема файла целиком).
  final int line;
}

/// Черновик импорта: текст файла и то, что нужно диалогу маппинга
/// (шапка файла и число строк данных). Текст нужен целиком: слой данных
/// ещё раз валидирует файл при записи (D-25), повторного разбора нет.
class CsvImportDraft {
  const CsvImportDraft({
    required this.csv,
    required this.header,
    required this.rowCount,
  });

  /// Текст выбранного файла.
  final String csv;

  /// Шапка файла (первая запись парсера) — подписи колонок в диалоге.
  final List<String> header;

  /// Число строк данных (для подтверждения перед записью).
  final int rowCount;
}

/// Исход импорта, доведённый до конца: что показать пользователю.
/// Образец — [SettingsOutcome]: тексты подбирает UI, отказы машиночитаемы.
sealed class CsvImportOutcome {
  const CsvImportOutcome();
}

/// Зарезервировано для симметрии исходов; контроллер его не возвращает.
class CsvImportCancelled extends CsvImportOutcome {
  const CsvImportCancelled();
}

/// Импорт прошёл: показать «Добавлено N операций».
class CsvImportSucceeded extends CsvImportOutcome {
  const CsvImportSucceeded({required this.imported});

  final int imported;
}

/// Отказ слоя данных: машиночитаемый вид для локализованного текста.
class CsvImportFailed extends CsvImportOutcome {
  const CsvImportFailed(this.failure, {required this.line});

  final CsvImportFailure failure;

  /// Номер строки файла; 0 — проблема файла/базы целиком (у invalidData
  /// так выражаются дубли имён счетов/категорий, D-40).
  final int line;
}

/// Контроллер импорта CSV (M4-шаг 3): файл выбирает [FilePicker], разбор
/// шапки — слой данных ([parseCsv]), запись — [importCsvFile] (merge к
/// живой базе). Отказы слоя — Result-исходы, UI без try/catch (§2).
class CsvImportController extends Notifier {
  @override
  void build() {
    // Состояния у контроллера нет: исходы возвращаются методами.
  }

  /// Выбор файла (.csv/.txt) и чтение как текста. Выбор отделён от разбора:
  /// тесты идут через [loadDraft] — FilePicker в тестах не мокается.
  Future<CsvPickOutcome> pickDraft() async {
    final PlatformFile? picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: <String>['csv', 'txt'],
    );
    if (picked == null || picked.path == null) {
      return const CsvPickCancelled();
    }
    final String csv;
    try {
      csv = await File(picked.path!).readAsString();
    } on IOException {
      return const CsvPickFailed(CsvImportFailure.invalidFormat, line: 0);
    }
    return loadDraft(csv);
  }

  /// Шов тестов и UI: черновик из текста файла, без файловой системы.
  /// Пустой файл (0 байт) и файл без строк данных (только шапка, Dz-2) —
  /// ранний отказ invalidFormat: маппинг и подтверждение «0 операций»
  /// лишь ложно обещали бы работу импорта (D-42.б — честный отказ дороже).
  CsvPickOutcome loadDraft(String csv) {
    final List<List<String>> rows;
    try {
      rows = parseCsv(csv);
    } on CsvImportException catch (error) {
      return CsvPickFailed(error.kind, line: error.line);
    }
    if (rows.isEmpty || rows.length == 1) {
      return const CsvPickFailed(CsvImportFailure.invalidFormat, line: 0);
    }
    return CsvPickLoaded(
      CsvImportDraft(csv: csv, header: rows.first, rowCount: rows.length - 1),
    );
  }

  /// Импорт в живую базу с маппингом из диалога (merge, дубли не
  /// отслеживаются — предупреждение UI показывает до записи).
  Future<CsvImportOutcome> importCsv(
    String csv,
    CsvColumnMapping mapping,
  ) async {
    try {
      final CsvImportResult result = await importCsvFile(
        ref.read(appDatabaseProvider),
        csv: csv,
        mapping: mapping,
      );
      return CsvImportSucceeded(imported: result.imported);
    } on CsvImportException catch (error) {
      return CsvImportFailed(error.kind, line: error.line);
    }
  }
}

final csvImportControllerProvider = NotifierProvider<CsvImportController, void>(
  CsvImportController.new,
);
