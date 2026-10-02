import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/dao/scheduled_transfers_dao.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

// Исполнение отложенных переводов (M7-шаг B, D-119).
//
// Механика — по духу D-83: офлайн, при запуске приложения, без фоновых
// периодических задач (§5), идемпотентно. Все назревшие строки исполняются
// одной drift-транзакцией: либо исполнены все, либо (сбой на любой) —
// ни одной, частичных данных не остаётся.

/// Текст уведомления об исполнении (D-119): константа механики, как у
/// напоминаний M6 (финальные тексты и формулировки — спека шага D;
/// показ — через шов [RemindersService.showNow]).
const String scheduledTransferExecutedBody = 'Отложенный перевод исполнен';

/// Префикс payload уведомления об исполнении (D-119; стабильный числовой
/// id из ключа — образец `account:`/`debt:` D-83).
const String scheduledTransferSource = 'scheduled:';

/// Обработчик исполненного перевода (D-119): живой binding показывает
/// уведомление через RemindersService при включённом opt-in; тесты —
/// записывают факт. Вызывается после успешной общей транзакции.
typedef ScheduledTransferExecutedHandler =
    Future<void> Function(ScheduledTransfer transfer);

/// Заглушка «уведомлений нет» (тесты и конструкторы без потребителя).
Future<void> _noopExecuted(ScheduledTransfer transfer) async {}

/// Исполняет отложенные переводы (M7/D-119): `watchDue(now)` → одна
/// drift-транзакция на все назревшие строки.
///
/// Суммы берутся строго из записи: курс заморожен при планировании,
/// пересчёта нет (D-115.г/D-17). Комиссия — расход `commission_minor`
/// в категорию комиссии со счёта списания; **комиссия 0 = отсутствие
/// комиссии** (D-123) — нулевой расход не создаётся. Дата создаваемой
/// операции — `execute_at` (UTC), не момент запуска: операции встают
/// в плановые даты, месячные отчёты соответствуют намерению (D-119).
/// Идемпотентность — `executed_at IS NOT NULL` (повторный запуск —
/// no-op); мягко удалённая строка не исполняется (её нет в `watchDue`).
/// Уведомление — после общей транзакции, отказ показа не влияет на данные.
class ScheduledTransfersService {
  ScheduledTransfersService({
    required this.db,
    required this.scheduledDao,
    required this.transactionsDao,
    this.onExecuted = _noopExecuted,
    this.clock = utcNow,
  });

  /// БД для единой транзакции «создание операций + отметка исполнения».
  final AppDatabase db;

  /// Отложенные переводы (v8, D-116).
  final ScheduledTransfersDao scheduledDao;

  /// Операции: перевод и расход комиссии создаются существующим API (D-17).
  final TransactionsDao transactionsDao;

  /// Уведомление «исполнен отложенный перевод» (D-119).
  final ScheduledTransferExecutedHandler onExecuted;

  /// Часы сервиса (в тестах — фиксированные, образец DAO `clock`).
  final Clock clock;

  /// Исполняет всё, что назрело к моменту часов сервиса.
  Future<void> executeDue() async {
    final DateTime now = clock();
    final List<ScheduledTransfer> due = await scheduledDao
        .watchDue(now: now)
        .first;
    if (due.isEmpty) {
      return; // нечего исполнять — ни транзакции, ни уведомлений
    }
    final List<ScheduledTransfer> executed = <ScheduledTransfer>[];
    await db.transaction(() async {
      for (final ScheduledTransfer candidate in due) {
        // Перепроверка внутри транзакции: пока шли предыдущие строки,
        // другая выдача могла исполнить/удалить эту — no-op (D-119).
        final ScheduledTransfer? fresh = await scheduledDao.getById(
          candidate.id,
        );
        if (fresh == null || fresh.executedAt != null) {
          continue;
        }
        final DateTime executeAt = DateTime.parse(fresh.executeAt).toUtc();
        final Transaction transfer = await transactionsDao.create(
          type: TransactionType.transfer,
          accountId: fresh.accountId,
          targetAccountId: fresh.targetAccountId,
          amountMinor: fresh.amountMinor,
          targetAmountMinor: fresh.targetAmountMinor,
          date: executeAt,
        );
        final int commission = fresh.commissionMinor ?? 0;
        if (commission > 0) {
          // Комиссия 0 = отсутствие комиссии: расход нулевой суммы
          // не создаётся (D-123).
          await transactionsDao.create(
            type: TransactionType.expense,
            accountId: fresh.accountId,
            categoryId: fresh.commissionCategoryId,
            amountMinor: commission,
            date: executeAt,
          );
        }
        await scheduledDao.markExecuted(
          fresh.id,
          transactionId: transfer.id,
          executedAt: now,
        );
        executed.add(fresh);
      }
    });
    for (final ScheduledTransfer transfer in executed) {
      // Показ не влияет на данные: отказ канала не роняет исполнение
      // (D-43-дух/D-119) и не мешает уведомить остальные строки.
      await onExecuted(transfer).then(
        (_) {},
        onError: (Object _) {},
      );
    }
  }
}
