// Routes (from the plan): bottom nav Home, Energy, Bill, Ask Mira, Alerts; Settings and the
// Brownout Advisor open on top. Each tab keeps its own navigation stack.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/alerts/alerts_screen.dart';
import '../features/ask/ask_screen.dart';
import '../features/bill/bill_screen.dart';
import '../features/brownout/brownout_screen.dart';
import '../features/energy/energy_screen.dart';
import '../features/home/home_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/app_shell.dart';

class Routes {
  static const home = '/home';
  static const energy = '/energy';
  static const bill = '/bill';
  static const ask = '/ask';
  static const alerts = '/alerts';
  static const settings = '/settings';
  static const brownout = '/brownout';
}

final _rootKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() => GoRouter(
      navigatorKey: _rootKey,
      initialLocation: Routes.home,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AppShell(shell: shell),
          branches: [
            _branch(Routes.home, const HomeScreen()),
            _branch(Routes.energy, const EnergyScreen()),
            _branch(Routes.bill, const BillScreen()),
            _branch(Routes.ask, const AskScreen()),
            _branch(Routes.alerts, const AlertsScreen()),
          ],
        ),
        GoRoute(
          path: Routes.settings,
          parentNavigatorKey: _rootKey,
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: Routes.brownout,
          parentNavigatorKey: _rootKey,
          builder: (context, state) => const BrownoutScreen(),
        ),
      ],
    );

StatefulShellBranch _branch(String path, Widget screen) => StatefulShellBranch(
      routes: [GoRoute(path: path, builder: (context, state) => screen)],
    );
