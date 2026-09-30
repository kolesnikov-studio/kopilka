import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/providers.dart';

/// Живые долги — список раздела (старые сверху, D-82).
final aliveDebtsProvider = StreamProvider<List<Debt>>((ref) {
  return ref.watch(debtsDaoProvider).watchAlive();
});

/// Сводка долга (D-82): NULL — долг удалён (D-87.1 — обязанность UI).
final debtSummaryProvider =
    StreamProvider.autoDispose.family<DebtSummary?, String>((ref, debtId) {
  return ref.watch(debtsDaoProvider).watchSummary(debtId);
});

/// Живые платежи долга (свежие сверху, D-82).
final debtPaymentsProvider =
    StreamProvider.autoDispose.family<List<DebtPayment>, String>((
  ref,
  debtId,
) {
  return ref.watch(debtsDaoProvider).watchPayments(debtId);
});

/// Параметры связанного перевода в диалоге гашения (§4/D-17): одна сумма —
/// при равных валютах, обе — при разных.
class DebtTransferData {
  const DebtTransferData({
    required this.outAccountId,
    required this.inAccountId,
    required this.amountMinor,
    this.targetAmountMinor,
    this.note,
    this.date,
  });

  /// Счёт списания.
  final String outAccountId;

  /// Счёт зачисления (валюта долга).
  final String inAccountId;

  /// Сумма списания (валюта счёта списания).
  final int amountMinor;

  /// Сумма зачисления — только при разных валютах счетов (D-17), иначе NULL.
  final int? targetAmountMinor;

  final String? note;

  /// Дата перевода (UTC, D-78); NULL — дата формы (utcNow).
  final DateTime? date;
}

/// Контроллер раздела «Долги» (M6/D-89): формы/удаление/гашение через DAO,
/// без прямого SQL. Отказы DAO — [Result] с машиночитаемым [DataFailure],
/// тексты подбирает UI (§2).
class DebtsController extends Notifier {
  @override
  void build() {}

  DebtsDao get _debts => ref.read(debtsDaoProvider);

  /// Создаёт долг; отказ возвращает как [Result], не бросая исключение.
  Future<Result<Debt>> createDebt({
    required String person,
    required DebtDirection direction,
    required int amountMinor,
    required String currencyCode,
    int extraMinor = 0,
    DateTime? dueDate,
    String? note,
  }) async {
    try {
      final Debt debt = await _debts.create(
        person: person,
        direction: direction,
        amountMinor: amountMinor,
        currencyCode: currencyCode,
        extraMinor: extraMinor,
        dueDate: dueDate,
        note: note,
      );
      return Success<Debt>(debt);
    } on DataValidationException catch (error) {
      return Failure<Debt>(error.kind);
    }
  }

  /// Правит поля долга (не переданные — `Value.absent()`, конвенция A1).
  Future<Result<Debt>> updateDebt(
    String id, {
    Value<String> person = const Value.absent(),
    Value<DebtDirection> direction = const Value.absent(),
    Value<int> amountMinor = const Value.absent(),
    Value<int> extraMinor = const Value.absent(),
    Value<String> currencyCode = const Value.absent(),
    Value<DateTime?> dueDate = const Value.absent(),
    Value<String?> note = const Value.absent(),
  }) async {
    try {
      final Debt debt = await _debts.updateDebt(
        id,
        person: person,
        direction: direction,
        amountMinor: amountMinor,
        extraMinor: extraMinor,
        currencyCode: currencyCode,
        dueDate: dueDate,
        note: note,
      );
      return Success<Debt>(debt);
    } on DataValidationException catch (error) {
      return Failure<Debt>(error.kind);
    }
  }

  /// Мягко удаляет долг; гонка «уже удалён» — notFound (D-87.1).
  Future<Result<void>> deleteDebt(String id) async {
    try {
      await _debts.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }

  /// Записывает гашение без перевода (§4, по умолчанию): transaction_id
  /// остаётся NULL (D-81.в).
  Future<Result<DebtPayment>> recordPayment({
    required String debtId,
    required int amountMinor,
    required DateTime paidAt,
  }) async {
    try {
      final DebtPayment payment = await _debts.addPayment(
        debtId,
        amountMinor: amountMinor,
        paidAt: paidAt,
      );
      return Success<DebtPayment>(payment);
    } on DataValidationException catch (error) {
      return Failure<DebtPayment>(error.kind);
    }
  }

  /// Связка «перевод + платёж одним потоком» (§4, D-81.в/D-17): создаёт
  /// операцию-перевод и платёж с [transactionId] сохранённого перевода.
  ///
  /// Откат при отказе DAO: платёж не пишется вовсе (отказ до его записи),
  /// а отказавший перевод откатывается [TransactionsDao.softDelete] —
  /// «ни перевода, ни платежа» по спеке §4. Отказ на платеже (гонка «долг
  /// удалён») — перевод удаляется, наружу идёт отказ платежа (notFound).
  Future<Result<DebtPayment>> recordPaymentWithTransfer({
    required String debtId,
    required int amountMinor,
    required DateTime paidAt,
    required DebtTransferData transfer,
  }) async {
    String? transferId;
    try {
      final Transaction created = await ref
          .read(transactionsDaoProvider)
          .create(
            type: TransactionType.transfer,
            accountId: transfer.outAccountId,
            targetAccountId: transfer.inAccountId,
            amountMinor: transfer.amountMinor,
            targetAmountMinor: transfer.targetAmountMinor,
            note: transfer.note,
            date: transfer.date ?? utcNow(),
          );
      transferId = created.id;
      final DebtPayment payment = await _debts.addPayment(
        debtId,
        transactionId: created.id,
        amountMinor: amountMinor,
        paidAt: paidAt,
      );
      return Success<DebtPayment>(payment);
    } on DataValidationException catch (error) {
      // Перевод создан, платёж не прошёл — перевод откатывается: «ни
      // перевода, ни платежа» (§4). Мягкое удаление как у удаления любой
      // операции; отказ самого отката не проглатываем — unexpected.
      final String? createdId = transferId;
      if (createdId != null) {
        await ref.read(transactionsDaoProvider).softDelete(createdId);
      }
      return Failure<DebtPayment>(error.kind);
    }
  }

  /// Мягко удаляет платёж (D-89: без редактирования); операция-перевод
  /// не трогается (текст подтверждения говорит об этом честно, §2).
  Future<Result<void>> deletePayment(String id) async {
    try {
      await _debts.softDeletePayment(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final debtsControllerProvider =
    NotifierProvider<DebtsController, void>(DebtsController.new);
