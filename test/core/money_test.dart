import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kopilka/core/money.dart';

void main() {
  // Контракт парсера (P2-2 аудита D-75, зафиксирован заголовком группы):
  // лимит целой части — 15 разрядов (~10^15, укладывается в int64);
  // некорректный ввод — null, FormatException не бросается никогда;
  // у валют с экспонентом 0 дробная часть запрещена целиком.
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

    test('гигантский ввод отклоняется, не бросает (регресс P1)', () {
      // 30 девяток: раньше int.parse бросал FormatException вместо null.
      expect(parseAmountToMinor('9' * 30), isNull);
      expect(parseAmountToMinor('9' * 16 + ',5'), isNull);
    });

    test('лимит разрядов целой части (15 знаков) принимается', () {
      // (10^15 − 1) мажорных × 100 минорных = 99 999 999 999 999 900 < 2^63.
      expect(parseAmountToMinor('9' * 15), 99999999999999900);
    });

    group('экспоненты (D-15)', () {
      test('экспонент 0: дробная часть запрещена, разделитель отклоняется', () {
        expect(parseAmountToMinor('250', exponent: 0), 250);
        expect(parseAmountToMinor('250,5', exponent: 0), isNull);
        expect(parseAmountToMinor('250.5', exponent: 0), isNull);
      });

      test('экспонент 2: поведение по умолчанию не изменилось', () {
        expect(parseAmountToMinor('1,5', exponent: 2), 150);
        expect(parseAmountToMinor('1,50', exponent: 2), 150);
        expect(parseAmountToMinor('1,505', exponent: 2), isNull);
      });

      test('экспонент 3: до трёх знаков, третья цифра значима', () {
        expect(parseAmountToMinor('1,234', exponent: 3), 1234);
        expect(parseAmountToMinor('1,2345', exponent: 3), isNull);
      });
    });
  });

  group('formatMoneyMinor', () {
    setUp(() {
      Intl.defaultLocale = 'en';
    });

    // H2: глобальная настройка не протекает в другие тесты независимо
    // от порядка выполнения файлов.
    tearDown(() {
      Intl.defaultLocale = null;
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

    group('экспоненты (D-15)', () {
      test('экспонент 0: без дробной части', () {
        final String formatted = formatMoneyMinor(
          12345,
          symbol: '¥',
          locale: 'en',
          exponent: 0,
        );
        expect(formatted, contains('12,345'));
        expect(formatted, isNot(contains('.')));
      });

      test('экспонент 2: как по умолчанию', () {
        expect(
          formatMoneyMinor(12345, symbol: '₽', locale: 'en', exponent: 2),
          formatMoneyMinor(12345, symbol: '₽', locale: 'en'),
        );
      });

      test('экспонент 3: три знака после разделителя', () {
        final String formatted = formatMoneyMinor(
          1234,
          symbol: 'د.ك',
          locale: 'en',
          exponent: 3,
        );
        expect(formatted, contains('1.234'));
      });
    });
  });
}
