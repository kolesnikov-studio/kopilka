import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/widgets/dialogs.dart';
import 'package:kopilka/app/widgets/error_state.dart';
import 'package:kopilka/core/currency.dart';
import 'package:kopilka/core/rate.dart';
import 'package:kopilka/core/result.dart';
import 'package:kopilka/data/db/database.dart';
import 'package:kopilka/features/settings/currencies_controller.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Валюты» (Настройки → Валюты, спека B1): список живых валют
/// (базовая — первой, со звездой и без курса — D-16), добавление из
/// встроенного ISO-списка, ручной курс, удаление, смена базовой.
class CurrenciesScreen extends ConsumerWidget {
  const CurrenciesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AsyncValue<List<Currency>> currencies = ref.watch(
      currenciesListProvider,
    );

    return Scaffold(
      // B1: собственный AppBar с заголовком и кнопкой назад — вложенный
      // экран настроек перекрывает заголовок ветки оболочки.
      appBar: AppBar(
        title: Text(l10n.currenciesScreenTitle),
        leading: const BackButton(),
      ),
      floatingActionButton: FloatingActionButton(
        // Уникальный hero-тег (M6-шаг D): FAB веток шелла живут в одном
        // поддереве корневого навигатора — дефолтный тег ломает Hero-полёт
        // при пуще fullscreen-маршрута (просмотр вложения из плитки).
        heroTag: 'currencies-fab',
        tooltip: l10n.currencyAdd,
        onPressed: () => _showAddDialog(context, ref),
        child: const Icon(Icons.add),
      ),
      body: currencies.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          // Поток DAO живой: переподписка при пересборке виджета.
          onRetry: () => ref.invalidate(currenciesListProvider),
        ),
        data: (List<Currency> rows) {
          // Пусто недостижимо (базовая всегда есть, посев): B1. Проверка
          // всё же есть — на случай несогласованного импорта.
          if (rows.isEmpty) {
            return Center(child: Text(l10n.errorNotFound));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (BuildContext context, int index) =>
                const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) => _CurrencyTile(
              currency: rows[index],
              // Код базовой нужен подзаголовкам «1 = …» и заголовкам диалогов.
              baseCode:
                  rows.firstWhere((Currency c) => c.isBase).code,
            ),
          );
        },
      ),
    );
  }

  /// B1.1: выбор из встроенного ISO-списка, минус уже добавленные живые
  /// (отключены с бейджем, не выбрасываются); поиск по коду и названию.
  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => const _AddCurrencyDialog(),
    );
  }
}

class _CurrencyTile extends ConsumerWidget {
  const _CurrencyTile({required this.currency, required this.baseCode});

  final Currency currency;
  final String baseCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? nameRu = currencyNamesRu[currency.code];

    return ListTile(
      leading: CircleAvatar(
        child: Text(
          currency.symbol,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      title: Text(
        nameRu == null
            ? currency.code
            // B1: «Код — Название»; название из core-словаря (D-23).
            : '${currency.code} — $nameRu',
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: currency.isBase
          ? Text(l10n.currenciesBaseBadge)
          // B1: «1 = 97,50 RUB» — код базовой в записи, не «1 ₽ = …»
          // (базовая меняется, D-20).
          : Text(
              l10n.currenciesRateOf(formatRate(currency.rateToBase), baseCode),
            ),
      trailing: currency.isBase
          // B1: базовая — иконка-бейдж; курс всегда 1 и скрыт (D-16).
          ? const Icon(Icons.star)
          : null,
      onTap: currency.isBase
          // Тап по базовой — ничего (D-16).
          ? null
          : () => _showRateDialog(context),
      onLongPress: currency.isBase
          // B1: долгий тап по базовой отключён — удаление базовой запрещено
          // DAO (правило «ровно одна базовая»), смена — только у остальных.
          ? null
          : () => _showRowMenu(context, ref),
    );
  }

  /// B1.2: диалог правки курса с подсказкой о молчаливом пересчёте
  /// агрегатов (D-16: без «вы уверены»).
  Future<void> _showRateDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _RateDialog(currency: currency, baseCode: baseCode),
    );
  }

  /// B1.3/B1.4: меню долгого тапа — «Сделать базовой», «Удалить».
  Future<void> _showRowMenu(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: Text('${currency.code} — ${currencyNamesRu[currency.code] ?? ''}'),
        children: <Widget>[
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('base'),
            child: Text(l10n.currencyMakeBase),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop('delete'),
            child: Text(l10n.currencyDeleteMenuAction),
          ),
        ],
      ),
    );
    if (action == null || !context.mounted) {
      return;
    }
    if (action == 'base') {
      await _confirmChangeBase(context, ref);
    } else if (action == 'delete') {
      await _confirmDelete(context, ref);
    }
  }

  /// B1.3: обязательное подтверждение с объяснением последствий (D-20).
  Future<void> _confirmChangeBase(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool confirmed = await showCustomConfirmDialog(
      context: context,
      title: l10n.currencyChangeBaseTitle(currency.code),
      body: l10n.currencyChangeBaseBody(currency.code),
      confirmLabel: l10n.currencyChangeBaseAction,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result = await ref
        .read(currenciesControllerProvider.notifier)
        .changeBase(currency.code);
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }

  /// B1.4: если валюту используют живые счета — объяснение отказа ДО попытки
  /// (диалог со счётчиком); DAO-отказ остаётся страховкой и показывается
  /// снеком (не глотать). Иначе — подтверждение «история не изменится».
  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final int used = await ref
        .read(currenciesControllerProvider.notifier)
        .aliveAccountsUsing(currency.code);
    if (!context.mounted) {
      return;
    }
    if (used > 0) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(l10n.currencyDeleteTitle(currency.code)),
          content: Text(l10n.currencyDeleteBlockedBody(used)),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancelAction),
            ),
          ],
        ),
      );
      return;
    }
    final bool confirmed = await showCustomConfirmDialog(
      context: context,
      title: l10n.currencyDeleteTitle(currency.code),
      body: l10n.currencyDeleteBody,
      confirmLabel: l10n.deleteAction,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    final Result<void> result = await ref
        .read(currenciesControllerProvider.notifier)
        .deleteCurrency(currency.code);
    if (result.isFailure && context.mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}

/// B1.1: нижний лист выбора из ISO-справочника: поиск по коду/названию
/// (нормализация регистра, RU и EN), уже добавленные живые — отключены
/// с бейджем. Выбор → вторая ступень: поле курса (предзаполнено 1,
/// подсвечено; подсказка B1.1).
class _AddCurrencyDialog extends ConsumerStatefulWidget {
  const _AddCurrencyDialog();

  @override
  ConsumerState<_AddCurrencyDialog> createState() => _AddCurrencyDialogState();
}

class _AddCurrencyDialogState extends ConsumerState<_AddCurrencyDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Set<String> alive = <String>{
      for (final Currency currency
          in ref.watch(currenciesListProvider).value ??
              const <Currency>[])
        currency.code,
    };
    final String normalized = _query.trim().toLowerCase();
    final List<CurrencyInfo> results = isoCurrencies
        .where(
          (CurrencyInfo info) =>
              normalized.isEmpty ||
              info.code.toLowerCase().contains(normalized) ||
              info.nameEn.toLowerCase().contains(normalized) ||
              (currencyNamesRu[info.code] ?? '')
                  .toLowerCase()
                  .contains(normalized),
        )
        .toList();

    return AlertDialog(
      title: Text(l10n.currencyAdd),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.currencySearchHint,
              ),
              onChanged: (String value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        l10n.errorNotFound,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (BuildContext context, int index) {
                        final CurrencyInfo info = results[index];
                        final bool added = alive.contains(info.code);
                        final String? nameRu = currencyNamesRu[info.code];
                        return ListTile(
                          dense: true,
                          enabled: !added,
                          title: Text(
                            nameRu == null
                                ? '${info.code} — ${info.symbol}'
                                // B1.1: «Код — Символ — Название».
                                : '${info.code} — ${info.symbol} — $nameRu',
                          ),
                          subtitle: added ? Text(l10n.currencyAlreadyAdded) : null,
                          onTap: added
                              ? null
                              : () => _chooseRateStep(info),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
      ],
    );
  }

  /// Вторая ступень B1.1: предзаполненный курс 1,000000, подсвечен,
  /// подсказка «сколько базовой валюты в одной единице»; Сохранить активен
  /// только при валидном курсе (> 0).
  Future<void> _chooseRateStep(CurrencyInfo info) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextEditingController rate = TextEditingController(text: '1');
    final GlobalKey<FormState> formKey = GlobalKey<FormState>();
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, void Function(void Function()) setState) {
          final bool valid = parseRate(rate.text) != null;
          return AlertDialog(
            title: Text(
              '${info.code} — ${currencyNamesRu[info.code] ?? info.nameEn}',
            ),
            content: Form(
              key: formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextFormField(
                    controller: rate,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: l10n.currencyRateLabel,
                    ),
                    validator: (String? value) =>
                        parseRate(value ?? '') == null
                            ? l10n.currencyRateInvalid
                            : null,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.currencyRateHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.cancelAction),
              ),
              FilledButton(
                onPressed: valid
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: Text(l10n.saveAction),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) {
      return;
    }
    final double? parsed = parseRate(rate.text);
    if (parsed == null) {
      return;
    }
    // Дефолт курса — 1 (B1.1: никаких «справочных» курсов); значение,
    // введённое пользователем поверх предзаполнения, сохраняется как есть.
    final Result<Currency> result = await ref
        .read(currenciesControllerProvider.notifier)
        .addCurrency(info.code);
    if (result.isSuccess && parsed != 1 && mounted) {
      // addCurrency создаёт с курсом 1; если пользователь ввёл иной курс —
      // применяем вторым шагом (create+update короче, чем расширять DAO).
      await ref
          .read(currenciesControllerProvider.notifier)
          .updateRate(info.code, parsed);
    }
    if (result.isFailure && mounted) {
      await showDataFailureSnack(context, result.failure);
    }
  }
}

/// B1.2: правка курса существующей валюты; заголовок «Курс USD → RUB»,
/// подсказка о пересчёте отчётов (D-16). У базовой диалог не открывается.
class _RateDialog extends ConsumerStatefulWidget {
  const _RateDialog({required this.currency, required this.baseCode});

  final Currency currency;
  final String baseCode;

  @override
  ConsumerState<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends ConsumerState<_RateDialog> {
  late final TextEditingController _rate = TextEditingController(
    text: formatRate(widget.currency.rateToBase),
  );

  @override
  void dispose() {
    _rate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool valid = parseRate(_rate.text) != null;
    return AlertDialog(
      title: Text(
        l10n.currencyRateDialogTitle(widget.currency.code, widget.baseCode),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextFormField(
            controller: _rate,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l10n.currencyRateLabel,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.currencyRateRecalcNote,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: valid ? _save : null,
          child: Text(l10n.saveAction),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final double? rate = parseRate(_rate.text);
    if (rate == null) {
      return;
    }
    final Result<Currency> result = await ref
        .read(currenciesControllerProvider.notifier)
        .updateRate(widget.currency.code, rate);
    if (!mounted) {
      return;
    }
    if (result.isSuccess) {
      Navigator.of(context).pop();
    } else {
      await showDataFailureSnack(context, result.failure);
    }
  }
}

/// Диалог подтверждения с настраиваемой кнопкой (showConfirmDialog проекта
/// жёстко пишет «Удалить» — смена базовой требует «Сделать базовой», B1.3).
Future<bool> showCustomConfirmDialog({
  required BuildContext context,
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelAction),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
