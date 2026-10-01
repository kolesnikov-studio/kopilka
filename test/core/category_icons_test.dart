// Тесты константного справочника иконок категорий (M5, D-54).
//
// Справочник — часть формата данных (код хранится в БД v4 и бэкапе v4),
// поэтому тесты — это замки на контракт: уникальность и форма кодов,
// валидность глифов, работа поиска по коду.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kopilka/core/category_icons.dart';

void main() {
  test('справочник покрывает типовые категории: не меньше 35 записей', () {
    expect(categoryIcons.length, greaterThanOrEqualTo(35));
  });

  test('коды уникальны и в snake_case (контракт хранения в БД/бэкапе)', () {
    final Set<String> codes = categoryIconCodes;
    expect(
      codes,
      hasLength(categoryIcons.length),
      reason: 'коды справочника уникальны',
    );
    final RegExp snakeCase = RegExp(r'^[a-z][a-z0-9]*(_[a-z0-9]+)*$');
    for (final CategoryIcon entry in categoryIcons) {
      expect(
        snakeCase.hasMatch(entry.code),
        isTrue,
        reason: 'код «${entry.code}» — snake_case',
      );
    }
  });

  test('коды из брифа присутствуют (D-54: типовые категории)', () {
    expect(
      categoryIconCodes,
      containsAll(<String>[
        'food', // еда
        'cafe', // кафе
        'transport', // транспорт
        'car', // автомобиль
        'home', // дом
        'utilities', // ЖКХ
        'communication', // связь
        'internet', // интернет/подписки
        'health', // здоровье
        'pharmacy', // аптека
        'sport', // спорт
        'beauty', // красота
        'clothes', // одежда
        'kids', // дети
        'education', // образование
        'entertainment', // развлечения
        'travel', // путешествия
        'pets', // животные
        'gifts', // подарки
        'salary', // зарплата
        'freelance', // фриланс
        'investments', // инвестиции
        'taxes', // налоги
        'fees', // комиссии
        'other', // другое
      ]),
    );
  });

  test('все записи несут MaterialIcons-глиф (без новых зависимостей)', () {
    for (final CategoryIcon entry in categoryIcons) {
      expect(entry.icon, isA<IconData>());
      expect(
        entry.icon.codePoint,
        greaterThan(0),
        reason: 'запись «${entry.code}» с валидным глифом',
      );
    }
  });

  test('categoryIconByCode: известный код найден, неизвестный — null', () {
    expect(categoryIconByCode('food')?.icon, Icons.restaurant);
    expect(categoryIconByCode('другой-код'), isNull);
    expect(categoryIconByCode(''), isNull);
  });
}
