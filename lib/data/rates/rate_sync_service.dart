import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';

// Синхронизация курсов с интернетом (D-36): opt-in фича, обновление
// rate_to_base небазовых валют к базовой из открытого бесплатного источника.
//
// Ручной ввод курса остаётся офлайн-fallback: при недоступности сети сервис
// тихо отказывается с машиночитаемым исходом, курсы не трогаются —
// «остаются последние» (D-36). Схема БД не меняется; SQL — только в DAO.
//
// Тексты для пользователя не подбираются здесь: исход машиночитаемый,
// локализация — задача UI (шаг 2). Тестируется с фейковым http.Client.

/// Источник курсов: открытый бесплатный API без ключа и регистрации (D-36).
///
/// Выбор против frankfurter.dev: у frankfurter нет RUB и экзотических валют
/// (у нашего справочника 157 записей ISO, включая RUB — посев по умолчанию);
/// open.er-api.com отдаёт курсы ~160 валют к любой базовой одним запросом
/// без ключа. Схема ответа `{ "result": "success", "rates": { "CODE": 90.5 } }`.
///
/// Если источник переедет или поменяет схему — правки только здесь.
const String rateSyncApiUrl = 'https://open.er-api.com/v6/latest';

/// Таймаут сетевого запроса: молчаливый сервер не должен держать UI
/// (шаг 2) дольше этого времени; по таймауту — тихий отказ сети (D-36).
const Duration rateSyncTimeout = Duration(seconds: 10);

/// Исход запуска синхронизации (машиночитаемый, без текстов).
sealed class RateSyncResult {
  const RateSyncResult();
}

/// Курсы обновлены: число небазовых валют, чей rate_to_base перезаписан.
class RateSyncUpdated extends RateSyncResult {
  const RateSyncUpdated(this.updatedCount);

  final int updatedCount;
}

/// Сеть недоступна, таймаут или источник ответил не 2xx: курсы не тронуты
/// (D-36 — остаются последние).
class RateSyncOffline extends RateSyncResult {
  const RateSyncOffline();
}

/// Источник ответил, но формат неожиданный (не success, нет словаря rates,
/// не JSON) — не падаем, сообщаем как отказ.
class RateSyncFailed extends RateSyncResult {
  const RateSyncFailed();
}

/// Синхронизация отключена пользователем (opt-in, D-36): сетевых вызовов нет.
/// Галочка в настройках — шаг 2 (UI); до неё контроллер решает по состоянию.
class RateSyncDisabled extends RateSyncResult {
  const RateSyncDisabled();
}

/// Разбирает ответ источника в словарь «код → курс».
///
/// Возвращает null, если формат неожиданный: не `result: "success"`,
/// `rates` — не словарь конечных чисел или словарь пуст. Пустой `rates`
/// при «success» — признак сбоя источника: отчёт «обновлено 0» выглядел
/// бы успехом, а справочник в этом случае молча не обновился бы; отказ
/// честнее и оставляет курсы нетронутыми (D-36). Курс ≤ 0 отбрасывает
/// весь разбор: источник обязан отдавать положительные курсы, нулевые/
/// отрицательные значения — признак сломанного ответа (DAO отклонил бы
/// их сам, но частично применённый ответ оставил бы справочник
/// в полусостоянии).
Map<String, double>? parseRatesResponse(Object? decoded) {
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  if (decoded['result'] != 'success') {
    return null;
  }
  final Object? rates = decoded['rates'];
  if (rates is! Map<String, dynamic> || rates.isEmpty) {
    return null;
  }
  final Map<String, double> parsed = <String, double>{};
  for (final MapEntry<String, dynamic> entry in rates.entries) {
    final Object? value = entry.value;
    if (value is! num || value <= 0) {
      return null;
    }
    parsed[entry.key] = value.toDouble();
  }
  return parsed;
}

/// Сервис синхронизации курсов: загрузка курсов небазовых валют к базовой
/// и запись их через [CurrenciesDao]. Единственный сетевой вызов фичи;
/// телеметрии нет (D-36).
class RateSyncService {
  RateSyncService({http.Client? client, this.timeout = rateSyncTimeout})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Таймаут запроса (в тестах сокращается, чтобы не гонять время).
  final Duration timeout;

  /// Загружает курсы источника и записывает их в справочник.
  ///
  /// Базовая валюта не найдена (пустой справочник до посева) — тихий отказ
  /// сети: синхронизировать не к чему, а сетевой вызов за базой не нужен.
  Future<RateSyncResult> syncNow(CurrenciesDao dao) async {
    final Currency? base = await dao.baseCurrency();
    if (base == null) {
      return const RateSyncOffline();
    }
    return _sync(dao, base.code);
  }

  /// Синхронизация с известной базовой валютой: тот же цикл без повторного
  /// чтения справочника (контроллер передаёт код из состояния экрана).
  Future<RateSyncResult> syncForBase(CurrenciesDao dao, String baseCode) =>
      _sync(dao, baseCode);

  Future<RateSyncResult> _sync(CurrenciesDao dao, String baseCode) async {
    final Uri url = Uri.parse('$rateSyncApiUrl/$baseCode');
    final http.Response response;
    try {
      response = await _client.get(url).timeout(timeout);
    } on TimeoutException {
      return const RateSyncOffline();
    } on Exception {
      // Сеть недоступна, DNS, отказ клиента: для пользователя это
      // «нет сети» в любом случае; курсы не трогаются (D-36).
      return const RateSyncOffline();
    }
    if (response.statusCode != 200) {
      return const RateSyncOffline();
    }
    final Map<String, double>? rates;
    try {
      rates = parseRatesResponse(jsonDecode(utf8.decode(response.bodyBytes)));
    } on FormatException {
      return const RateSyncFailed();
    }
    if (rates == null) {
      return const RateSyncFailed();
    }
    return applyRates(dao, rates, baseCode: baseCode);
  }

  /// Записывает курсы [rates] («код источника → курс за единицу [baseCode]»)
  /// в справочник: каждая живая небазовая валюта, присутствующая в словаре,
  /// получает rate_to_base из источника; база и валюты вне словаря не трогаются.
  ///
  /// Отдельный от сети метод: шаг 2 (UI) и тесты могут гонять применение
  /// без фейкового клиента.
  Future<RateSyncResult> applyRates(
    CurrenciesDao dao,
    Map<String, double> rates, {
    required String baseCode,
  }) async {
    final List<Currency> alive = await dao.getAlive();
    int updated = 0;
    await dao.transaction(() async {
      for (final Currency currency in alive) {
        if (currency.isBase) {
          continue;
        }
        final double? rate = rates[currency.code];
        if (rate == null) {
          continue;
        }
        await dao.updateRateToBase(currency.code, rate);
        updated++;
      }
    });
    return RateSyncUpdated(updated);
  }
}
