// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'currencies_dao.dart';

// ignore_for_file: type=lint
mixin _$CurrenciesDaoMixin on DatabaseAccessor<AppDatabase> {
  $CurrenciesTable get currencies => attachedDatabase.currencies;
  $AccountsTable get accounts => attachedDatabase.accounts;
  CurrenciesDaoManager get managers => CurrenciesDaoManager(this);
}

class CurrenciesDaoManager {
  final _$CurrenciesDaoMixin _db;
  CurrenciesDaoManager(this._db);
  $$CurrenciesTableTableManager get currencies =>
      $$CurrenciesTableTableManager(_db.attachedDatabase, _db.currencies);
  $$AccountsTableTableManager get accounts =>
      $$AccountsTableTableManager(_db.attachedDatabase, _db.accounts);
}
