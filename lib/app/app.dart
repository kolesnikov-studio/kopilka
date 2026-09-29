import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kopilka/app/router.dart';
import 'package:kopilka/app/theme.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Корень приложения: локализации, тема, режим темы и роутинг.
class KopilkaApp extends ConsumerWidget {
  const KopilkaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final ThemePair themePair = ref.watch(themePairProvider);
    final ThemeMode themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      onGenerateTitle: (BuildContext context) =>
          AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: themePair.light,
      darkTheme: themePair.dark,
      themeMode: themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    );
  }
}
