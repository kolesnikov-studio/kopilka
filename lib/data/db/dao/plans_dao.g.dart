// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'plans_dao.dart';

// ignore_for_file: type=lint
mixin _$PlansDaoMixin on DatabaseAccessor<AppDatabase> {
  $CategoriesTable get categories => attachedDatabase.categories;
  $PlansTable get plans => attachedDatabase.plans;
  $CurrenciesTable get currencies => attachedDatabase.currencies;
  $AccountsTable get accounts => attachedDatabase.accounts;
  $TransactionsTable get transactions => attachedDatabase.transactions;
  PlansDaoManager get managers => PlansDaoManager(this);
}

class PlansDaoManager {
  final _$PlansDaoMixin _db;
  PlansDaoManager(this._db);
  $$CategoriesTableTableManager get categories =>
      $$CategoriesTableTableManager(_db.attachedDatabase, _db.categories);
  $$PlansTableTableManager get plans =>
      $$PlansTableTableManager(_db.attachedDatabase, _db.plans);
  $$CurrenciesTableTableManager get currencies =>
      $$CurrenciesTableTableManager(_db.attachedDatabase, _db.currencies);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db.attachedDatabase, _db.accounts);
  $$TransactionsTableTableManager get transactions =>
      $$TransactionsTableTableManager(_db.attachedDatabase, _db.transactions);
}
