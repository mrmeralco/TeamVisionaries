// Alerts (Figma "Alerts"): GET /api/alerts grouped Today / Earlier, live alerts merged in, tap marks read,
// "Mark all read". Brownout alerts link to the Brownout Advisor.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/ui.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hindi na-mark as read. Subukan ulit.')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider);
    final unread = ref.watch(unreadAlertsProvider);
    final notifier = ref.read(alertsProvider.notifier);

    return RefreshIndicator(
      onRefresh: () => ref.refresh(alertsProvider.future).then((_) {}, onError: (_) {}),
      child: ListView(padding: EdgeInsets.zero, children: [
        SafeArea(
          bottom: false,
          child: PageHeader(
            'Alerts',
            unread == 0 ? 'Updates about your solar, battery and grid.' : '$unread unread · updates about your home power.',
            trailing: unread > 0
                ? TextButton(
                    onPressed: () => _run(context, notifier.markAllRead),
                    child: Text('Mark all read', style: ts(11, w: FontWeight.w700, color: C.orange)),
                  )
                : null,
          ),
        ),
        const SizedBox(height: 24),
        AsyncBody(
          value: alerts,
          onRetry: () => ref.invalidate(alertsProvider),
          data: (a) {
            final list = (a['alerts'] as List).cast<Map<String, dynamic>>();
            if (list.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(40),
                child: Column(children: [
                  const Icon(Icons.notifications_none_rounded, size: 36, color: C.orange),
                  const SizedBox(height: 8),
                  Text('Walang alerts. Maayos ang lahat!', style: ts(12, w: FontWeight.w600)),
                ]),
              );
            }
            final today = list.where((x) => isTodayManila(x['ts'] as int)).toList();
            final earlier = list.where((x) => !isTodayManila(x['ts'] as int)).toList();
            void tap(Map<String, dynamic> x) {
              if (x['read'] != true) _run(context, () => notifier.markRead(x['id'] as int));
            }

            return Column(children: [
              if (today.isNotEmpty) _Group('Today', today, tap),
              if (earlier.isNotEmpty) _Group('Earlier', earlier, tap),
              const SizedBox(height: 24),
            ]);
          },
        ),
      ]),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.label, this.alerts, this.onTap);
  final String label;
  final List<Map<String, dynamic>> alerts;
  final ValueChanged<Map<String, dynamic>> onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$label  ·  ${alerts.length}', style: ts(9, w: FontWeight.w500, spacing: -0.18)),
          const SizedBox(height: 8),
          for (final a in alerts) _AlertTile(a, onTap: () => onTap(a)),
        ]),
      );
}

class _AlertTile extends StatelessWidget {
  const _AlertTile(this.a, {required this.onTap});
  final Map<String, dynamic> a;
  final VoidCallback onTap;

  static (IconData, Color) _look(String type, String severity) => (
        switch (type) {
          'fault' => Icons.error_outline_rounded,
          'brownout' => Icons.power_off_rounded,
          'grid_restored' => Icons.power_rounded,
          'low_battery' => Icons.battery_alert_rounded,
          'high_temp' => Icons.thermostat_rounded,
          'device_offline' => Icons.cloud_off_rounded,
          'device_online' => Icons.cloud_done_rounded,
          _ => Icons.notifications_rounded,
        },
        switch (severity) { 'critical' => C.red, 'warning' => C.amber, _ => C.green },
      );

  @override
  Widget build(BuildContext context) {
    final read = a['read'] == true;
    final (icon, color) = _look(a['type'] as String, a['severity'] as String);
    final ts0 = a['ts'] as int;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: read ? Colors.white.withValues(alpha: 0.6) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: read ? Colors.transparent : color.withValues(alpha: 0.45), width: 0.8),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(5)),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(a['title'] as String, style: ts(11, w: read ? FontWeight.w500 : FontWeight.w700, spacing: -0.18))),
                    if (!read) Container(width: 7, height: 7, decoration: const BoxDecoration(color: C.orange, shape: BoxShape.circle)),
                  ]),
                  const SizedBox(height: 4),
                  Text(a['message'] as String, style: ts(10, height: 1.35, spacing: -0.18, color: read ? C.muted : C.ink)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: Text('${formatClock(ts0)}  ·  ${formatAgo(ts0)}',
                          overflow: TextOverflow.ellipsis, style: ts(8, color: C.muted, spacing: -0.14)),
                    ),
                    if (a['type'] == 'brownout')
                      GestureDetector(
                        onTap: () => context.push(Routes.brownout),
                        child: Text('Brownout Advisor →', style: ts(9, w: FontWeight.w700, color: C.orange)),
                      ),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
