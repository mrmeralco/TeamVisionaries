// Alerts (Figma "Alerts"): GET /api/alerts grouped Today / Earlier, live alerts merged in, severity filter,
// "Mark all read". Tapping an alert opens its explanation (alert_detail.dart) and marks it read.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/ui.dart';
import 'alert_detail.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({super.key});
  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  String? _severity; // null = all

  Future<void> _markAll() async {
    try {
      await ref.read(alertsProvider.notifier).markAllRead();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hindi na-mark as read. Subukan ulit.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final alerts = ref.watch(alertsProvider);
    final unread = ref.watch(unreadAlertsProvider);

    return RefreshIndicator(
      onRefresh: () => ref.refresh(alertsProvider.future).then((_) {}, onError: (_) {}),
      child: ListView(padding: EdgeInsets.zero, children: [
        SafeArea(
          bottom: false,
          child: PageHeader(
            'Alerts',
            unread == 0
                ? 'View your latest notifications and updates.'
                : '${badgeText(unread)} unread · your latest notifications and updates.',
            trailing: unread > 0
                ? TextButton(onPressed: _markAll, child: const Text('Mark all read'))
                : null,
          ),
        ),
        const SizedBox(height: S.x3),
        AsyncBody(
          value: alerts,
          onRetry: () => ref.invalidate(alertsProvider),
          data: (a) {
            final all = listOfMaps(a['alerts']);
            if (all.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(S.gutter),
                child: SCard(
                  padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x8),
                  child: Column(children: [
                    const Icon(Icons.notifications_none_rounded, size: 36, color: C.orangeDeep),
                    const SizedBox(height: S.x2),
                    Text('Walang alerts. Maayos ang lahat!', style: ts(13, w: FontWeight.w700), textAlign: TextAlign.center),
                    const SizedBox(height: S.x1),
                    Text(
                      'Dito lalabas ang brownout, fault at low battery.',
                      style: ts(12, color: C.muted),
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              );
            }
            final counts = <String, int>{};
            for (final x in all) {
              final s = str(x['severity'], 'info');
              counts[s] = (counts[s] ?? 0) + 1;
            }
            final list = _severity == null ? all : all.where((x) => str(x['severity'], 'info') == _severity).toList();
            bool today(Map<String, dynamic> x) {
              final t = intOrNull(x['ts']);
              return t != null && isTodayManila(t);
            }

            final todays = list.where(today).toList();
            final earlier = list.where((x) => !today(x)).toList();
            void open(Map<String, dynamic> x) => showAlertDetail(context, ref, x);

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (counts.length > 1)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(S.gutter, 0, S.gutter, S.x2),
                  child: Row(children: [
                    _Filter('All', all.length, _severity == null, () => setState(() => _severity = null)),
                    for (final s in ['critical', 'warning', 'info'])
                      if (counts[s] != null)
                        _Filter(severityLabel(s), counts[s]!, _severity == s, () => setState(() => _severity = s)),
                  ]),
                ),
              if (todays.isNotEmpty) _Group('Today', todays, open),
              if (earlier.isNotEmpty) _Group('Earlier', earlier, open),
              const SizedBox(height: kFabClearance),
            ]);
          },
        ),
      ]),
    );
  }
}

class _Filter extends StatelessWidget {
  const _Filter(this.label, this.count, this.selected, this.onTap);
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: S.x2),
        child: ChoiceChip(
          label: Text('$label  ${badgeText(count)}'),
          labelStyle: ts(12, w: FontWeight.w700, color: selected ? Colors.white : C.ink),
          selected: selected,
          showCheckmark: false,
          selectedColor: C.brandDark,
          side: BorderSide(color: selected ? C.brandDark : C.orangeLine, width: 0.5),
          onSelected: (_) => onTap(),
        ),
      );
}

/// Figma: section title, then one white card with the alerts separated by thin lines.
class _Group extends StatelessWidget {
  const _Group(this.label, this.alerts, this.onTap);
  final String label;
  final List<Map<String, dynamic>> alerts;
  final ValueChanged<Map<String, dynamic>> onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(S.gutter, S.x2, S.gutter, S.x4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionTitle('$label  ·  ${alerts.length}'),
          const SizedBox(height: S.x2),
          Material(
            color: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: R.card, side: kCardLine),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (var i = 0; i < alerts.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16, color: C.divider),
                _AlertTile(alerts[i], onTap: () => onTap(alerts[i])),
              ],
            ]),
          ),
        ]),
      );
}

class _AlertTile extends StatelessWidget {
  const _AlertTile(this.a, {required this.onTap});
  final Map<String, dynamic> a;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final read = a['read'] == true;
    final type = str(a['type']);
    final (icon, color) = alertLook(type, str(a['severity'], 'info'));
    final ts0 = intOrNull(a['ts']);
    final title = str(a['title'], 'Alert');
    final message = str(a['message']);
    final brownoutLink = type == 'brownout' || type == 'low_battery';

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x2, S.x1),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: color.withValues(alpha: read ? 0.1 : 0.16), borderRadius: R.control),
            child: Icon(icon, size: 18, color: color, semanticLabel: severityLabel(str(a['severity'], 'info'))),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(title, style: ts(13, w: read ? FontWeight.w600 : FontWeight.w800, spacing: -0.1)),
                ),
                if (!read)
                  Semantics(
                    label: 'Unread',
                    child: Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: const BoxDecoration(color: C.orange, shape: BoxShape.circle),
                    ),
                  ),
              ]),
              const SizedBox(height: S.x1),
              Text(message, style: ts(13, height: 1.4, color: read ? C.muted : C.ink)),
              // Wrap: at large text sizes the link moves under the time instead of overflowing.
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(ts0 == null ? '' : formatWhen(ts0), style: ts(11, color: C.muted)),
                  brownoutLink
                      ? LinkButton('Brownout Advisor', size: 11, onTap: () => context.push(Routes.brownout))
                      : LinkButton('See explanation', size: 11, onTap: onTap),
                ],
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
