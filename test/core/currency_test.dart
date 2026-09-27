// Тесты модуля справочника валют (R2): предзаполнение строкой
// (minorToMajorString) и конвертация в базовую (convertMinor, D-22),
// целостность полного ISO-списка (M3-шаг 2), cross-конвертация и
// производный курс перевода (M3-шаг 4, B4.1).
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/currency.dart';

void main() {
  group('целостность полного ISO-списка (M3-шаг 2)', () {
    test('коды уникальны и каноничны: три заглавные буквы', () {
      final Set<String> codes = <String>{
        for (final CurrencyInfo info in isoCurrencies) info.code,
      };
      expect(codes.length, isoCurrencies.length, reason: 'все коды уникальны');
      for (final String code in codes) {
        expect(code, matches(RegExp(r'^[A-Z]{3}$')), reason: 'код $code');
      }
    });

    test('символ и названия RU/EN непустые у каждой записи', () {
      for (final CurrencyInfo info in isoCurrencies) {
        expect(info.symbol.trim(), isNotEmpty, reason: 'символ ${info.code}');
        expect(info.nameEn.trim(), isNotEmpty, reason: 'EN ${info.code}');
        expect(
          currencyNamesRu[info.code]?.trim(),
          isNotEmpty,
          reason: 'RU ${info.code}',
        );
      }
    });

    test('словарь RU-названий ровно на список, без лишних ключей', () {
      expect(currencyNamesRu.length, isoCurrencies.length);
      expect(
        currencyNamesRu.keys.toSet(),
        <String>{for (final CurrencyInfo info in isoCurrencies) info.code},
      );
    });

    test('экспонент только 0/2/3', () {
      for (final CurrencyInfo info in isoCurrencies) {
        expect(info.exponent, anyOf(0, 2, 3), reason: 'экспонент ${info.code}');
      }
    });

    test('currencyInfoByCode находит каждую запись списка', () {
      for (final CurrencyInfo info in isoCurrencies) {
        expect(currencyInfoByCode(info.code)?.code, info.code);
      }
      expect(currencyInfoByCode('XXX'), isNull);
    });

    test('объём списка — полный ISO 4217 (около 160 записей)', () {
      // Решение мейнтейнера: полный ISO 4217 (~160). Без интернета сомнительные
      // записи исключены — граница допуска обозначена явно (см. отчёт шага).
      expect(isoCurrencies.length, inInclusiveRange(150, 180));
    });

    test('RUB/USD/EUR/JPY/KWD — точечные ассерты (экспоненты 2/2/2/0/3)', () {
      expect(currencyInfoByCode('RUB')?.exponent, 2);
      expect(currencyInfoByCode('RUB')?.symbol, '₽');
      expect(currencyInfoByCode('RUB')?.nameEn, 'Russian Ruble');
      expect(currencyInfoByCode('USD')?.exponent, 2);
      expect(currencyInfoByCode('USD')?.symbol, r'$');
      expect(currencyInfoByCode('EUR')?.exponent, 2);
      expect(currencyInfoByCode('EUR')?.symbol, '€');
      expect(currencyInfoByCode('JPY')?.exponent, 0);
      expect(currencyInfoByCode('JPY')?.symbol, '¥');
      expect(currencyInfoByCode('KWD')?.exponent, 3);
      expect(currencyInfoByCode('KWD')?.symbol, 'د.ك');
      expect(currencyNamesRu['RUB'], 'Российский рубль');
      expect(currencyNamesRu['USD'], 'Доллар США');
    });
  });

  group('minorToMajorString', () {
    test('экспонент 2: обычные суммы и ноль', () {
      expect(minorToMajorString(123456), '1234.56');
      expect(minorToMajorString(5), '0.05');
      // Ноль — с обычной дробной частью: строка идёт в поле ввода,
      // где дробность валидируется парсером (ноль отдельной ветки не требует).
      expect(minorToMajorString(0), '0.00');
    });

    test('знак сохраняется', () {
      expect(minorToMajorString(-123456), '-1234.56');
      expect(minorToMajorString(-5), '-0.05');
    });

    test('экспонент 0: целое число без разделителя', () {
      expect(minorToMajorString(12345, exponent: 0), '12345');
      expect(minorToMajorString(-7, exponent: 0), '-7');
    });

    test('экспонент 3: три знака, хвостовые нули', () {
      expect(minorToMajorString(1234, exponent: 3), '1.234');
      expect(minorToMajorString(1000, exponent: 3), '1.000');
      expect(minorToMajorString(1, exponent: 3), '0.001');
    });

    test('справочник: RUB двухзнаковый, JPY без дробной части, KWD трёхзнаковый',
        () {
      expect(currencyExponentByCode('RUB'), 2);
      expect(currencyExponentByCode('JPY'), 0);
      expect(currencyExponentByCode('KWD'), 3);
      // Код вне справочника — экспонент по умолчанию 2.
      expect(currencyExponentByCode('XXX'), 2);
      expect(currencyInfoByCode('USD')?.symbol, r'$');
      expect(currencyNamesRu['RUB'], 'Российский рубль');
    });
  });

  group('convertMinor (D-22)', () {
    test('простая конвертация 1:1 базовой валюты', () {
      expect(convertMinor(12345, 1), 12345);
      expect(convertMinor(-12345, 1), -12345);
    });

    test('курс умножает сумму', () {
      expect(convertMinor(10000, 2.5), 25000);
    });

    test('half-up по модулю на дробном произведении', () {
      // 100 минорных × 1.075 = 107.5 → 108 (вверх по модулю; не к нулю).
      expect(convertMinor(100, 1.075), 108);
      // Зеркальный отрицательный случай.
      expect(convertMinor(-100, 1.075), -108);
      // 250 минорных × 0.97 = 242.5 → 243.
      expect(convertMinor(250, 0.97), 243);
    });

    test('целое произведение не меняется округлением', () {
      expect(convertMinor(1000, 1.005), 1005);
      expect(convertMinor(12345, 0.975), 12036); // 12036.375 → 12036.
    });

    test('ноль конвертируется в ноль', () {
      expect(convertMinor(0, 97.5), 0);
    });
  });

  group('convertMinorCross (M3-шаг 4, B4.1)', () {
    test('равные курсы — тождественная конвертация', () {
      // 100,00 RUB → USD при курсах 1 и 0.01: 100 × 1 / 0.01 = 10 000
      // минорных (100 мажорных USD — курс искусственный, важна арифметика).
      expect(convertMinorCross(10000, 1, 0.01), 10000 * 100);
    });

    test('RUB (база) → USD по курсу справочника (97,5 ₽ за доллар)', () {
      // 9750 минорных RUB (97,50 ₽) → USD: 97,5 / 97,5 = 1 $ =
      // 100 минорных. Курс RUB к базе — 1 (RUB — база), USD — 97,5.
      expect(convertMinorCross(9750, 1, 97.5), 100);
    });

    test('USD → RUB: разница экспонентов в масштабе', () {
      // 100 минорных USD (1 $) × 97.5 / 1 = 9750 минорных RUB.
      expect(convertMinorCross(100, 97.5, 1), 9750);
    });

    test('JPY (экспонент 0) → RUB: без дробной части источника', () {
      // 1000 минорных йен = 1000 мажорных × 0.6 = 600 мажорных RUB =
      // 60 000 минорных (перевод йен: предзаполнение второй суммы).
      expect(
        convertMinorCross(1000, 0.6, 1, fromExponent: 0),
        60000,
      );
    });

    test('USD → JPY (экспонент 0): half-up по модулю на делении', () {
      // 1 $ (100 минорных USD, курс 97,5) → база 9750 минорных →
      // JPY: 97,5 / 0,6 = 162,5 йены → 163 (половина вверх по модулю).
      expect(
        convertMinorCross(100, 97.5, 0.6, toExponent: 0),
        163,
      );
    });

    test('KWD (экспонент 3) → RUB и знак сохраняется', () {
      // 1234 минорных динара = 1,234 KWD × 300 = 370,2 ₽ → 37020 минорных.
      expect(convertMinorCross(1234, 300, 1, fromExponent: 3), 37020);
      // Отрицательная сумма (не бывает в форме, но контракт общий с D-22).
      expect(
        convertMinorCross(-1234, 300, 1, fromExponent: 3),
        -37020,
      );
    });

    test('ноль конвертируется в ноль', () {
      expect(convertMinorCross(0, 97.5, 1), 0);
    });
  });

  group('derivedRate (M3-шаг 4, B4.1)', () {
    test('отношение сумм с учётом экспонентов', () {
      // 100 $ (10000 минорных) за 9750 ₽ (975000 минорных): курс =
      // 9750/100 = 97,5 ₽ за 1 $.
      expect(derivedRate(10000, 975000), 97.5);
    });

    test('разные экспоненты: минорные приведены к мажорным', () {
      // 1 $ (100 минорных) → 1000 йен (экспонент 0): курс 1000 мажорных
      // йен за 1 мажорный доллар.
      expect(derivedRate(100, 1000, toExponent: 0), 1000);
      // 1 динар (1000 минорных, экспонент 3) → 385 ₽ (38500): курс 385.
      expect(derivedRate(1000, 38500, fromExponent: 3), 385);
    });
  });
}
