// Тесты механики советов (M6-шаг B, D-84): константный справочник в core,
// дескриптор на живых потоках DAO, критерий «подходящего» — параметр
// (порог не зашит — решит дизайнер шага D). In-memory БД, образец Б2/D-80.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/advice_catalog.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';
import 'package:kopilka/data/db/seed.dart';
import 'package:kopilka/data/providers.dart';
import 'package:kopilka/features/insights/insights_providers.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await seedDefaultsIfEmpty(db);
    addTearDown(db.close);
  });

  group('справочник советов (D-84: константа в core)', () {
    test('содержит первый совет «неснижаемый остаток и проценты»', () {
      expect(adviceCatalog, hasLength(1));
      expect(adviceCatalog.single.id, 'min-balance-interest');
      expect(adviceCatalog.single.titleKey, 'adviceMinBalanceTitle');
      expect(adviceCatalog.single.bodyKey, 'adviceMinBalanceBody');
      expect(adviceCatalog.single.actionKey, 'adviceMinBalanceAction');
    });
  });

  group('дескриптор первого совета: критерий — параметр (D-84)', () {
    test('нет счетов — дескриптор ложен (порог не зашит)', () async {
      final bool active = await minBalanceAdviceDescriptor(
        db.accountsDao,
        db.debtsDao,
        suitability: noSuitability,
      );

      expect(active, isFalse);
    });

    test(
      'есть счёт без флага и подходит под критерий — дескриптор истинен',
      () async {
        await db.accountsDao.create(
          name: 'Карта',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          initialBalanceMinor: 500_00,
        );

        final bool active = await minBalanceAdviceDescriptor(
          db.accountsDao,
          db.debtsDao,
          suitability: (Account account, int balanceMinor) =>
              balanceMinor >= 100_00,
        );

        expect(active, isTrue);
      },
    );

    test('есть счёт, но не подходит под критерий — дескриптор ложен', () async {
      await db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        initialBalanceMinor: 50_00,
      );

      final bool active = await minBalanceAdviceDescriptor(
        db.accountsDao,
        db.debtsDao,
        suitability: (Account account, int balanceMinor) =>
            balanceMinor >= 100_00,
      );

      expect(active, isFalse);
    });

    test(
      'накопительный счёт (с датой напоминания) не даёт совета (D-81)',
      () async {
        await db.accountsDao.create(
          name: 'Уже накопительный',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          initialBalanceMinor: 500_00,
          interestReminderDate: DateTime.utc(2026, 10, 15),
        );

        final bool active = await minBalanceAdviceDescriptor(
          db.accountsDao,
          db.debtsDao,
          suitability: (Account account, int balanceMinor) => true,
        );

        expect(active, isFalse);
      },
    );

    test(
      'дефолтный справочник: критерий дизайнера применён (шаг D, D-92)',
      () async {
        await db.accountsDao.create(
          name: 'Карта',
          kind: AccountKind.card,
          currencyCode: 'RUB',
          initialBalanceMinor: 999_00,
        );

        final List<Advice> active = await activeAdvices(
          db.accountsDao,
          db.debtsDao,
        );

        // Спека дизайнера (D-92): suitability = balanceMinor > 0 — совет
        // активен на обычном счёте с любой лежащей суммой; UI-фильтр
        // «пока жив накопительный» — потребление карточки (insights_cards).
        expect(active, hasLength(1));
        expect(active.single.id, 'min-balance-interest');
      },
    );

    test('нулевые балансы совета не дают (критерий дизайнера: > 0)', () async {
      await db.accountsDao.create(
        name: 'Пустая карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );

      final List<Advice> active = await activeAdvices(
        db.accountsDao,
        db.debtsDao,
      );

      expect(active, isEmpty);
    });

    test('мягкое удаление счёта убирает его из дескриптора', () async {
      final Account account = await db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
        initialBalanceMinor: 500_00,
      );
      bool alwaysTrue(Account account, int balanceMinor) => true;
      expect(
        await minBalanceAdviceDescriptor(
          db.accountsDao,
          db.debtsDao,
          suitability: alwaysTrue,
        ),
        isTrue,
      );

      await db.accountsDao.softDelete(account.id);

      expect(
        await minBalanceAdviceDescriptor(
          db.accountsDao,
          db.debtsDao,
          suitability: alwaysTrue,
        ),
        isFalse,
      );
    });
  });

  group('поток активных советов (insights_providers, D-84)', () {
    test('пересчитывается при изменении живых счетов', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      final List<List<Advice>> emitted = <List<Advice>>[];
      final ProviderSubscription<AsyncValue<List<Advice>>> subscription =
          container.listen(activeAdvicesProvider, (
            _,
            AsyncValue<List<Advice>> value,
          ) {
            if (value.hasValue) {
              emitted.add(value.value!);
            }
          });
      addTearDown(subscription.close);

      // Начальный срез — пусто (дефолтный справочник без критерия).
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(1));
      expect(emitted.first, isEmpty);

      // Изменение источника — новый срез (критерий через переопределение
      // справочника нельзя: провайдер читает дефолт; проверяем пересчёт).
      await db.accountsDao.create(
        name: 'Карта',
        kind: AccountKind.card,
        currencyCode: 'RUB',
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(emitted.length, greaterThanOrEqualTo(2));
      expect(emitted.last, isEmpty);
    });
  });
}
