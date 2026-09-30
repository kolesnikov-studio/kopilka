// Деньги в минорных единицах (копейки/центы), §3. Фасад P2-2 аудита D-75:
// парсинг ввода — в money_parse.dart, форматирование для показа — в
// money_format.dart; этот файл оставлен экспортом, чтобы не рвать
// существующие импорты. Новые импорты — по частям.
export 'money_format.dart' show formatMoneyMinor;
export 'money_parse.dart' show defaultCurrencyExponent, parseAmountToMinor;
