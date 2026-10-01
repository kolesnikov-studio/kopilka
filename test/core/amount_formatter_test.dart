// Юнит-тесты AmountInputFormatter (спека B3/A4): форматтер — silent-ограничение
// дробности по экспоненту валюты (D-15): экспонент 0 запрещает разделитель
// целиком, 2 — до двух знаков, 3 — до трёх. Группировка (пробелы) и один
// разделитель разрешены, мусор — нет.
//
// Хелпер _edit имитирует ввод символа в конец текста: formatEditUpdate
// получает прежнее и новое значение поля, как это делает TextEditingController.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/app/widgets/amount_field.dart';
import 'package:kopilka/core/money.dart';

TextEditingValue _edit(
  TextInputFormatter formatter,
  String oldText,
  String newText,
) {
  return formatter.formatEditUpdate(
    TextEditingValue(text: oldText),
    TextEditingValue(text: newText),
  );
}

void main() {
  group('AmountInputFormatter, экспонент 2 (по умолчанию)', () {
    final AmountInputFormatter formatter = AmountInputFormatter();

    test('цифры, один разделитель и группировка пропускаются', () {
      expect(_edit(formatter, '', '1').text, '1');
      expect(_edit(formatter, '1', '12,5').text, '12,5');
      expect(_edit(formatter, '1', '12.5').text, '12.5');
      expect(_edit(formatter, '1250', '12 50').text, '12 50');
      // Разделитель допустим и без дробной части.
      expect(_edit(formatter, '12', '12.').text, '12.');
      // Запятая нормализуется к точке только внутри проверки: обе —
      // допустимые разделители.
      expect(_edit(formatter, '12,', '12,5').text, '12,5');
    });

    test(
      'второй разделитель и мусор отклоняются (возврат старого значения)',
      () {
        expect(_edit(formatter, '12.5', '12.5.').text, '12.5');
        expect(_edit(formatter, '12', '12a').text, '12');
        expect(_edit(formatter, '', '-5').text, '');
      },
    );

    test('не более двух знаков после разделителя', () {
      expect(_edit(formatter, '1,25', '1,250').text, '1,25');
      // До разделителя — можно много разрядов (лимит целой части парсера).
      expect(_edit(formatter, '9' * 14, '9' * 15).text, '9' * 15);
    });

    test(
      'третий знак после разделителя не вводится (silent-ограничение, B3)',
      () {
        expect(_edit(formatter, '1,25', '1,259').text, '1,25');
      },
    );
  });

  group('AmountInputFormatter, экспонент 0 (JPY)', () {
    final AmountInputFormatter formatter = AmountInputFormatter(exponent: 0);

    test('только цифры: разделитель и пробелы запрещены целиком', () {
      // Жёстче экспонентов > 0: у целых валют группировка форматтером
      // не пропускается (парсер пробелы по-прежнему игнорирует — «1 2»
      // из другого источника распарсится, но в поле не вводится).
      expect(_edit(formatter, '', '123').text, '123');
      expect(_edit(formatter, '12', '12 3').text, '12');
      expect(_edit(formatter, '123', '123 ').text, '123');
      expect(_edit(formatter, '', '1.').text, '');
      expect(_edit(formatter, '', ',').text, '');
      expect(_edit(formatter, '1', '1,2').text, '1');
    });
  });

  group('AmountInputFormatter, экспонент 3 (KWD)', () {
    final AmountInputFormatter formatter = AmountInputFormatter(exponent: 3);

    test('до трёх знаков после разделителя', () {
      expect(_edit(formatter, '1,23', '1,234').text, '1,234');
      expect(_edit(formatter, '1,234', '1,2345').text, '1,234');
    });
  });

  test('согласованность с парсером: пропущенное форматтером парсится (§7)', () {
    // Всё, что форматтер пропустил, парсер обязан разобрать теми же
    // правилами дробности — иначе форма отклоняла бы введённый текст.
    final AmountInputFormatter three = AmountInputFormatter(exponent: 3);
    expect(
      parseAmountToMinor(_edit(three, '', '1,234').text, exponent: 3),
      1234,
    );
    final AmountInputFormatter zero = AmountInputFormatter(exponent: 0);
    expect(parseAmountToMinor(_edit(zero, '', '123').text, exponent: 0), 123);
  });
}
