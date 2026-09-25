import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:kopilka/l10n/gen/app_localizations.dart';

/// Ширина окна, с которой навигация переезжает в боковой rail (десктоп).
const double railBreakpoint = 700;

/// Ширина, с которой rail разворачивается с подписями.
const double extendedRailBreakpoint = 1100;

/// Один пункт навигации: подпись и иконки в обычном и выбранном состоянии.
class ShellDestination {
  const ShellDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// Оболочка с навигацией: нижняя панель на телефоне, боковой rail на десктопе.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Пункты навигации в порядке веток роутера (`lib/app/router.dart`).
  static List<ShellDestination> destinationsFor(AppLocalizations l10n) {
    return <ShellDestination>[
      ShellDestination(
        label: l10n.navAccounts,
        icon: Icons.account_balance_wallet_outlined,
        selectedIcon: Icons.account_balance_wallet,
      ),
      ShellDestination(
        label: l10n.navTransactions,
        icon: Icons.swap_horiz_outlined,
        selectedIcon: Icons.swap_horiz,
      ),
      ShellDestination(
        label: l10n.navCategories,
        icon: Icons.category_outlined,
        selectedIcon: Icons.category,
      ),
      ShellDestination(
        label: l10n.navReports,
        icon: Icons.pie_chart_outline,
        selectedIcon: Icons.pie_chart,
      ),
      ShellDestination(
        label: l10n.navSettings,
        icon: Icons.settings_outlined,
        selectedIcon: Icons.settings,
      ),
    ];
  }

  void _goToBranch(int index) {
    navigationShell.goBranch(
      index,
      // Повторный тап по активной вкладке возвращает её к корневому экрану.
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final double width = MediaQuery.sizeOf(context).width;
    final List<ShellDestination> destinations = destinationsFor(
      AppLocalizations.of(context),
    );
    final int index = navigationShell.currentIndex;
    final String title = destinations[index].label;

    if (width >= railBreakpoint) {
      final bool extended = width >= extendedRailBreakpoint;
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Row(
          children: [
            NavigationRail(
              extended: extended,
              labelType: extended
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              selectedIndex: index,
              onDestinationSelected: _goToBranch,
              destinations: [
                for (final ShellDestination destination in destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: Text(destination.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: navigationShell),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: _goToBranch,
        destinations: [
          for (final ShellDestination destination in destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}
