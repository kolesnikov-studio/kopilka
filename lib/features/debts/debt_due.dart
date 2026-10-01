import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/database.dart';

/// Срок долга для показа (дедупликация D-102): единственный парсер
/// `due_date` для плитки списка (`debts_screen.dart`) и карточки долга
/// (`debt_card_screen.dart`) — раньше он повторялся приватным `_dueDateOf`
/// в обоих файлах. Пустая/битая строка — срока нет (терпимость схемы, §3);
/// показ — локальная дата.
DateTime? dueDateOf(Debt debt) {
  final String? due = debt.dueDate;
  if (due == null || due.isEmpty) {
    return null;
  }
  return DateTime.tryParse(due)?.toLocal();
}

/// Просрочка срока долга (S3 D-101, уточнение D-102): календарными датами
/// в UTC, а не моментом времени. Срок хранится полуночью UTC (§3), поэтому
/// «сегодня» — не просрочен весь сегодняшний день UTC, «вчера» — просрочен
/// (просрочка со следующего дня). Общее ядро календарного сравнения —
/// [isCalendarOverdueUtc]; наступление срока (карточка %, D-93.2) —
/// соседний предикат [isDueTodayOrEarlierUtc], включает «сегодня».
bool isDebtOverdue(Debt debt, DateTime nowUtc) {
  final DateTime? due = dueDateOf(debt)?.toUtc();
  return due != null && isCalendarOverdueUtc(due, nowUtc);
}
