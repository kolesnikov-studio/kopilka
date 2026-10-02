// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'scheduled_transfers_dao.dart';

// ignore_for_file: type=lint
mixin _$ScheduledTransfersDaoMixin on DatabaseAccessor<AppDatabase> {
  $CurrenciesTable get currencies => attachedDatabase.currencies;
  $AccountsTable get accounts => attachedDatabase.accounts;
  $CategoriesTable get categories => attachedDatabase.categories;
  $TransactionsTable get transactions => attachedDatabase.transactions;
  $ScheduledTransfersTable get scheduledTransfers =>
      attachedDatabase.scheduledTransfers;
  ScheduledTransfersDaoManager get managers =>
      ScheduledTransfersDaoManager(this);
}

class ScheduledTransfersDaoManager {
  final _$ScheduledTransfersDaoMixin _db;
  ScheduledTransfersDaoManager(this._db);
  $$CurrenciesTableTableManager get currencies =>
      $$CurrenciesTableTableManager(_db.attachedDatabase, _db.currencies);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db.attachedDatabase, _db.accounts);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$TransactionsTableTableManager get transactions =>
      $$TransactionsTableTableManager(_db.attachedDatabase, _db.transactions);
  $$ScheduledTransfersTableTableManager get scheduledTransfers =>
      $$ScheduledTransfersTableTableManager(
        _db.attachedDatabase,
        _db.scheduledTransfers,
      );
}
