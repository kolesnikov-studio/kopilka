import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/core/advice_catalog.dart';
import 'package:kopilka/data/db/dao/accounts_dao.dart';
import 'package:kopilka/data/db/dao/debts_dao.dart';
import 'package:kopilka/data/providers.dart';

// Провайдер механики советов (M6/D-84): поток активных советов над живыми
// потоками DAO. UI-карточки — шаг D; механика отдаёт готовый список.

/// Поток активных советов: первый срез — сразу, далее — при любом
/// изменении счетов или долгов (живые потоки DAO, D-84). Дескрипторы —
/// линзы (D-16/D-18): без кэша и хранения. Событие изменения перезапускает
/// вычисление; повторные срезы схлопываются обычным async-пролётом
/// (exhaust-семантика: во время вычисления новые события копятся в один).
Stream<List<Advice>> _watchActiveAdvices(Ref ref) async* {
  final AccountsDao accountsDao = ref.watch(accountsDaoProvider);
  final DebtsDao debtsDao = ref.watch(debtsDaoProvider);

  final StreamController<void> changes = StreamController<void>();
  final List<StreamSubscription<void>> subscriptions = <StreamSubscription<void>>[
    // skip(1): первый срез потока DAO — не «изменение», он уже покрыт
    // начальным yield'ом ниже; иначе совет пересчитывался бы дважды.
    accountsDao.watchAlive().skip(1).listen(changes.add),
    debtsDao.watchAlive().skip(1).listen(changes.add),
  ];
  ref.onDispose(() {
    for (final StreamSubscription<void> subscription in subscriptions) {
      subscription.cancel();
    }
    changes.close();
  });

  yield await activeAdvices(accountsDao, debtsDao);
  await for (final _ in changes.stream) {
    yield await activeAdvices(accountsDao, debtsDao);
  }
}

final activeAdvicesProvider = StreamProvider<List<Advice>>(
  (Ref ref) => _watchActiveAdvices(ref),
);
