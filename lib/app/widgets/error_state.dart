import 'package:flutter/material.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Единое состояние ошибки экрана/карточки (U2): текст ошибки и кнопка
/// «Повторить». Поток DAO живой и восстанавливается сам, но кнопка даёт
/// пользователю действие и снимает вид «замершего экрана».
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, this.onRetry});

  /// Повтор (например, повторная подписка на поток); null — кнопка скрыта.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              l10n.errorUnknown,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retryAction),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Единое пустое состояние со CTA (U1): текст «пусто» и приглашение к
/// действию; CTA-кнопка ведёт в ту же форму, что и FAB экрана.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.text,
    required this.ctaLabel,
    this.onCta,
  });

  final String text;
  final String ctaLabel;

  /// Действие CTA; null — кнопка скрыта (остаётся один текст).
  final VoidCallback? onCta;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onCta != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onCta,
                icon: const Icon(Icons.add),
                label: Text(ctaLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
