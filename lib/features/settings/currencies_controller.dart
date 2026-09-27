import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';

/// Живой список валют экрана «Валюты» (B1): базовая — первой, остальные
/// по коду (порядок DAO). Поток DAO сам перерисовывает экран при изменениях.
final currenciesListProvider = StreamProvider.autoDispose<List<Currency>>((
  ref,
) {
  return ref.watch(currenciesDaoProvider).watchAlive().map(
        (List<Currency> currencies) => <Currency>[
          // Базовая выносится вверх (B1: сортировка DAO по коду, базовая —
          // первая в UI); порядок остальных не трогаем.
          for (final Currency currency in currencies)
            if (currency.isBase) currency,
          for (final Currency currency in currencies)
            if (!currency.isBase) currency,
        ],
      );
});

/// Контроллер экрана «Валюты»: добавление, курс, удаление, смена базовой —
/// через DAO; отказы возвращаются как [Result] и объясняются UI снеком.
class CurrenciesController extends Notifier {
  @override
  void build() {}

  CurrenciesDao get _currencies => ref.read(currenciesDaoProvider);

  /// Добавляет валюту из встроенного ISO-списка (D-15: свободного ввода
  /// кода нет). Курс по умолчанию — 1 (B1.1: никаких «справочных» курсов,
  /// пользователь обязан ввести актуальный; предзаполнение подсвечивается).
  /// Воскрешение ранее удалённой валюты — штатный путь DAO (B1.4).
  Future<Result<Currency>> addCurrency(String code) async {
    final CurrencyInfo? info = currencyInfoByCode(code);
    if (info == null) {
      // Недостижимо по построению UI (выбор только из списка), но строка
      // защиты не даёт создать валюту вне справочника.
      return const Failure<Currency>(DataFailure.invalidInput);
    }
    try {
      final Currency currency = await _currencies.create(
        code: info.code,
        symbol: info.symbol,
      );
      return Success<Currency>(currency);
    } on DataValidationException catch (error) {
      return Failure<Currency>(error.kind);
    }
  }

  /// Меняет ручной курс к базовой (D-16). Базовую DAO не даст править
  /// смыслу записи; UI у базовой диалог и не открывает.
  Future<Result<Currency>> updateRate(String code, double rate) async {
    try {
      final Currency currency = await _currencies.updateCurrency(
        code,
        rateToBase: Value<double>(rate),
      );
      return Success<Currency>(currency);
    } on DataValidationException catch (error) {
      return Failure<Currency>(error.kind);
    }
  }

  /// Мягко удаляет валюту. Отказ currencyUsedByAccounts UI показывает
  /// снеком (B1: не глотать); до попытки UI объясняет отказ заранее
  /// счётчиком живых счетов.
  Future<Result<void>> deleteCurrency(String code) async {
    try {
      await _currencies.softDelete(code);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }

  /// Смена базовой с пересчётом курсов (D-20). Отказы: notFound;
  /// повторный запрос текущей базовой — идемпотентный успех DAO.
  Future<Result<void>> changeBase(String code) async {
    try {
      await _currencies.changeBase(code);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }

  /// Сколько живых счетов используют валюту (для B1.4: объяснение отказа
  /// удаления до попытки).
  Future<int> aliveAccountsUsing(String code) =>
      _currencies.aliveAccountsUsing(code);
}

final currenciesControllerProvider =
    NotifierProvider<CurrenciesController, void>(CurrenciesController.new);
