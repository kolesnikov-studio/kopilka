import 'package:drift/drift.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/ids.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/tables.dart';

part 'scheduled_transfers_dao.g.dart';

/// Отложенные переводы (v8, M7/D-116): CRUD, выборка ожидающих исполнения
/// и идемпотентная отметка исполнения.
///
/// Правила (D-115.г):
/// - суммы фиксируются при планировании: валюты счетов различаются ⇔ обе
///   суммы (D-17), курс заморожен — при исполнении пересчёта нет;
/// - комиссия — пара «обе или ни одной»: `commission_minor` >= 0 вместе
///   с живой категорией расходов либо обе NULL;
/// - `execute_at` (и `executed_at`) — UTC (§3), TEXT ISO-8601;
/// - pending-строки не участвуют в балансах до исполнения (§8);
/// - исполнение отмечается [markExecuted] идемпотентно: повторная отметка —
///   no-op (D-119); дата создаваемой операции — `execute_at` (D-119);
/// - удаление — только soft delete.
@DriftAccessor(tables: [ScheduledTransfers, Accounts, Categories, Transactions])
class ScheduledTransfersDao extends DatabaseAccessor<AppDatabase>
    with _$ScheduledTransfersDaoMixin {
  ScheduledTransfersDao(
    super.db, {
    this.idGenerator = newId,
    this.clock = utcNow,
  });

  /// Источник первичных ключей (в тестах подменяется на детерминированный).
  final IdGenerator idGenerator;

  /// Часы DAO (в тестах подменяются фиксированным временем).
  final Clock clock;

  /// Создаёт отложенный перевод.
  ///
  /// [targetAmountMinor] — правило D-17: обязательна, когда валюты живых
  /// счетов различаются, и обязана быть NULL, когда совпадают. Комиссия —
  /// [commissionMinor] + [commissionCategoryId] «обе или ни одной»; при
  /// исполнении она станет расходом в категорию комиссии (D-115.г).
  Future<ScheduledTransfer> create({
    required String accountId,
    required String targetAccountId,
    required int amountMinor,
    int? targetAmountMinor,
    required DateTime executeAt,
    int? commissionMinor,
    String? commissionCategoryId,
  }) async {
    await _validate(
      accountId: accountId,
      targetAccountId: targetAccountId,
      amountMinor: amountMinor,
      targetAmountMinor: targetAmountMinor,
      executeAt: executeAt,
      commissionMinor: commissionMinor,
      commissionCategoryId: commissionCategoryId,
    );
    final DateTime now = clock();
    return into(scheduledTransfers).insertReturning(
      ScheduledTransfersCompanion.insert(
        id: idGenerator(),
        accountId: accountId,
        targetAccountId: targetAccountId,
        amountMinor: amountMinor,
        targetAmountMinor: Value(targetAmountMinor),
        executeAt: _iso(executeAt),
        commissionMinor: Value(commissionMinor),
        commissionCategoryId: Value(commissionCategoryId),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Живой отложенный перевод по id (или NULL); исполненный — тоже
  /// «живой» (deleted_at NULL), D-119.
  Future<ScheduledTransfer?> getById(String id) => (select(
    scheduledTransfers,
  )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();

  /// Живой отложенный перевод по id или отказ [DataFailure.notFound]
  /// (образец D-82).
  Future<ScheduledTransfer> requireAliveById(String id) async {
    final ScheduledTransfer? row = await getById(id);
    if (row == null) {
      throw DataValidationException(
        'отложенный перевод $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return row;
  }

  /// Поток живых отложенных переводов (ожидающие и исполненные), ранние
  /// сверху — для списка UI (D-116).
  Stream<List<ScheduledTransfer>> watchAlive() => _aliveQuery().watch();

  /// Поток ожидающих исполнения: живые, ещё не исполненные строки
  /// с `execute_at <= now` (первый потребитель — сервис исполнения D-119).
  /// Мягко удалённые и уже исполненные не отдаются.
  Stream<List<ScheduledTransfer>> watchDue({required DateTime now}) {
    final int nowSeconds = now.toUtc().millisecondsSinceEpoch ~/ 1000;
    return customSelect(
      'SELECT * FROM scheduled_transfers '
      'WHERE deleted_at IS NULL AND executed_at IS NULL '
      'AND CAST(strftime(\'%s\', execute_at) AS INTEGER) <= ? '
      'ORDER BY execute_at, id',
      variables: [Variable<int>(nowSeconds)],
      readsFrom: {scheduledTransfers},
    ).watch().map(
      (List<QueryRow> rows) => <ScheduledTransfer>[
        for (final QueryRow row in rows) scheduledTransfers.map(row.data),
      ],
    );
  }

  /// Правит поля отложенного перевода; не переданные поля
  /// (`Value.absent()`) остаются как были. `updatedAt` обновляется всегда.
  ///
  /// Исполненный перевод не правится (D-119): отмена исполнения — не
  /// операция DAO, при потребности шаг B решает это сервисом.
  Future<ScheduledTransfer> updateScheduledTransfer(
    String id, {
    Value<String> accountId = const Value.absent(),
    Value<String> targetAccountId = const Value.absent(),
    Value<int> amountMinor = const Value.absent(),
    Value<int?> targetAmountMinor = const Value.absent(),
    Value<DateTime> executeAt = const Value.absent(),
    Value<int?> commissionMinor = const Value.absent(),
    Value<String?> commissionCategoryId = const Value.absent(),
  }) async {
    final ScheduledTransfer current = await requireAliveById(id);
    if (current.executedAt != null) {
      throw DataValidationException(
        'исполненный отложенный перевод $id не правится (D-119)',
        kind: DataFailure.invalidInput,
      );
    }
    final String effectiveAccount = accountId.present
        ? accountId.value
        : current.accountId;
    final String effectiveTarget = targetAccountId.present
        ? targetAccountId.value
        : current.targetAccountId;
    final int effectiveAmount = amountMinor.present
        ? amountMinor.value
        : current.amountMinor;
    final int? effectiveTargetAmount = targetAmountMinor.present
        ? targetAmountMinor.value
        : current.targetAmountMinor;
    final DateTime effectiveExecuteAt = executeAt.present
        ? executeAt.value
        : DateTime.parse(current.executeAt).toUtc();
    final int? effectiveCommission = commissionMinor.present
        ? commissionMinor.value
        : current.commissionMinor;
    final String? effectiveCommissionCategory = commissionCategoryId.present
        ? commissionCategoryId.value
        : current.commissionCategoryId;
    await _validate(
      accountId: effectiveAccount,
      targetAccountId: effectiveTarget,
      amountMinor: effectiveAmount,
      targetAmountMinor: effectiveTargetAmount,
      executeAt: effectiveExecuteAt,
      commissionMinor: effectiveCommission,
      commissionCategoryId: effectiveCommissionCategory,
    );
    await (update(scheduledTransfers)..where((t) => t.id.equals(id))).write(
      ScheduledTransfersCompanion(
        accountId: accountId,
        targetAccountId: targetAccountId,
        amountMinor: amountMinor,
        targetAmountMinor: targetAmountMinor,
        executeAt: executeAt.present
            ? Value<String>(_iso(executeAt.value))
            : const Value.absent(),
        commissionMinor: commissionMinor,
        commissionCategoryId: commissionCategoryId,
        updatedAt: Value(clock()),
      ),
    );
    return requireAliveById(id);
  }

  /// Мягко удаляет отложенный перевод. Каскадов нет (§3): исполненный
  /// перевод своим результатом-операцией не управляет.
  Future<void> softDelete(String id) async {
    await requireAliveById(id);
    final DateTime now = clock();
    await (update(scheduledTransfers)..where((t) => t.id.equals(id))).write(
      ScheduledTransfersCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );
  }

  /// Идемпотентная отметка исполнения (D-116/D-119): записывает
  /// [executedAt] и созданную операцию-перевод [transactionId].
  ///
  /// Повторный вызов на уже исполненной строке — no-op (повторный запуск
  /// исполнения исключён, D-119); вызывается сервисом исполнения внутри
  /// общей транзакции с созданием операции. `executedAt` — UTC (§3).
  Future<void> markExecuted(
    String id, {
    required String transactionId,
    required DateTime executedAt,
  }) async {
    final ScheduledTransfer? current = await getById(id);
    if (current == null) {
      throw DataValidationException(
        'отложенный перевод $id не найден',
        kind: DataFailure.notFound,
      );
    }
    if (current.executedAt != null) {
      return; // уже исполнен — идемпотентно (D-119)
    }
    if (!executedAt.isUtc) {
      throw DataValidationException(
        'момент исполнения должен быть в UTC (§3)',
        kind: DataFailure.invalidInput,
      );
    }
    final Transaction? transaction =
        await (select(transactions)
              ..where((t) => t.id.equals(transactionId) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (transaction == null) {
      throw DataValidationException(
        'операция исполнения $transactionId не найдена',
        kind: DataFailure.notFound,
      );
    }
    final int updated =
        await (update(
          scheduledTransfers,
        )..where((t) => t.id.equals(id) & t.executedAt.isNull())).write(
          ScheduledTransfersCompanion(
            executedAt: Value(_iso(executedAt)),
            executedTransactionId: Value(transactionId),
            updatedAt: Value(clock()),
          ),
        );
    if (updated == 0) {
      // Гонка двух отметок: исполнение уже отмечено — no-op (D-119).
      return;
    }
  }

  SimpleSelectStatement<$ScheduledTransfersTable, ScheduledTransfer>
  _aliveQuery() => select(scheduledTransfers)
    ..where((t) => t.deletedAt.isNull())
    ..orderBy([
      (t) => OrderingTerm.asc(t.executeAt),
      (t) => OrderingTerm.asc(t.id),
    ]);

  /// Валидации create/update по итоговому состоянию строки (D-115.г).
  Future<void> _validate({
    required String accountId,
    required String targetAccountId,
    required int amountMinor,
    required int? targetAmountMinor,
    required DateTime executeAt,
    required int? commissionMinor,
    required String? commissionCategoryId,
  }) async {
    if (amountMinor <= 0) {
      throw DataValidationException(
        'сумма отложенного перевода должна быть больше нуля',
        kind: DataFailure.invalidInput,
      );
    }
    if (accountId == targetAccountId) {
      throw DataValidationException(
        'счёт списания и зачисления перевода должны различаться',
        kind: DataFailure.invalidInput,
      );
    }
    final Account account = await _requireAliveAccount(accountId);
    final Account target = await _requireAliveAccount(targetAccountId);
    // Правило D-17 — как у обычного перевода: суммы фиксируются при
    // планировании, курс замораживается, при исполнении пересчёта нет.
    if (target.currencyCode != account.currencyCode) {
      if (targetAmountMinor == null) {
        throw DataValidationException(
          'перевод между разными валютами (${account.currencyCode} → '
          '${target.currencyCode}) требует обеих сумм: списания и зачисления',
          kind: DataFailure.invalidInput,
        );
      }
      if (targetAmountMinor <= 0) {
        throw DataValidationException(
          'сумма зачисления должна быть больше нуля',
          kind: DataFailure.invalidInput,
        );
      }
    } else if (targetAmountMinor != null) {
      throw DataValidationException(
        'перевод в одной валюте (${account.currencyCode}) хранит только '
        'сумму списания: target_amount_minor обязана быть NULL (D-17)',
        kind: DataFailure.invalidInput,
      );
    }
    if (!executeAt.isUtc) {
      throw DataValidationException(
        'момент исполнения должен быть в UTC (§3)',
        kind: DataFailure.invalidInput,
      );
    }
    // Пара комиссии «обе или ни одной» (D-115.г): одна из пары пуста —
    // отказ, не тихая нормализация.
    if ((commissionMinor == null) != (commissionCategoryId == null)) {
      throw DataValidationException(
        'комиссия задаётся парой: сумма и категория «обе или ни одной» '
        '(D-115.г)',
        kind: DataFailure.invalidInput,
      );
    }
    if (commissionMinor != null) {
      if (commissionMinor < 0) {
        throw DataValidationException(
          'комиссия не может быть отрицательной',
          kind: DataFailure.invalidInput,
        );
      }
      final Category? category =
          await (select(categories)..where(
                (t) =>
                    t.id.equals(commissionCategoryId!) & t.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (category == null) {
        throw DataValidationException(
          'категория комиссии $commissionCategoryId не найдена',
          kind: DataFailure.notFound,
        );
      }
      if (CategoryKind.fromDb(category.kind) != CategoryKind.expense) {
        throw DataValidationException(
          'комиссия — расход: категория «${category.name}» должна быть '
          'расходной',
          kind: DataFailure.invalidInput,
        );
      }
    }
  }

  Future<Account> _requireAliveAccount(String id) async {
    final Account? account = await (select(
      accounts,
    )..where((t) => t.id.equals(id) & t.deletedAt.isNull())).getSingleOrNull();
    if (account == null) {
      throw DataValidationException(
        'счёт $id не найден',
        kind: DataFailure.notFound,
      );
    }
    return account;
  }

  /// Каноничная запись UTC-даты в TEXT-колонку (образец due_date долгов).
  String _iso(DateTime date) => date.toUtc().toIso8601String();
}
