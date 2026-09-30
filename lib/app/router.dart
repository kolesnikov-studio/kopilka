import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kopilka/app/home_shell.dart';
import 'package:kopilka/app/routes.dart';
import 'package:kopilka/features/accounts/accounts_screen.dart';
import 'package:kopilka/features/categories/categories_screen.dart';
import 'package:kopilka/features/debts/debt_card_screen.dart';
import 'package:kopilka/features/debts/debts_screen.dart';
import 'package:kopilka/features/reports/reports_screen.dart';
import 'package:kopilka/features/settings/currencies_screen.dart';
import 'package:kopilka/features/settings/hidden_categories_screen.dart';
import 'package:kopilka/features/settings/settings_screen.dart';
import 'package:kopilka/features/transactions/transactions_screen.dart';

/// Роутер приложения: четыре вкладки в [StatefulShellRoute], состояние
/// каждой вкладки сохраняется при переключении.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoutes.accounts,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.accounts,
                name: AppRoutes.accountsName,
                builder: (context, state) => const AccountsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.transactions,
                name: AppRoutes.transactionsName,
                builder: (context, state) => const TransactionsScreen(),
              ),
            ],
          ),
          // Шестая ветка «Долги» (M6/D-89): между «Операциями» и «Категориями».
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.debts,
                name: AppRoutes.debtsName,
                builder: (context, state) => const DebtsScreen(),
                // Карточка долга — вложенный маршрут ветки: tап из списка,
                // живое состояние вкладки переживает навигацию.
                routes: [
                  GoRoute(
                    path: ':id',
                    name: AppRoutes.debtName,
                    builder: (context, state) => DebtCardScreen(
                      debtId: state.pathParameters['id']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.categories,
                name: AppRoutes.categoriesName,
                builder: (context, state) => const CategoriesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.reports,
                name: AppRoutes.reportsName,
                builder: (context, state) => const ReportsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                name: AppRoutes.settingsName,
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  GoRoute(
                    path: 'currencies',
                    name: AppRoutes.currenciesName,
                    builder: (context, state) => const CurrenciesScreen(),
                  ),
                  GoRoute(
                    path: 'hidden-categories',
                    name: AppRoutes.hiddenCategoriesName,
                    builder: (context, state) => const HiddenCategoriesScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );

  ref.onDispose(router.dispose);
  return router;
});
