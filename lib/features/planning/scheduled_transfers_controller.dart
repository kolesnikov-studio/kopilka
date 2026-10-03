import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/errors.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/dao/scheduled_transfers_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/providers.dart';

/// Живые отложенные переводы — ожидающие и исполненные, ранние сверху
/// (порядок [ScheduledTransfersDao.watchAlive], D-116): источник секции
/// «Отложенные переводы» в разделе «Планирование» (спека D §4).
final scheduledTransfersProvider =
    StreamProvider.autoDispose<List<ScheduledTransfer>>((ref) {
      return ref.watch(scheduledTransfersDaoProvider).watchAlive();
    });

/// Контроллер отложенных переводов (M7-шаг D, D-119/D-130): создание из
/// формы перевода, правка и удаление из списка «Планирования»; отказы DAO
/// — как [Result], UI объясняет их снеком по машиночитаемому виду
/// (образец [PlanningController]).
class ScheduledTransfersController extends Notifier {
  @override
  void build() {}

  ScheduledTransfersDao get _dao => ref.read(scheduledTransfersDaoProvider);

  /// Создаёт отложенный перевод из формы (спека D §3): `executeAtUtc` —
  /// полночь UTC выбранного дня (`calendarDayUtc`), дата созданной
  /// операции при исполнении будет равна ей (D-119). Комиссия — пара
  /// «обе или ни одной» (D-115.г): NULL/NULL либо сумма > 0 с живой
  /// расходной категорией. Отказы: [DataFailure.invalidInput] (суммы,
  /// счета, правила D-17, пара комиссии), [DataFailure.notFound]
  /// (счёт/категория).
  Future<Result<ScheduledTransfer>> createScheduledTransfer({
    required String accountId,
    required String targetAccountId,
    required int amountMinor,
    int? targetAmountMinor,
    required DateTime executeAtUtc,
    int? commissionMinor,
    String? commissionCategoryId,
  }) async {
    try {
      final ScheduledTransfer row = await _dao.create(
        accountId: accountId,
        targetAccountId: targetAccountId,
        amountMinor: amountMinor,
        targetAmountMinor: targetAmountMinor,
        executeAt: executeAtUtc,
        commissionMinor: commissionMinor,
        commissionCategoryId: commissionCategoryId,
      );
      return Success<ScheduledTransfer>(row);
    } on DataValidationException catch (error) {
      return Failure<ScheduledTransfer>(error.kind);
    }
  }

  /// Правит ожидающий отложенный перевод (спека D §4): сохранение формы
  /// в режиме правки. Исполненный строка формы не правится — DAO откажет
  /// [DataFailure.invalidInput] (гонка: исполнение произошло, пока форма
  /// была открыта); удалённый — [DataFailure.notFound].
  Future<Result<ScheduledTransfer>> updateScheduledTransfer({
    required String id,
    required String accountId,
    required String targetAccountId,
    required int amountMinor,
    int? targetAmountMinor,
    required DateTime executeAtUtc,
    int? commissionMinor,
    String? commissionCategoryId,
  }) async {
    try {
      final ScheduledTransfer row = await _dao.updateScheduledTransfer(
        id,
        accountId: Value<String>(accountId),
        targetAccountId: Value<String>(targetAccountId),
        amountMinor: Value<int>(amountMinor),
        targetAmountMinor: Value<int?>(targetAmountMinor),
        executeAt: Value<DateTime>(executeAtUtc),
        commissionMinor: Value<int?>(commissionMinor),
        commissionCategoryId: Value<String?>(commissionCategoryId),
      );
      return Success<ScheduledTransfer>(row);
    } on DataValidationException catch (error) {
      return Failure<ScheduledTransfer>(error.kind);
    }
  }

  /// Мягко удаляет ожидающий перевод (спека D §4, долгий тап списка):
  /// исполненный результат-операция не затрагивается (D-115.г).
  Future<Result<void>> deleteScheduledTransfer(String id) async {
    try {
      await _dao.softDelete(id);
      return const Success<void>(null);
    } on DataValidationException catch (error) {
      return Failure<void>(error.kind);
    }
  }
}

final scheduledTransfersControllerProvider =
    NotifierProvider<ScheduledTransfersController, void>(
      ScheduledTransfersController.new,
    );
