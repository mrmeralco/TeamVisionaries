// Bottom navigation (Figma) around the five tabs. Keeps /ws/live open for every tab, and pops a
// snackbar on any tab when the server pushes a new alert.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../common/ui.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(unreadAlertsProvider);
    ref.listen(liveProvider.select((s) => s.lastAlert), (prev, alert) {
      if (alert == null || alert['id'] == prev?['id']) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: alert['severity'] == 'critical' ? C.red : C.ink,
        content: Text('${alert['title']}: ${alert['message']}', maxLines: 2, overflow: TextOverflow.ellipsis),
        action: SnackBarAction(label: 'Tingnan', textColor: C.yellow, onPressed: () => shell.goBranch(4)),
      ));
    });

    return Scaffold(
      backgroundColor: shell.currentIndex == 0 ? Colors.white : C.cream,
      body: shell,
      bottomNavigationBar: SinagNavBar(
        index: shell.currentIndex,
        badge: unread,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}
