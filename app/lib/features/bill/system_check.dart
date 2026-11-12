// Bill & Savings: "System check" from GET /api/upgrade. Does the solar, battery and inverter still fit how
// this household uses electricity? Verdict, current system, and each recommendation with the household's own
// numbers behind it, plus a rough cost/savings/payback that's clearly labelled as an estimate.
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../common/ui.dart';

const _icons = {
  'battery': Icons.battery_charging_full_rounded,
  'solar': Icons.solar_power_rounded,
  'inverter': Icons.electrical_services_rounded,
  'usage': Icons.trending_up_rounded,
};

class SystemCheckCard extends StatelessWidget {
  const SystemCheckCard(this.u, {super.key});
  final Map<String, dynamic> u;

  @override
  Widget build(BuildContext context) {
    final verdict = str(u['verdict'], 'unknown');
    final sys = mapOf(u['system']);
    final usage = mapOf(u['usage']);
    final recs = listOfMaps(u['recommendations']);
    final (badge, badgeColor, badgeIcon) = switch (verdict) {
      'ok' => ('Fits your use', C.green, Icons.check_circle_rounded),
      'consider' => ('Upgrade worth considering', C.orangeText, Icons.upgrade_rounded),
      _ => ('Not enough data yet', C.muted, Icons.hourglass_empty_rounded),
    };
    final days = usage['days'];

    return SCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const CardTitle('System check'),
        const SizedBox(height: 2),
        Text(days == null ? 'Based on your own readings' : 'Based on your last $days days of readings',
            style: ts(10, color: C.muted)),
        const SizedBox(height: S.x3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
          decoration: BoxDecoration(color: badgeColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(R.pill)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(badgeIcon, size: 15, color: badgeColor),
            const SizedBox(width: 5),
            Flexible(child: Text(badge, style: ts(11, w: FontWeight.w800, color: badgeColor))),
          ]),
        ),
        const SizedBox(height: S.x2),
        Text(str(u['headline']), style: ts(12.5, height: 1.45)),
        const SizedBox(height: S.x2),
        Text(
          'Your system: ${_n(sys['pv_kwp'])} kWp solar · ${_n(sys['battery_kwh'])} kWh battery · ${_n(sys['inverter_kw'])} kW inverter',
          style: ts(10.5, w: FontWeight.w600, color: C.label),
        ),
        for (final r in recs) ...[const SizedBox(height: S.x3), _Rec(r)],
        if (recs.any((r) => r['cost_php'] != null || r['savings_php_month'] != null)) ...[
          const SizedBox(height: S.x3),
          Text(
            'Savings and prices are rough estimates from your data and typical installed prices. '
            'Ask your installer for an exact quote.',
            style: ts(10, height: 1.4, color: C.muted),
          ),
        ],
      ]),
    );
  }
}

String _n(Object? v) {
  final x = numOr(v);
  return x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toString();
}

class _Rec extends StatelessWidget {
  const _Rec(this.r);
  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final evidence = listOfMaps(r['evidence']);
    final save = r['savings_php_month'] as num?;
    final cost = r['cost_php'] as num?;
    final payback = r['payback_years'] as num?;
    final money = [
      if (save != null) '~${formatPhp(save, whole: true)}/month saved',
      if (cost != null) '~${formatPhp(cost, whole: true)} installed',
      if (payback != null) 'pays back in ~${pctNum(payback)} yrs',
    ];

    return Container(
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(color: C.cream, borderRadius: R.tile),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: Colors.white, borderRadius: R.control),
            child: Icon(_icons[r['id']] ?? Icons.tips_and_updates_outlined, size: 17, color: C.orangeText),
          ),
          const SizedBox(width: S.x3),
          Expanded(child: Text(str(r['title']), style: ts(13, w: FontWeight.w800))),
          const SizedBox(width: S.x2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(R.pill)),
            child: Text(str(r['add']), style: ts(12, w: FontWeight.w800, color: C.orangeText)),
          ),
        ]),
        const SizedBox(height: S.x2),
        Text(str(r['reason']), style: ts(12, height: 1.45, color: C.ink)),
        if (evidence.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          Wrap(spacing: S.x2, runSpacing: S.x2, children: [
            for (final e in evidence)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(R.pill)),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${str(e['label'])}  ', style: ts(10.5, w: FontWeight.w600, color: C.label)),
                  TextSpan(text: str(e['value']), style: ts(10.5, w: FontWeight.w800, color: C.ink)),
                ])),
              ),
          ]),
        ],
        if (money.isNotEmpty) ...[
          const SizedBox(height: S.x2),
          Text(money.join('  ·  '), style: ts(11, w: FontWeight.w700, color: C.orangeText)),
        ],
      ]),
    );
  }
}
