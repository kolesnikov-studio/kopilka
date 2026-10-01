import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kopilka/core/money.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Поле ввода денежной суммы: принимает «1 234,56», отдаёт минорные единицы.
///
/// Валидация — по правилам [parseAmountToMinor]: положительная сумма
/// не более чем с двумя знаками после разделителя; с `allowZero` ноль
/// тоже корректен (поле «новый начальный баланс» при редактировании счёта).
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.controller,
    this.onSubmitted,
    this.onChanged,
    this.allowZero = false,
    this.allowEmpty = false,
    this.exponent = defaultCurrencyExponent,
    this.hintText,
    this.suffixText,
    this.labelText,
    this.invalidText,
  });

  final TextEditingController controller;
  final void Function(String value)? onSubmitted;

  /// Разрешает ноль как корректное значение (по умолчанию — только > 0).
  final bool allowZero;

  /// Разрешает пустое поле как корректное — для необязательных сумм
  /// («пустое = 0», D-82: переплата долга): вызывающий код сам трактует
  /// пустоту как ноль/отсутствие. По умолчанию пустота — ошибка.
  final bool allowEmpty;

  /// Число знаков после разделителя у валюты поля (D-15): 2 — копейки,
  /// 0 — без дробной части, 3 — динары. По умолчанию 2.
  final int exponent;

  /// Подсказка внутри пустого поля (U12: «0,00» в начальном балансе счёта);
  /// null — без подсказки.
  final String? hintText;

  /// Символ валюты в суффиксе поля (B3): «какая валюта у этой суммы»
  /// видна всегда; null — без суффикса (M1/M2-вызовы без контекста валют).
  final String? suffixText;

  /// Свой заголовок поля (B4.1: «Списано»/«Зачислено» у перевода);
  /// null — стандартный «Сумма».
  final String? labelText;

  /// Свой текст ошибки валидации (D-90: спеченные тексты суммы формы
  /// долга — `debtAmountInvalid`/`debtExtraInvalid` вместо общего
  /// amountInvalid); null — стандартный текст. Семантику (> 0 / >= 0)
  /// не меняет — только текст.
  final String? invalidText;

  /// Вызывается при каждой правке текста пользователем (B4.1: пересчёт
  /// расчётной строки курса и предзаполнения второй суммы перевода);
  /// программная смена `controller.text` её не вызывает.
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter(exponent: exponent)],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: labelText ?? l10n.amountLabel,
        hintText: hintText,
        suffixText: suffixText,
        errorMaxLines: 2,
      ),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (String? value) {
        final String text = value ?? '';
        if (allowEmpty && text.trim().isEmpty) {
          return null;
        }
        return parseAmountToMinor(
                  text,
                  allowZero: allowZero,
                  exponent: exponent,
                ) ==
                null
            ? (invalidText ?? l10n.amountInvalid)
            : null;
      },
      onFieldSubmitted: onSubmitted,
    );
  }
}

/// Пропускает только цифры, пробелы, запятую и точку; при экспонентах > 0
/// пробел — разделитель групп любой длины (парсер снимает все пробелы:
/// «4 000» = 4000), разделитель не более одного и не более [exponent]
/// знаков после него (D-15: экспонент валюты управляет вводом); экспонент
/// 0 (целые валюты) — жёстче: только цифры, без разделителя и пробелов.
class AmountInputFormatter extends TextInputFormatter {
  AmountInputFormatter({this.exponent = defaultCurrencyExponent})
    : _allowed = exponent > 0
          ? RegExp(
              r'^\d+([ \u00A0\u202F]\d+)*(\.\d{0,' +
                  exponent.toString() +
                  r'})?$',
            )
          : RegExp(r'^\d*$');

  final RegExp _allowed;

  final int exponent;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text.replaceAll(',', '.');
    if (newValue.text.isEmpty || _allowed.hasMatch(text)) {
      return newValue;
    }
    return oldValue;
  }
}
