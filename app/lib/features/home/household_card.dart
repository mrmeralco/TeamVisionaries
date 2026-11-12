// Home: "Your household" from GET /api/household. What the home's electricity use says about the people in
// it: is anyone likely home right now (and is that unusual for this hour), a possible new appliance (a
// sustained rise in use in the last few days), and the usual routine: a 24-hour strip of how often the
// house is busy, wake / away / sleep hours and the always-on load. Every number and Taglish sentence comes
// from the backend. Refetched every 5 minutes so "right now" follows the house. Hidden while loading or if
// the endpoint fails: it's insight, not status.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/ui.dart';

Map<String, (String, IconData, Color)> get _states => {
  'active': ('Someone is home', Icons.person_rounded, C.green),
  'asleep': ('Probably asleep', Icons.bedtime_rounded, C.seriesGrid),
  'away': ('Probably no one home', Icons.directions_walk_rounded, C.orangeText),
  'quiet': ('Quieter than usual', Icons.home_outlined, C.amber),
  'unknown': ('Can’t tell right now', Icons.help_outline_rounded, C.label),
};

/// "7AM", "12PM", "11PM" (hours 0-24 from the backend, local time).
String hourLabel(int h) {
  final x = h % 24;
  return '${x % 12 == 0 ? 12 : x % 12}${x < 12 ? 'AM' : 'PM'}';
}

/// How often "right now" is refetched while Home is open.
const kHouseholdRefresh = Duration(minutes: 5);

class HouseholdCard extends ConsumerStatefulWidget {
  const HouseholdCard({super.key});

  @override
  ConsumerState<HouseholdCard> createState() => _HouseholdCardState();
}

class _HouseholdCardState extends ConsumerState<HouseholdCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(kHouseholdRefresh, (_) => ref.invalidate(householdProvider));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = ref.watch(householdProvider).value;
    if (h == null) return const SizedBox.shrink();
    final now = mapOf(h['now']);
    final loads = listOfMaps(h['new_loads']);
    final routine = mapOf(h['routine']);
    final weekday = routine['weekday'] is Map ? mapOf(routine['weekday']) : null;
    final weekend = routine['weekend'] is Map ? mapOf(routine['weekend']) : null;
    final day = weekday ?? weekend;
    final base = h['baseload'] is Map ? mapOf(h['baseload']) : null;
    final arch = mapOf(h['archetype']);

    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x6, S.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Your household'),
          const SizedBox(height: S.x3),
          SCard(
            padding: const EdgeInsets.all(S.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Now(now),
                for (final l in loads) ...[const SizedBox(height: S.x3), _NewLoad(l)],
                const SizedBox(height: S.x4),
                Text(str(arch['label']), style: ts(13, w: FontWeight.w800, height: 1.3)),
                const SizedBox(height: S.x1),
                Text(str(arch['description']), style: ts(12, height: 1.45, color: C.ink)),
                if (day != null) ...[
                  const SizedBox(height: S.x3),
                  _Strip(day, title: weekday != null ? 'A usual weekday' : 'A usual weekend day'),
                  const SizedBox(height: S.x3),
                  Wrap(
                    spacing: S.x2,
                    runSpacing: S.x2,
                    children: [
                      if (day['wake_hour'] is int) _Chip('Up', hourLabel(day['wake_hour'] as int)),
                      if (day['away'] is Map)
                        _Chip(
                          'Out',
                          '${hourLabel(mapOf(day['away'])['start_hour'] as int)}–'
                              '${hourLabel(mapOf(day['away'])['end_hour'] as int)}',
                        ),
                      if (day['sleep_hour'] is int) _Chip('Lights out', hourLabel(day['sleep_hour'] as int)),
                      _Chip('Busiest', hourLabel(day['peak_hour'] as int)),
                      if (base != null) _Chip('Always on', formatWatts(numOr(base['watts']))),
                    ],
                  ),
                ],
                if (base != null) ...[
                  const SizedBox(height: S.x2),
                  Text(
                    'Always-on use is ${pctNum(base['share_pct'])}% of your home’s use: up to '
                    '${formatPhp(numOr(base['php_month']), whole: true)} a month.',
                    style: ts(11, height: 1.4, color: C.label),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Right now: the state, the backend's sentence, and a flag when it's unusual for this hour.
class _Now extends StatelessWidget {
  const _Now(this.n);
  final Map<String, dynamic> n;

  @override
  Widget build(BuildContext context) {
    final (title, icon, color) = _states[str(n['state'], 'unknown')] ?? _states['unknown']!;
    final unusual = n['unusual'] == true;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.09), borderRadius: R.tile),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: C.card, borderRadius: R.control),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AT HOME NOW',
                  style: ts(9.5, w: FontWeight.w800, color: C.label, spacing: 0.6),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: ts(14, w: FontWeight.w800, height: 1.3, color: color),
                ),
                const SizedBox(height: S.x1),
                Text(str(n['text']), style: ts(12, height: 1.45, color: C.ink)),
                if (unusual) ...[
                  const SizedBox(height: S.x2),
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 15, color: C.amber),
                      const SizedBox(width: S.x1),
                      Flexible(
                        child: Text(
                          'Unusual for this hour',
                          style: ts(11, w: FontWeight.w700, color: C.amber),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A possible new appliance: what, when it started, and what it may add to the bill.
class _NewLoad extends StatelessWidget {
  const _NewLoad(this.l);
  final Map<String, dynamic> l;

  @override
  Widget build(BuildContext context) {
    final since = intOrNull(l['since_ts']);
    final hours = l['start_hour'] is int
        ? '${hourLabel(l['start_hour'] as int)}–${hourLabel(l['end_hour'] as int)}'
        : 'day and night';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(color: C.yellow.withValues(alpha: 0.35), borderRadius: R.tile),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: C.card, borderRadius: R.control),
            child: Icon(Icons.electrical_services_rounded, size: 17, color: C.orangeText),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NEW APPLIANCE?',
                  style: ts(9.5, w: FontWeight.w800, color: C.orangeText, spacing: 0.6),
                ),
                const SizedBox(height: 2),
                Text(
                  '+${formatWatts(numOr(l['added_w']))}, $hours'
                  '${since != null ? ' since ${formatShortDate(since)}' : ''}',
                  style: ts(13, w: FontWeight.w800, height: 1.3),
                ),
                const SizedBox(height: S.x1),
                Text(str(l['text']), style: ts(12, height: 1.45, color: C.ink)),
                const SizedBox(height: S.x2),
                Text(
                  'Adds up to ${formatPhp(numOr(l['php_month']), whole: true)} a month',
                  style: ts(11, w: FontWeight.w700, color: C.orangeText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 24 bars, one per hour: taller and darker = the house is busy at that hour more often.
class _Strip extends StatelessWidget {
  const _Strip(this.day, {required this.title});
  final Map<String, dynamic> day;
  final String title;

  @override
  Widget build(BuildContext context) {
    final pct = (day['home_pct'] as List? ?? const []).map((v) => numOr(v).toDouble()).toList();
    if (pct.length != 24) return const SizedBox.shrink();
    final busy = [
      for (var h = 0; h < 24; h++)
        if (pct[h] >= 50) h,
    ];
    return Semantics(
      label: '$title: busiest hours ${busy.map(hourLabel).join(', ')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: ts(11, w: FontWeight.w600, color: C.label),
          ),
          const SizedBox(height: S.x2),
          SizedBox(
            height: 28,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var h = 0; h < 24; h++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Container(
                        height: 4 + 24 * pct[h] / 100,
                        decoration: BoxDecoration(
                          color: C.orange.withValues(alpha: 0.2 + 0.8 * pct[h] / 100),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: S.x1),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final l in ['12AM', '6AM', '12PM', '6PM', '12AM']) Text(l, style: ts(9.5, color: C.label)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
    decoration: BoxDecoration(color: C.cream, borderRadius: BorderRadius.circular(R.pill)),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label  ',
            style: ts(10.5, w: FontWeight.w600, color: C.label),
          ),
          TextSpan(
            text: value,
            style: ts(10.5, w: FontWeight.w800, color: C.ink),
          ),
        ],
      ),
    ),
  );
}
