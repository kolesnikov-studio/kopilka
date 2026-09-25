import 'package:kopilka/data/db/dao/categories_dao.dart';
import 'package:kopilka/data/db/dao/currencies_dao.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/data/db/enums.dart';

/// Валюта, создаваемая при первом запуске (одна базовая валюта).
const String baseCurrencyCode = 'RUB';

/// Меню системных категорий, предустановленных при первом запуске.
///
/// Категории создаются с `isSystem = true`: их нельзя удалить (DAO это
/// запрещает), но можно переименовать — состав меню подстраивают под себя.
///
/// Названия системных категорий НЕ локализуются `.arb`: это данные в БД,
/// а не тексты интерфейса — пользователь их переименовывает, экспортирует
/// и переносит между устройствами вместе с файлом бэкапа.
const List<String> presetExpenseCategories = <String>[
  'Продукты',
  'Кафе и рестораны',
  'Транспорт',
  'Жильё',
  'Здоровье',
  'Развлечения',
  'Одежда',
  'Подарки',
  'Прочие расходы',
];

const List<String> presetIncomeCategories = <String>[
  'Зарплата',
  'Подарки',
  'Прочие доходы',
];

/// Наполняет пустую базу справочниками первого запуска: базовая валюта
/// и системный предустановленный набор категорий.
///
/// Идемпотентно: на непустой базе ничего не делает, повторный вызов безопасен.
Future<void> seedDefaultsIfEmpty(AppDatabase db) async {
  final CurrenciesDao currencies = db.currenciesDao;
  final CategoriesDao categories = db.categoriesDao;

  if (await currencies.findAlive(baseCurrencyCode) == null) {
    await currencies.create(
      code: baseCurrencyCode,
      symbol: '₽',
      isBase: true,
    );
  }

  if ((await categories.getAlive(kind: CategoryKind.expense)).isEmpty) {
    for (final String name in presetExpenseCategories) {
      await categories.create(
        name: name,
        kind: CategoryKind.expense,
        isSystem: true,
      );
    }
  }

  if ((await categories.getAlive(kind: CategoryKind.income)).isEmpty) {
    for (final String name in presetIncomeCategories) {
      await categories.create(
        name: name,
        kind: CategoryKind.income,
        isSystem: true,
      );
    }
  }
}
