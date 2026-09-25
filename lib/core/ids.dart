import 'package:uuid/uuid.dart';

/// Первичные ключи таблиц — UUID v4 (TEXT), генерирует приложение (§3).
///
/// Тип вынесен отдельно, чтобы тесты подменяли генератор на
/// детерминированный и проверяли идентификаторы точно.
typedef IdGenerator = String Function();

const Uuid _uuid = Uuid();

/// Новый UUID v4 в каноническом строковом виде.
String newId() => _uuid.v4();
