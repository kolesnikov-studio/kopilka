// Справочник иконок категорий (M5, D-54): константные данные в core,
// не .arb — по образцу справочника валют (D-23): это справочные данные,
// а не интерфейсные тексты; .arb остаётся для интерфейса.
//
// Код — стабильная snake_case-строка ("food"): он хранится в БД
// (categories.icon_code, схема v4) и в файлах бэкапа v4, поэтому состав
// справочника расширяется только добавлением записей — переименование
// или удаление кода сломало бы данные пользователей.
//
// Иконки — только MaterialIcons (uses-material-design уже включён),
// без новых зависимостей. Стиль — закрашенные базовые глифы, чтобы
// в списках читались одинаково; UI-шаг выберет показ по своему вкусу.
//
// Этот файл не знает про БД и DAO: слой данных проверяет коды через
// [categoryIconByCode]; UI возьмёт IconData отсюда же. Подписи иконок —
// не здесь: это интерфейсные тексты, они придут с UI-шагом через .arb.

import 'package:flutter/material.dart';

/// Справочная запись иконки: код в БД/бэкапе + MaterialIcons-иконка.
class CategoryIcon {
  const CategoryIcon({required this.code, required this.icon});

  /// Стабильный код в БД и бэкапе (snake_case, без пробелов).
  final String code;

  /// Глиф MaterialIcons для показа в UI.
  final IconData icon;
}

/// Полный справочник: типовые категории личного учёта (D-54, идея 4).
///
/// Порядок — группами (еда/быт, транспорт, здоровье, дети, досуг, деньги,
/// прочее) в логике «от расходов к доходам»: он же станет порядком выбора
/// в UI. Состав расширяется без ломки данных; коды после выпуска не
/// переименовываются и не удаляются.
const List<CategoryIcon> categoryIcons = <CategoryIcon>[
  // Еда и быт.
  CategoryIcon(code: 'food', icon: Icons.restaurant),
  CategoryIcon(code: 'groceries', icon: Icons.local_grocery_store),
  CategoryIcon(code: 'cafe', icon: Icons.local_cafe),
  CategoryIcon(code: 'home', icon: Icons.home),
  CategoryIcon(code: 'utilities', icon: Icons.receipt_long),
  CategoryIcon(code: 'communication', icon: Icons.phone_iphone),
  CategoryIcon(code: 'internet', icon: Icons.wifi),
  CategoryIcon(code: 'subscriptions', icon: Icons.autorenew),
  CategoryIcon(code: 'clothes', icon: Icons.checkroom),
  CategoryIcon(code: 'beauty', icon: Icons.face_retouching_natural),
  CategoryIcon(code: 'cleaning', icon: Icons.cleaning_services),
  CategoryIcon(code: 'electronics', icon: Icons.devices),
  CategoryIcon(code: 'shopping', icon: Icons.shopping_bag),
  CategoryIcon(code: 'repair', icon: Icons.construction),
  // Транспорт.
  CategoryIcon(code: 'transport', icon: Icons.directions_bus),
  CategoryIcon(code: 'car', icon: Icons.directions_car),
  CategoryIcon(code: 'fuel', icon: Icons.local_gas_station),
  // Здоровье и спорт.
  CategoryIcon(code: 'health', icon: Icons.medical_services),
  CategoryIcon(code: 'pharmacy', icon: Icons.medication),
  CategoryIcon(code: 'sport', icon: Icons.fitness_center),
  CategoryIcon(code: 'insurance', icon: Icons.shield),
  // Дети и образование.
  CategoryIcon(code: 'kids', icon: Icons.child_care),
  CategoryIcon(code: 'education', icon: Icons.school),
  CategoryIcon(code: 'books', icon: Icons.menu_book),
  // Досуг.
  CategoryIcon(code: 'entertainment', icon: Icons.movie),
  CategoryIcon(code: 'hobby', icon: Icons.palette),
  CategoryIcon(code: 'travel', icon: Icons.flight),
  CategoryIcon(code: 'pets', icon: Icons.pets),
  CategoryIcon(code: 'gifts', icon: Icons.card_giftcard),
  CategoryIcon(code: 'charity', icon: Icons.volunteer_activism),
  // Деньги и доходы.
  CategoryIcon(code: 'salary', icon: Icons.payments),
  CategoryIcon(code: 'freelance', icon: Icons.laptop_mac),
  CategoryIcon(code: 'investments', icon: Icons.trending_up),
  CategoryIcon(code: 'taxes', icon: Icons.account_balance),
  CategoryIcon(code: 'fees', icon: Icons.percent),
  // Прочее.
  CategoryIcon(code: 'other', icon: Icons.category),
];

/// Все коды справочника — для тестов и UI-выборщика.
Set<String> get categoryIconCodes =>
    <String>{for (final CategoryIcon entry in categoryIcons) entry.code};

/// Код нейтральной иконки «прочее» — дефолт выбора в UI и заглушка
/// для категорий без иконки (NULL живой базы v0.4, D-55). Код существует
/// в справочнике всегда (замок — в test/core/category_icons_test.dart).
const String defaultCategoryIconCode = 'other';

/// Запись для показа: известный код — из справочника; NULL и неизвестная
/// строка (живая база v0.4 без иконок) — нейтральная заглушка «other».
CategoryIcon categoryIconFor(String? code) =>
    categoryIconByCode(code ?? '') ?? categoryIconByCode(defaultCategoryIconCode)!;

/// Справка по коду; `null` — кода нет в справочнике. DAO и импорт бэкапа
/// такой код отклоняют (строгая валидация, по образцу D-25): NULL валиден,
/// неизвестная строка — нет.
CategoryIcon? categoryIconByCode(String code) {
  for (final CategoryIcon entry in categoryIcons) {
    if (entry.code == code) {
      return entry;
    }
  }
  return null;
}
