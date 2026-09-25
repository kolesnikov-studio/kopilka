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
    this.allowZero = false,
  });

  final TextEditingController controller;
  final void Function(String value)? onSubmitted;

  /// Разрешает ноль как корректное значение (по умолчанию — только > 0).
  final bool allowZero;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AmountInputFormatter()],
      decoration: InputDecoration(
        labelText: l10n.amountLabel,
        errorMaxLines: 2,
      ),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (String? value) => parseAmountToMinor(
            value ?? '',
            allowZero: allowZero,
          ) ==
          null
          ? l10n.amountInvalid
          : null,
      onFieldSubmitted: onSubmitted,
    );
  }
}

/// Пропускает только цифры, пробелы, запятую и точку; не более одного
/// разделителя и не более двух знаков после него.
class AmountInputFormatter extends TextInputFormatter {
  static final RegExp _allowed = RegExp(r'^\d*[\s.,]?\d{0,2}$');

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
