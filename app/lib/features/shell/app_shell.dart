// Bottom navigation + top bar with the live-link indicator. Keeps /ws/live open for every tab.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../../providers/server_providers.dart';
import '../../services/live_connection.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _titles = ['Sinag', 'Energy', 'Bill', 'Ask Sinag', 'Alerts'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadAlertsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[shell.currentIndex]),
        actions: [
          const LinkIndicator(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
        ],
      ),
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          const NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Energy'),
          const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Bill'),
          const NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Ask'),
          NavigationDestination(
            icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications_outlined)),
            selectedIcon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.notifications)),
            label: 'Alerts',
          ),
        ],
      ),
    );
  }
}

/// Small dot + label: Live / Connecting / Reconnecting / Mock.
class LinkIndicator extends ConsumerWidget {
  const LinkIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(liveProvider.select((s) => s.link));
    final mock = ref.watch(serverConfigProvider.select((c) => c.useMock));
    final (color, label) = switch (link) {
      LinkStatus.connected => (Colors.green, mock ? 'Mock' : 'Live'),
      LinkStatus.connecting => (Colors.amber, 'Connecting'),
      LinkStatus.waiting => (Colors.red, 'Reconnecting'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ]),
    );
  }
}
