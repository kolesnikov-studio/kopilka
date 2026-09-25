# Архитектура Kopilka (рабочее имя)

Кроссплатформенное локальное приложение учёта финансов. Flutter, оффлайн-first, без сервера. Решения — в DECISIONS.md, этапы — в ROADMAP.md.

## 1. Стек

| Компонент | Выбор |
|---|---|
| UI и логика | Flutter (Dart), канальный stable |
| Состояние | Riverpod |
| БД | SQLite через drift (типизированные DAO, миграции, потоки изменений) |
| Графики | fl_chart (M2) |
| Локализация | flutter_localizations + .arb (RU, EN) |
| Файлы/пути | path_provider, file_picker, share_plus |
| Сеть (только проверка обновлений) | http + package_info_plus |
| Открытие ссылки релиза | url_launcher |
| UUID | uuid |
| Тесты | flutter_test, drift in-memory |

Принцип: минимум зависимостей, каждая новая — с обоснованием.

## 2. Слои и структура репозитория

```
lib/
  main.dart
  app/            — корень, роутинг, темы
  features/
    accounts/     — UI + state по фичам
    transactions/
    categories/
    budgets/      (M2)
    reports/      (M2)
    settings/     — экспорт/импорт, бэкапы, обновления
  data/
    db/           — drift: таблицы, DAO, миграции
    export/       — JSON/CSV импорт-экспорт
    update/       — проверка обновлений
  core/           — деньги (minor units), uuid, даты, ошибки
  l10n/           — .arb файлы
```

Поток зависимостей: UI → Riverpod-контроллеры → сервисы/DAO → drift. UI не обращается к БД напрямую.

## 3. Схема данных (v1, закладывается в M1)

Общие правила (нарушать нельзя):
- PK — UUID v4 (TEXT), генерирует приложение. Не автоинкремент: это основа будущего слияния файлов/синка.
- Каждая таблица: `created_at`, `updated_at` (UTC), `deleted_at` (NULL = живая запись). Удаление — только soft delete, без каскадов.
- Деньги — INTEGER в минорных единицах (копейки/центы). Float для денег запрещён.
- Индексы: transactions(date), transactions(account_id), transactions(category_id).

Таблицы:
- `currencies`: code TEXT PK (ISO 4217), symbol, is_base, rate_to_base
- `accounts`: id, name, kind (cash|bank|card|other), currency_code FK, initial_balance_minor, sort_order
- `categories`: id, name, kind (income|expense), parent_id NULL (вложенность), icon, color, is_system
- `transactions`: id, type (income|expense|transfer), account_id FK, target_account_id NULL (для transfer), category_id NULL, amount_minor, currency_code, date, note

Балансы не хранятся — вычисляются запросом из транзакций + initial_balance. Единый источник истины.

Мультивалютность (D-11): в M1 у счёта одна валюта, транзакция наследует валюту счёта; поле `rate_to_base` в currencies уже есть, пересчёты появятся в M2/M3 без изменения схемы. Долги/взаиморасчёты — вне MVP, закладки не делаем.

## 4. Экспорт/импорт и бэкапы

- Формат бэкапа: JSON `{ schema_version, exported_at, data: { таблицы } }`. Полный дамп, атомарная замена при импорте.
- Импорт обязан поддерживать старые schema_version (миграции формата экспорта).
- CSV — экспорт транзакций (для Excel/таблиц); импорт CSV с маппингом колонок — опционален (M2).
- Автобэкап при каждом запуске: JSON в выбранный пользователем каталог, хранить последние 10.
- Всё локально; ничего не уходит в сеть.

## 5. Проверка обновлений (D-09)

- UpdateService: GET GitHub Releases API, сравнение semver с версией из package_info_plus.
- Настройка в Settings: вкл/выкл (по умолчанию выкл + предложение при первом запуске), проверка вручную + автопроверка раз в 7 дней при включённой.
- Есть новая версия → диалог: версия, чейнджлог, кнопка «Открыть страницу релиза» (url_launcher). Скачивание/установка — руками пользователя (MVP).
- Единственный сетевой вызов в приложении — эта проверка. Телеметрии нет.

## 6. Платформы

- Android: minSdk по требованиям текущего Flutter stable; universal APK в GitHub Releases.
- Windows: NSIS-инсталлятор + portable zip.
- Linux: AppImage (основной), .deb опционально.
- iOS: код пишем совместимым, сборка/дистрибуция не настраиваются (D-10).

## 7. Качество и CI

- Unit-тесты: денежная логика, импорт/экспорт, DAO (drift in-memory).
- CI GitHub Actions: `analyze` + `test` на каждый PR; сборка артефактов (NSIS, portable, AppImage, APK) на тег релиза + черновик Release.
- Conventional commits; миграции drift — строго с первого релиза: у пользователей появятся данные с v0.1, ломать схему после — недопустимо.
