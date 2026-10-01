import 'package:drift/drift.dart';

import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/core/text.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'debts_dao.g.dart';

/// Сводка долга (D-82): к возврату, погашено, остаток.
///
/// Деньги — минорные единицы валюты долга (§3).
class DebtSummary {
  const DebtSummary({required this.debt, required this.paidMinor});

  /// Сам долг; тело и переплата берутся из него.
  final Debt debt;

  /// Погашено: сумма живых платежей долга (один SQL-агрегат, D-82).
  final int paidMinor;

  /// К возврату: тело + переплата суммой (D-81).
  int get totalMinor => debt.amountMinor + debt.extraMinor;

  /// Остаток: к возврату минус погашено (может уйти в минус только при
  /// несогласованных данных импорта — валидация это отсекает).
  int get remainingMinor => totalMinor - paidMinor;
}

/// Долги и погашения (v7, M6/D-82).
///
/// Правила:
/// - person непустой, direction — одно из двух значений D-81;
/// - тело долга строго положительно, переплата неотрицательна, деньги —
///   минорные единицы (§3);
/// - валюта долга обязана существовать живой строкой справочника;
/// - даты — UTC (§3): due_date/paid_at хранятся ISO-строкой UTC-момента
///   ( drift-DateTime на границе записи нормализуется через toUtc);
/// - FK без каскадов (§3/D-25): мягкое удаление долга или операции-
///   перевода платежи не трогает, сводка считается по живым строкам;
/// - удаление — только soft delete.
@DriftAccessor(tables: [Debts, DebtPayments, Currencies, Transactions])
class DebtsDao extends DatabaseAccessor<AppDatabase> with _$DebtsDaoMixin {
  DebtsDao(super.db, {this.idGenerator = newId, this.clock = utcNow});

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт долг.
  Future<Debt> create({
    required String person,
    required DebtDirection direction,
    required int amountMinor,
    required String currencyCode,
    int extraMinor = 0,
    DateTime? dueDate,
    String? note,
  }) async {
    final String trimmedPerson = _requirePerson(person);
    if (amountMinor <= 0) {
      throw DataValidationException(
        'тело долга должно быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
    if (extraMinor < 0) {
      throw DataValidationException(
        'переплата не может быть отрицательной',
        kind: DataFailure.invalidInput,
      );
    }
    await _requireAliveCurrency(currencyCode);
    final DateTime now = clock();
    return into(debts).insertReturning(
      DebtsCompanion.insert(
        id: idGenerator(),
        person: trimmedPerson,
        direction: direction.dbValue,
        amountMinor: amountMinor,
        extraMinor: extraMinor,
        currencyCode: currencyCode,
        dueDate: Value(dueDate?.toUtc().toIso8601String()),
        note: Value(optionalText(note)),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живой долг по id (или NULL).
  Future<Debt?> findById(String id) => (select(
    debts,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Живой долг по id или отказ [DataFailure.notFound] — образец
  /// [AttachmentsDao.requireAliveById] (D-82).
  Future<Debt> requireAliveById(String id) async {
    final Debt? debt = await findById(id);
    if (debt == null) {
      throw DataValidationException(
        'долг $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return debt;
  }

  /// Поток живых долгов, старые сверху (для списка UI).
  Stream<List<Debt>> watchAlive() => _aliveQuery().watch();

  /// Правит поля долга; не переданные поля (`Value.absent()`) остаются
  /// как были. `updatedAt` обновляется всегда.
  Future<Debt> updateDebt(
    String id, {
    Value<String> person = const Value.absent(),
    Value<DebtDirection> direction = const Value.absent(),
    Value<int> amountMinor = const Value.absent(),
    Value<int> extraMinor = const Value.absent(),
    Value<String> currencyCode = const Value.absent(),
    Value<DateTime?> dueDate = const Value.absent(),
    Value<String?> note = const Value.absent(),
  }) async {
    await requireAliveById(id);
    Value<String>? newPerson;
    if (person.present) {
      newPerson = Value<String>(_requirePerson(person.value));
    }
    if (amountMinor.present && amountMinor.value <= 0) {
      throw DataValidationException(
        'тело долга должно быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
    if (extraMinor.present && extraMinor.value < 0) {
      throw DataValidationException(
        'переплата не может быть отрицательной',
        kind: DataFailure.invalidInput,
      );
    }
    if (currencyCode.present) {
      await _requireAliveCurrency(currencyCode.value);
    }
    await (update(debts)..where((t) => t.id.equals(id))).write(
      DebtsCompanion(
        person: newPerson ?? const Value.absent(),
        direction: direction.present
            ? Value<String>(direction.value.dbValue)
            : const Value.absent(),
        amountMinor: amountMinor,
        extraMinor: extraMinor,
        currencyCode: currencyCode,
        dueDate: dueDate.present
            ? Value<String?>(dueDate.value?.toUtc().toIso8601String())
            : const Value.absent(),
        note: note.present
            ? Value<String?>(optionalText(note.value))
            : const Value.absent(),
        updatedAt: Value(clock()),
      ),
    );
    return requireAliveById(id);
  }

  /// Мягко удаляет долг. Платежи не трогает (без каскадов, §3/D-25):
  /// строки живут в дампах, сводка удалённого долга не показывается.
  Future<void> softDelete(String id) async {
    await requireAliveById(id);
    final DateTime now = clock();
    await (update(debts)..where((t) => t.id.equals(id))).write(
      DebtsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Записывает погашение долга: факт возврата деньгами (D-81).
  ///
  /// [transactionId] — перевод гашения (необязателен: перевод можно
  /// записать позже, платёж цел и без ссылки). Сумма — в валюте долга,
  /// строго положительная; [paidAt] — UTC-дата факта. Долг обязан быть
  /// живым; операция-перевод — тоже (мягко удалённая — notFound).
  Future<DebtPayment> addPayment(
    String debtId, {
    String? transactionId,
    required int amountMinor,
    required DateTime paidAt,
  }) async {
    final Debt debt = await requireAliveById(debtId);
    if (amountMinor <= 0) {
      throw DataValidationException(
        'сумма платежа должна быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
    if (transactionId != null) {
      final Transaction? linked =
          await (select(transactions)..where(
                (t) => t.id.equals(transactionId) & t.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (linked == null) {
        throw DataValidationException(
          'операция $transactionId не найдена',
          kind: DataFailure.notFound,
        );
      }
    }
    final DateTime now = clock();
    return into(debtPayments).insertReturning(
      DebtPaymentsCompanion.insert(
        id: idGenerator(),
        debtId: debt.id,
        transactionId: Value(transactionId),
        amountMinor: amountMinor,
        paidAt: paidAt.toUtc().toIso8601String(),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Мягко удаляет платёж. Долг и операцию-перевод не трогает (§3).
  Future<void> softDeletePayment(String id) async {
    await _requireAlivePayment(id);
    final DateTime now = clock();
    await (update(debtPayments)..where((t) => t.id.equals(id))).write(
      DebtPaymentsCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Поток живых платежей долга, свежие сверху (для карточки долга).
  Stream<List<DebtPayment>> watchPayments(String debtId) =>
      (select(debtPayments)
            ..where((t) => t.debtId.equals(debtId) & t.deletedAt.isNull())
            ..orderBy([
              (t) => OrderingTerm.desc(t.paidAt),
              (t) => OrderingTerm.desc(t.createdAt),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  /// Поток сводки долга (D-82): {к возврату, погашено, остаток}.
  ///
  /// Погашено — единственным SQL-агрегатом SUM по живым платежам
  /// (SQL только в DAO, §2; образец агрегата [BudgetsDao.watchProgress]):
  /// долг и сумма платежей читаются одним запросом с подзапросом-агрегатом.
  /// Мягкое удаление не ломает поток (D-25): удалённый долг исчезает
  /// из потока (NULL), удалённый платёж выпадает из SUM.
  Stream<DebtSummary?> watchSummary(String debtId) =>
      customSelect(
        'SELECT d.*, COALESCE(p.paid, 0) AS paid_minor '
        'FROM debts AS d '
        'LEFT JOIN ('
        '  SELECT debt_id, SUM(amount_minor) AS paid '
        '  FROM debt_payments WHERE deleted_at IS NULL '
        '  GROUP BY debt_id'
        ') AS p ON p.debt_id = d.id '
        'WHERE d.id = ? AND d.deleted_at IS NULL',
        variables: [Variable<String>(debtId)],
        readsFrom: {debts, debtPayments},
      ).watchSingleOrNull().map((QueryRow? row) {
        if (row == null) {
          return null;
        }
        return DebtSummary(
          debt: debts.map(row.data),
          paidMinor: row.read<int>('paid_minor'),
        );
      });

  SimpleSelectStatement<$DebtsTable, Debt> _aliveQuery() => select(debts)
    ..where((t) => t.deletedAt.isNull())
    ..orderBy([
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.id),
    ]);

  /// Живой платёж по id или отказ [DataFailure.notFound].
  Future<DebtPayment> _requireAlivePayment(String id) async {
    final DebtPayment? payment = await (select(
      debtPayments,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (payment == null) {
      throw DataValidationException(
        'платёж $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return payment;
  }

  Future<void> _requireAliveCurrency(String code) async {
    final Currency? currency =
        await (select(currencies)
              ..where((t) => t.code.equals(code) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (currency == null) {
      throw DataValidationException(
        'валюта $code не найдена в справочнике',
        kind: DataFailure.invalidInput,
      );
    }
  }

  /// Имя человека непустое; пробелы по краям обрезаются.
  String _requirePerson(String person) {
    final String trimmed = person.trim();
    if (trimmed.isEmpty) {
      throw DataValidationException(
        'имя человека в долге не может быть пустым',
        kind: DataFailure.invalidInput,
      );
    }
    return trimmed;
  }
}
