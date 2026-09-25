import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/core/money.dart';

void main() {
  group('parseAmountToMinor', () {
    test('целая сумма', () {
      expect(parseAmountToMinor('250'), 25000);
    });

    test('копейки через запятую', () {
      expect(parseAmountToMinor('1 234,56'), 123456);
    });

    test('копейки через точку', () {
      expect(parseAmountToMinor('1234.5'), 123450);
    });

    test('одна копейка', () {
      expect(parseAmountToMinor('0,01'), 1);
    });

    test('ноль отклоняется', () {
      expect(parseAmountToMinor('0'), isNull);
      expect(parseAmountToMinor('0,00'), isNull);
    });

    test('отрицательное и мусор отклоняются', () {
      expect(parseAmountToMinor('-5'), isNull);
      expect(parseAmountToMinor('abc'), isNull);
      expect(parseAmountToMinor('1.2.3'), isNull);
      expect(parseAmountToMinor('1,234'), isNull);
      expect(parseAmountToMinor(''), isNull);
    });

    test('неразрывные пробелы игнорируются', () {
      expect(parseAmountToMinor('12\u00A0500,10'), 1250010);
    });
  });

  group('formatMoneyMinor', () {
    setUp(() {
      Intl.defaultLocale = 'en';
    });

    test('группировка и символ', () {
      final String formatted = formatMoneyMinor(
        123456,
        symbol: '₽',
        locale: 'en',
      );
      expect(formatted, contains('1,234.56'));
      expect(formatted, contains('₽'));
    });

    test('копейки всегда два знака', () {
      final String formatted = formatMoneyMinor(5, symbol: '₽', locale: 'en');
      expect(formatted, contains('0.05'));
    });
  });
}
