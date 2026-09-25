import 'package:flutter/material.dart';
import 'package:kopilka/app/widgets/placeholder_view.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Экран «Отчёты». Заглушка: в M2 здесь появятся отчёты и бюджеты.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PlaceholderView(
      icon: Icons.pie_chart_outline,
      description: AppLocalizations.of(context).reportsPlaceholder,
    );
  }
}
