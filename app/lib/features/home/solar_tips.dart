// Home: "Solar tips" from GET /api/tips. What this month's solar spared the air (CO₂ avoided), then tips
// that move the household's use onto the sun: right now (live surplus / grid draw), today (the sunniest
// 3 hours, a cloudy tomorrow), habits from the last 30 days, and one general tip a day. Every number in the
// text comes from the backend. Refetched when the live state changes (e.g. solar → grid), so the "right
// now" tips follow the house. Hidden while loading or if the endpoint fails: it's advice, not status.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../common/ui.dart';

/// Tips shown before "Show more".
const kTipsShown = 3;

const _kinds = {
  'now': ('Right now', Icons.bolt_rounded),
  'today': ('Today', Icons.wb_sunny_rounded),
  'habit': ('Habit', Icons.autorenew_rounded),
  'general': ('Tip of the day', Icons.lightbulb_outline_rounded),
};

class SolarTips extends ConsumerStatefulWidget {
  const SolarTips({super.key});

  @override
  ConsumerState<SolarTips> createState() => _SolarTipsState();
}

class _SolarTipsState extends ConsumerState<SolarTips> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(liveProvider.select((s) => s.state), (prev, next) {
      if (prev != null && next != prev) ref.invalidate(tipsProvider);
    });
    final t = ref.watch(tipsProvider).value;
    if (t == null) return const SizedBox.shrink();
    final tips = listOfMaps(t['tips']);
    final impact = t['impact'] is Map ? mapOf(t['impact']) : null;
    if (tips.isEmpty && impact == null) return const SizedBox.shrink();
    final shown = _all ? tips : tips.take(kTipsShown).toList();
    final hidden = tips.length - shown.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x6, S.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Solar tips'),
          const SizedBox(height: S.x3),
          SCard(
            padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (impact != null) ...[_Impact(impact), const SizedBox(height: S.x3)],
                for (final (i, tip) in shown.indexed) ...[
                  if (i > 0) const SizedBox(height: S.x2),
                  _Tip(tip),
                ],
                if (hidden > 0 || _all && tips.length > kTipsShown)
                  LinkButton(
                    _all ? 'Show fewer tips' : 'Show $hidden more ${hidden == 1 ? 'tip' : 'tips'}',
                    onTap: () => setState(() => _all = !_all),
                  )
                else
                  const SizedBox(height: S.x2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// This month's clean energy: kg of CO₂ the grid would have emitted, kWh from the panels, trees.
class _Impact extends StatelessWidget {
  const _Impact(this.i);
  final Map<String, dynamic> i;

  @override
  Widget build(BuildContext context) {
    final co2 = numOr(i['co2_avoided_kg']);
    final kwh = numOr(i['solar_kwh']);
    final trees = (i['trees'] as num?)?.toInt() ?? 0;
    final share = i['clean_share_pct'] as num?;
    final facts = [
      '${kwh.toStringAsFixed(kwh >= 100 ? 0 : 1)} kWh of clean solar',
      if (share != null) '${pctNum(share)}% of your home ran on the sun',
    ].join(' · ');
    final co2Text = co2 >= 1000 ? (co2 / 1000).toStringAsFixed(2) : co2.toStringAsFixed(0);
    final co2Unit = co2 >= 1000 ? 't CO₂' : 'kg CO₂';

    return Semantics(
      label: 'This month: $co2Text $co2Unit avoided. $facts.'
          '${trees > 0 ? ' Like $trees ${trees == 1 ? 'tree' : 'trees'} growing for a year.' : ''}',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(S.x3),
        decoration: BoxDecoration(color: C.green.withValues(alpha: 0.09), borderRadius: R.tile),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: C.card, borderRadius: R.control),
              child: Icon(Icons.eco_rounded, size: 20, color: C.green),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Avoided this month', style: ts(11, w: FontWeight.w600, color: C.label)),
                  const SizedBox(height: 2),
                  Reading(co2Text, co2Unit, size: 22, valueColor: C.green),
                  const SizedBox(height: S.x1),
                  Text(facts, style: ts(11, height: 1.35, color: C.ink)),
                  if (trees > 0) ...[
                    const SizedBox(height: 2),
                    Text(
                      'Like $trees ${trees == 1 ? 'tree' : 'trees'} growing for a year',
                      style: ts(11, w: FontWeight.w700, color: C.green),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.t);
  final Map<String, dynamic> t;

  @override
  Widget build(BuildContext context) {
    final kind = str(t['kind'], 'general');
    final (label, icon) = _kinds[kind] ?? _kinds['general']!;
    final now = kind == 'now';
    final evidence = listOfMaps(t['evidence']);
    final save = t['savings_php_month'] as num?;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(
        color: now ? C.yellow.withValues(alpha: 0.35) : C.cream,
        borderRadius: R.tile,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: C.card, borderRadius: R.control),
            child: Icon(icon, size: 17, color: C.orangeText),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label.toUpperCase(), style: ts(9.5, w: FontWeight.w800, color: C.orangeText, spacing: 0.6)),
                const SizedBox(height: 2),
                Text(str(t['title']), style: ts(13, w: FontWeight.w800, height: 1.3)),
                const SizedBox(height: S.x1),
                Text(str(t['body']), style: ts(12, height: 1.45, color: C.ink)),
                if (evidence.isNotEmpty) ...[
                  const SizedBox(height: S.x2),
                  Wrap(spacing: S.x2, runSpacing: S.x2, children: [
                    for (final e in evidence)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
                        decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(R.pill)),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: '${str(e['label'])}  ', style: ts(10.5, w: FontWeight.w600, color: C.label)),
                          TextSpan(text: str(e['value']), style: ts(10.5, w: FontWeight.w800, color: C.ink)),
                        ])),
                      ),
                  ]),
                ],
                if (save != null) ...[
                  const SizedBox(height: S.x2),
                  Text(
                    'Saves up to ${formatPhp(save, whole: true)} a month',
                    style: ts(11, w: FontWeight.w700, color: C.orangeText),
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
