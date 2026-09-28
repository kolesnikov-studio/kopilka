import 'package:drift/drift.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/tables.dart';

part 'currencies_dao.g.dart';

/// Справочник валют (§3): PK — код ISO 4217, удаление — только soft delete.
///
/// Валюту, которую используют живые счета, удалить нельзя: внешний ключ такую
/// попытку не поймает (строка остаётся в таблице), а счёт остался бы без валюты.
@DriftAccessor(tables: [Currencies, Accounts])
class CurrenciesDao extends DatabaseAccessor<AppDatabase>
    with _$CurrenciesDaoMixin {
  CurrenciesDao(super.db, {this.clock = utcNow});

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт валюту; код приводится к верхнему регистру, символ обрезается.
  ///
  /// Повторное создание ранее удалённой валюты возвращает её в справочник с
  /// новыми реквизитами: PK занят кодом навсегда, без этого удалённый код
  /// нельзя было бы использовать снова.
  Future<Currency> create({
    required String code,
    required String symbol,
    bool isBase = false,
    double rateToBase = 1,
  }) async {
    final String normalizedCode = code.trim().toUpperCase();
    final String normalizedSymbol = symbol.trim();
    if (normalizedCode.isEmpty) {
      throw DataValidationException(
        'код валюты не может быть пустым',
        kind: DataFailure.invalidInput,
      );
    }
    if (normalizedSymbol.isEmpty) {
      throw DataValidationException(
        'символ валюты не может быть пустым',
        kind: DataFailure.invalidInput,
      );
    }
    _requirePositiveRate(rateToBase);
    final DateTime now = clock();
    // A10/R9: запись и демотировка прежней базовой — одной транзакцией,
    // как в setBase: между insert и снятием флага не должно быть момента
    // с двумя базовыми.
    final Currency? existing = await _findAny(normalizedCode);
    await transaction(() async {
      if (existing == null) {
        await into(currencies).insert(
          CurrenciesCompanion.insert(
            code: normalizedCode,
            symbol: normalizedSymbol,
            isBase: Value(isBase),
            rateToBase: Value(rateToBase),
            createdAt: now,
            updatedAt: now,
          ),
        );
      } else if (existing.deletedAt == null) {
        throw DataValidationException(
          'валюта $normalizedCode уже есть в справочнике',
          kind: DataFailure.invalidInput,
        );
      } else {
        await (update(currencies)..where((t) => t.code.equals(normalizedCode)))
            .write(
              CurrenciesCompanion(
                symbol: Value(normalizedSymbol),
                isBase: Value(isBase),
                rateToBase: Value(rateToBase),
                deletedAt: const Value<DateTime?>(null),
                updatedAt: Value(now),
              ),
            );
      }
      if (isBase) {
        await _demoteOtherBase(normalizedCode, now);
      }
    });
    final Currency? created = await findAlive(normalizedCode);
    if (created == null) {
      throw DataValidationException(
        'валюта $normalizedCode не найдена сразу после записи',
        kind: DataFailure.unknown,
      );
    }
    return created;
  }

  /// Живая валюта по коду.
  Future<Currency?> findAlive(String code) => (select(currencies)
        ..where((t) => t.code.equals(code) & t.deletedAt.isNull()))
      .getSingleOrNull();

  /// Все живые валюты, по алфавиту кода.
  Future<List<Currency>> getAlive() => _aliveQuery().get();

  /// Поток живых валют — обновляется при изменении справочника.
  Stream<List<Currency>> watchAlive() => _aliveQuery().watch();

  /// Базовая валюта приложения (сейчас — одна).
  Future<Currency?> baseCurrency() => (select(currencies)
        ..where((t) => t.isBase.equals(true) & t.deletedAt.isNull()))
      .getSingleOrNull();

  /// Меняет реквизиты валюты; не переданные поля (`Value.absent()`) остаются
  /// как были. `updatedAt` обновляется всегда.
  Future<Currency> updateCurrency(
    String code, {
    Value<String> symbol = const Value.absent(),
    Value<double> rateToBase = const Value.absent(),
  }) async {
    await _requireAlive(code);
    Value<String>? newSymbol;
    if (symbol.present) {
      final String trimmed = symbol.value.trim();
      if (trimmed.isEmpty) {
        throw DataValidationException(
          'символ валюты не может быть пустым',
          kind: DataFailure.invalidInput,
        );
      }
      newSymbol = Value<String>(trimmed);
    }
    if (rateToBase.present) {
      _requirePositiveRate(rateToBase.value);
    }
    await (update(currencies)..where((t) => t.code.equals(code))).write(
      CurrenciesCompanion(
        symbol: newSymbol ?? const Value.absent(),
        rateToBase: rateToBase,
        updatedAt: Value(clock()),
      ),
    );
    return _requireAlive(code);
  }

  /// Делает валюту базовой, снимая флаг с остальных живых валют.
  /// Курсы не трогает: для смены базовой с пересчётом курсов — [changeBase]
  /// (D-20). Оставлен как низкоуровневая операция и для обратной
  /// совместимости тестов слоя данных.
  Future<void> setBase(String code) async {
    await _requireAlive(code);
    final DateTime now = clock();
    await transaction(() async {
      await _demoteOtherBase(code, now);
      await (update(currencies)..where((t) => t.code.equals(code))).write(
        CurrenciesCompanion(
          isBase: const Value<bool>(true),
          updatedAt: Value(now),
        ),
      );
    });
  }

  /// Делает валюту базовой с пересчётом курсов остальных живых валют
  /// (D-20, R9). Новая базовая получает курс ровно 1, курс каждой прочей
  /// живой валюты делится на её старый курс к новой базовой:
  /// `rate'(v) = rate(v) / rate(newBase)` — отношение курсов не зависит
  /// от выбора знаменателя, поэтому пересчёт сохраняет все относительные
  /// курсы и не меняет данные операций.
  ///
  /// Идемпотентность: запрос базовой валюты — успешный выход без записи
  /// (после смены базовой повторный вызов с тем же кодом не ошибка,
  /// UI-отказов этот случай не создаёт: у базовой валюты действие скрыто).
  /// Отказ `notFound` — код не найден среди живых (в т.ч. мягко удалён).
  ///
  /// R9: вся правка — одна транзакция; между демотировкой старой базовой
  /// и промоцией новой не существует читаемого состояния без базовой
  /// или с двумя базовыми.
  Future<void> changeBase(String code) async {
    final Currency target = await _requireAlive(code);
    if (target.isBase) {
      return;
    }
    final DateTime now = clock();
    await transaction(() async {
      // Демотировка прежней базовой — первой операцией транзакции: до её
      // завершения другие транзакции видят ровно одну базовую (R9).
      await _demoteOtherBase(code, now);
      // Пересчёт курсов: живые валюты, кроме новой базовой.
      final List<Currency> alive = await (select(currencies)
            ..where(
              (t) => t.deletedAt.isNull() & t.code.equals(code).not(),
            ))
          .get();
      final double oldTargetRate = target.rateToBase;
      for (final Currency currency in alive) {
        final double recalculated = currency.isBase
            ? 1.0 / oldTargetRate
            : currency.rateToBase / oldTargetRate;
        await (update(currencies)
                ..where((t) => t.code.equals(currency.code)))
            .write(
          CurrenciesCompanion(
            rateToBase: Value(recalculated),
            isBase: const Value<bool>(false),
            updatedAt: Value(now),
          ),
        );
      }
      // Промоция новой базовой — последней операцией: курс ровно 1 (D-16).
      await (update(currencies)..where((t) => t.code.equals(code))).write(
        CurrenciesCompanion(
          isBase: const Value<bool>(true),
          rateToBase: const Value<double>(1),
          updatedAt: Value(now),
        ),
      );
    });
  }

  /// Точечное обновление курса к базовой валюте (M4: синхронизация курсов,
  /// D-36): запись внешнего курса, полученного сервисом синхронизации, без
  /// смены базовой валюты. Ручной ввод курса (B1.1) идёт через
  /// [updateCurrency]; здесь — отдельный вход для сетевого слоя, чтобы его
  /// отказы не смешивались с правкой реквизитов. Курс обязан быть
  /// положительным (`_requirePositiveRate`); валюта обязана быть живой.
  Future<void> updateRateToBase(String code, double rateToBase) async {
    await _requireAlive(code);
    _requirePositiveRate(rateToBase);
    await (update(currencies)..where((t) => t.code.equals(code))).write(
      CurrenciesCompanion(
        rateToBase: Value(rateToBase),
        updatedAt: Value(clock()),
      ),
    );
  }

  /// Сколько живых счетов используют валюту (B1.4: экран «Валюты» объясняет
  /// отказ удаления до попытки — счётчиком счетов, без списка).
  Future<int> aliveAccountsUsing(String code) => _aliveAccountsUsing(code);

  /// Мягко удаляет валюту. Запрещено, пока валюту используют живые счета.
  Future<void> softDelete(String code) async {
    await _requireAlive(code);
    final int usedByAccounts = await _aliveAccountsUsing(code);
    if (usedByAccounts > 0) {
      throw DataValidationException(
        'валюту $code используют живые счета ($usedByAccounts) — сначала удалите их',
        kind: DataFailure.currencyUsedByAccounts,
      );
    }
    final DateTime now = clock();
    await (update(currencies)..where((t) => t.code.equals(code))).write(
      CurrenciesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  SimpleSelectStatement<$CurrenciesTable, Currency> _aliveQuery() =>
      select(currencies)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.code)]);

  /// Валюта по PK — независимо от soft delete (нужно для разбора PK и циклов).
  Future<Currency?> _findAny(String code) =>
      (select(currencies)..where((t) => t.code.equals(code))).getSingleOrNull();

  Future<Currency> _requireAlive(String code) async {
    final Currency? currency = await findAlive(code);
    if (currency == null) {
      throw DataValidationException(
        'валюта $code не найдена в справочнике',
        kind: DataFailure.notFound,
      );
    }
    return currency;
  }

  void _requirePositiveRate(double rate) {
    if (rate <= 0) {
      throw DataValidationException(
        'курс к базовой валюте должен быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
  }

  Future<void> _demoteOtherBase(String keepCode, DateTime now) async {
    await (update(currencies)..where(
          (t) =>
              t.isBase.equals(true) &
              t.deletedAt.isNull() &
              t.code.equals(keepCode).not(),
        ))
        .write(
          CurrenciesCompanion(
            isBase: const Value<bool>(false),
            updatedAt: Value(now),
          ),
        );
  }

  Future<int> _aliveAccountsUsing(String code) async {
    final Expression<int> count = accounts.id.count();
    final TypedResult row = await (selectOnly(accounts)
          ..addColumns([count])
          ..where(
            accounts.currencyCode.equals(code) & accounts.deletedAt.isNull(),
          ))
        .getSingle();
    return row.read(count) ?? 0;
  }
}
