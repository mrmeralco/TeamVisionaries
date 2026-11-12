// Alerts: list (newest first), tap marks read, "mark all read". Live alerts arrive over /ws/live.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/placeholder.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(alertsProvider);
    final notifier = ref.read(alertsProvider.notifier);
    return PlaceholderPage(
      onRefresh: () => ref.refresh(alertsProvider.future),
      children: [
        const PlaceholderBanner('Alerts'),
        AsyncView(
          value: alerts,
          onRetry: () => ref.invalidate(alertsProvider),
          data: (a) {
            final list = (a['alerts'] as List).cast<Map<String, dynamic>>();
            return Column(children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: a['unread'] == 0 ? null : notifier.markAllRead,
                  child: Text('Mark all read (${a['unread']})'),
                ),
              ),
              if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Walang alerts.')),
              for (final alert in list)
                ListTile(
                  leading: Icon(
                    alert['read'] == true ? Icons.notifications_none : Icons.notifications_active,
                    color: alert['severity'] == 'critical' ? Colors.red : null,
                  ),
                  title: Text(alert['title'] as String),
                  subtitle: Text('${alert['message']}\n${formatDateTime(alert['ts'] as int)}'),
                  isThreeLine: true,
                  onTap: () {
                    if (alert['read'] != true) notifier.markRead(alert['id'] as int);
                    if (alert['type'] == 'brownout') context.push(Routes.brownout);
                  },
                ),
            ]);
          },
        ),
      ],
    );
  }
}
