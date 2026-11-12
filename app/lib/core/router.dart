// Routes: bottom nav Home, Energy, Bill, Alerts. Ask Mira (from the floating button on every tab),
// Settings and the Brownout Advisor open on top. Each tab keeps its own navigation stack.
// First run: everything redirects to /welcome (the household setup question) until it is answered;
// Settings stays reachable from there, to type the server address first.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/alerts/alerts_screen.dart';
import '../features/ask/ask_screen.dart';
import '../features/bill/bill_screen.dart';
import '../features/common/ui.dart' show GlassBackdrop;
import '../features/brownout/brownout_screen.dart';
import '../features/energy/energy_screen.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/app_shell.dart';
import '../providers/onboarding_providers.dart';

class Routes {
  static const home = '/home';
  static const energy = '/energy';
  static const bill = '/bill';
  static const ask = '/ask';
  static const alerts = '/alerts';
  static const settings = '/settings';
  static const brownout = '/brownout';
  static const welcome = '/welcome';
}

final _rootKey = GlobalKey<NavigatorState>();

GoRouter buildRouter() => GoRouter(
      navigatorKey: _rootKey,
      initialLocation: Routes.home,
      redirect: (context, state) {
        final done = ProviderScope.containerOf(context, listen: false).read(onboardedProvider);
        final at = state.matchedLocation;
        if (!done && at != Routes.welcome && at != Routes.settings) return Routes.welcome;
        if (done && at == Routes.welcome) return Routes.home;
        return null;
      },
      routes: [
        GoRoute(
          path: Routes.welcome,
          parentNavigatorKey: _rootKey,
          builder: (context, state) => const OnboardingScreen(),
        ),
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AppShell(shell: shell),
          branches: [
            _branch(Routes.home, const HomeScreen()),
            _branch(Routes.energy, const EnergyScreen()),
            _branch(Routes.bill, const BillScreen()),
            _branch(Routes.alerts, const AlertsScreen()),
          ],
        ),
        GoRoute(
          path: Routes.ask,
          parentNavigatorKey: _rootKey,
          builder: (context, state) => const AskScreen(),
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

// The glass backdrop goes inside each tab's page: the page route paints an opaque surface behind
// its content, so a backdrop around the whole shell would be hidden under every tab.
StatefulShellBranch _branch(String path, Widget screen) => StatefulShellBranch(
      routes: [GoRoute(path: path, builder: (context, state) => GlassBackdrop(child: screen))],
    );
