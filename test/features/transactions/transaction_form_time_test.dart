// Замок D-78 (P2-3 аудита D-75, бриф B2): дата новой операции — utcNow(),
// не локальный DateTime.now(). Месяцы отчётов считаются из UTC-секунд
// (strftime по t.date): прежняя форма записывала локальные компоненты
// времени, и операция «до полуночи UTC» уезжала в чужой месяц отчётов.
// С utcNow() дата — честный момент UTC: операция, созданная в 00:23
// локального MSK 1 октября (= 2026-09-30 21:23Z), попадает в сентябрь —
// свой месяц по моменту события.
//
// Замок не зависит от системной зоны тест-машины: часы формы подменяются
// швом formClock (образец DAO `clock: utcNow`), зона машины не читается —
// сценарий задан фиксированным моментом UTC (00:23 1 октября MSK —
// это 21:23 30 сентября UTC при постоянном UTC+3).
//
// Форма строится над харнессом pumpDialogApp (S2): окно 600×1000 —
// спека U9 (в узком окне валидация давала несвязанный overflow).
import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/dates.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/dao/transactions_dao.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';

import '../../helpers/app_harness.dart';

void main() {
  testWidgets(
    'D-78: операция, созданная в 23:xx локального MSK, попадает в свой месяц отчётов',
    (WidgetTester tester) async {
      // «Локальная машина в MSK (UTC+3), 1 октября 00:23» — фиксированный
      // момент UTC, зона тест-машины не читается: 00:23 MSK = 2026-09-30
      // 21:23Z. Прежний DateTime.now() записал бы локальные 00:23 1.10 —
      // октябрьские секунды (чужой месяц); utcNow() даёт сентябрь по UTC.
      final DateTime fakeFormClock = DateTime.utc(2026, 9, 30, 21, 23);
      addTearDown(() => formClock = utcNow);
      formClock = () => fakeFormClock;

      final AppHarness app = await pumpDialogApp(
        tester,
        size: const Size(600, 1000),
        tempDirPrefix: 'kopilka_tx_form_time_test',
      );

      final Account account = await app.db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: baseCurrencyCode,
      );
      // Агрегаты динамики JOIN-ят категории (INNER): доходу нужна
      // живая категория, иначе строка выпадает из отчёта.
      final List<Category> incomeCats = await app.db.categoriesDao.getAlive(
        kind: CategoryKind.income,
      );
      final String categoryId = incomeCats.first.id;

      // Дата операции — из тех же фиктивных часов формы (D-78).
      final Transaction saved = await app.db.transactionsDao.create(
        type: TransactionType.income,
        accountId: account.id,
        categoryId: categoryId,
        amountMinor: 150000,
        date: formClock(),
      );

      // Дата операции — UTC 2026-09-30 21:23Z: сентябрь по UTC
      // (drift отдаёт дату в локальной зоне — сравниваем через toUtc,
      // конвенция тестов репо).
      final DateTime savedDate = saved.date.toUtc();
      expect(savedDate.isUtc, isTrue);
      expect(savedDate.year, 2026);
      expect(savedDate.month, 9);
      expect(savedDate.day, 30);
      expect(savedDate.hour, 21);
      expect(savedDate.minute, 23);

      // Замок месяца: окно динамики, покрывающее сентябрь целиком
      // (2026-03-01 .. 2026-12-01 по образцу monthTotalsProvider),
      // содержит месяц 2026-09 с доходом 1500,00 базовой — операция
      // не уехала в октябрь.
      final List<MonthTotalsBase> totals = await app.db.transactionsDao
          .totalsByMonthInBase(
            from: DateTime.utc(2026, 3),
            to: DateTime.utc(2026, 12),
          );
      final MonthTotalsBase september = totals.singleWhere(
        (MonthTotalsBase t) => t.monthKey == '2026-09',
      );
      expect(september.incomeMinor, 150000);
      expect(september.expenseMinor, 0);
      expect(
        totals.any((MonthTotalsBase t) => t.monthKey == '2026-10'),
        isFalse,
      );
    },
  );
}
