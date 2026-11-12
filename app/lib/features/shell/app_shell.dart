// Bottom navigation (Figma) around the five tabs. Keeps /ws/live open for every tab, and handles
// alerts that arrive while the user isn't looking:
//  - app on screen: snackbar on any tab;
//  - app hidden (web background tab): a system notification, if enabled in Settings;
//  - app comes back (any platform): refetch alerts and say how many arrived while it was away
//    (the socket may have been closed in the background, so pushes can be missed).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../../providers/notification_providers.dart';
import '../common/ui.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with WidgetsBindingObserver {
  int? _lastSeenId; // newest alert id when the app went to the background

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  static int _newestId(Map<String, dynamic>? alerts) => ((alerts?['alerts'] as List?) ?? const [])
      .map((a) => (a as Map)['id'])
      .whereType<int>()
      .fold(0, (m, id) => id > m ? id : m);

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) {
      _lastSeenId ??= _newestId(ref.read(alertsProvider).value);
    } else if (s == AppLifecycleState.resumed && _lastSeenId != null) {
      final since = _lastSeenId!;
      _lastSeenId = null;
      _catchUp(since);
    }
  }

  Future<void> _catchUp(int sinceId) async {
    try {
      final a = await ref.refresh(alertsProvider.future);
      final missed = ((a['alerts'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .where((x) => (x['id'] as int) > sinceId && x['read'] != true)
          .toList();
      if (!mounted || missed.isEmpty) return;
      _snack(
        missed.length == 1
            ? '${missed.first['title']}: ${missed.first['message']}'
            : '${missed.length} bagong alert habang wala ka.',
        critical: missed.any((x) => x['severity'] == 'critical'),
      );
    } catch (_) {
      // Offline: the live socket's reconnect will refresh alerts later.
    }
  }

  void _snack(String text, {bool critical = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        persist: false,
        duration: const Duration(seconds: 4),
        showCloseIcon: true,
        closeIconColor: Colors.white,
        backgroundColor: critical ? C.red : C.ink,
        content: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
        action: SnackBarAction(label: 'View alerts', textColor: C.yellow, onPressed: () => widget.shell.goBranch(alertsTab)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = widget.shell;
    final unread = ref.watch(unreadAlertsProvider);
    ref.listen(liveProvider.select((s) => s.lastAlert), (prev, alert) {
      if (alert == null || alert['id'] == prev?['id']) return;
      final notifier = ref.read(systemNotifierProvider);
      if (notifier.appHidden && ref.read(notifyAlertsProvider)) {
        notifier.show('Solaris: ${alert['title']}', '${alert['message']}', tag: 'alert-${alert['id']}');
      } else {
        _snack('${alert['title']}: ${alert['message']}', critical: alert['severity'] == 'critical');
      }
    });

    return Scaffold(
      backgroundColor: C.cream,
      body: shell,
      floatingActionButton: const MiraButton(),
      bottomNavigationBar: SolarisNavBar(
        index: shell.currentIndex,
        badge: unread,
        onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
      ),
    );
  }
}
