// "Go solar" from GET /api/solar-plan, for a home without solar. Not on Home: a meter-only home sees only
// its use, bill and ways to save (onboarding: "Smart meter lang"). Kept for a future, opt-in "Go solar" page. How big a solar setup this household's own
// use needs: the recommended option first (grid-tie, or hybrid with a battery when most use is at night),
// then the other, each with panels, inverter, battery, how much of the home it covers, the bill after,
// savings, rough cost and payback. Every number and Taglish sentence comes from the backend.
//
// Below it, kept apart and labelled "Sponsored": ad slots for installers, brands and financing. Until real
// sponsors are configured on the server (SPONSORS_FILE) they are placeholders. The plan never depends on
// them. Hidden for homes with solar, while loading, or if the endpoint fails.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/ui.dart';

const _sponsorIcons = {
  'installer': Icons.handyman_rounded,
  'panel_brand': Icons.solar_power_rounded,
  'inverter_brand': Icons.electrical_services_rounded,
  'battery_brand': Icons.battery_charging_full_rounded,
  'financing': Icons.account_balance_rounded,
};

String _num(num v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

class SolarPlanCard extends ConsumerWidget {
  const SolarPlanCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(solarPlanProvider).value;
    if (p == null || p['has_solar'] == true) return const SizedBox.shrink();
    final options = listOfMaps(p['options']);
    final usage = p['usage'] is Map ? mapOf(p['usage']) : null;
    final sponsors = listOfMaps(p['sponsors']);

    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x6, S.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Go solar'),
          const SizedBox(height: S.x3),
          SCard(
            padding: const EdgeInsets.all(S.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(str(p['headline']), style: ts(13, w: FontWeight.w700, height: 1.4)),
                if (usage != null) ...[
                  const SizedBox(height: S.x2),
                  Text(
                    'Your home: ${_num(numOr(usage['kwh_day']))} kWh a day · ${usage['night_share_pct']}% at night · '
                    'about ${formatPhp(numOr(usage['bill_php_month']), whole: true)} a month now',
                    style: ts(11, height: 1.4, color: C.label),
                  ),
                ],
                for (final o in options) ...[const SizedBox(height: S.x3), _Option(o)],
                if (options.isNotEmpty) ...[
                  const SizedBox(height: S.x3),
                  Text(str(p['disclaimer']), style: ts(10.5, height: 1.4, color: C.label)),
                ],
              ],
            ),
          ),
          if (sponsors.isNotEmpty) ...[const SizedBox(height: S.x3), _Sponsors(sponsors)],
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option(this.o);
  final Map<String, dynamic> o;

  @override
  Widget build(BuildContext context) {
    final rec = o['recommended'] == true;
    final batt = o['battery_kwh'] as num?;
    final backup = o['backup_hours'] as num?;
    final payback = o['payback_years'] as num?;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(
        color: rec ? C.yellow.withValues(alpha: 0.35) : C.cream,
        borderRadius: R.tile,
        border: rec ? Border.all(color: C.orange, width: 1) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(str(o['title']), style: ts(13, w: FontWeight.w800, height: 1.3)),
              ),
              if (rec)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: 2),
                  decoration: BoxDecoration(color: C.brandDark, borderRadius: BorderRadius.circular(R.pill)),
                  child: Text(
                    'RECOMMENDED',
                    style: ts(9.5, w: FontWeight.w800, color: Colors.white, spacing: 0.6),
                  ),
                ),
            ],
          ),
          const SizedBox(height: S.x2),
          Reading(_num(numOr(o['pv_kwp'])), 'kWp', size: 22, valueColor: C.orangeDeep),
          Text(
            '${o['panels']} × ${o['panel_w']} W panels · about ${o['roof_m2']} m² of roof',
            style: ts(11, height: 1.4, color: C.ink),
          ),
          const SizedBox(height: S.x2),
          Wrap(
            spacing: S.x2,
            runSpacing: S.x2,
            children: [
              _Chip('Inverter', '${_num(numOr(o['inverter_kw']))} kW'),
              _Chip('Battery', batt != null ? '${_num(batt)} kWh' : 'None'),
              _Chip('Covers', '${o['covers_pct']}% of use'),
              if (backup != null) _Chip('Brownout backup', '~${_num(backup)} h'),
            ],
          ),
          const SizedBox(height: S.x3),
          Row(
            children: [
              Expanded(child: _Money('Saves', '${formatPhp(numOr(o['savings_php_month']), whole: true)}/mo')),
              Expanded(child: _Money('Rough cost', formatPhp(numOr(o['cost_php']), whole: true))),
              Expanded(child: _Money('Payback', payback != null ? '~${_num(payback)} yrs' : '—')),
            ],
          ),
          const SizedBox(height: S.x2),
          Text(
            'Bill ${formatPhp(numOr(o['bill_before_php_month']), whole: true)} → '
            '${formatPhp(numOr(o['bill_after_php_month']), whole: true)} a month',
            style: ts(11, w: FontWeight.w700, color: C.green),
          ),
          const SizedBox(height: S.x1),
          Text(str(o['why']), style: ts(12, height: 1.45, color: C.ink)),
        ],
      ),
    );
  }
}

class _Money extends StatelessWidget {
  const _Money(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: ts(10.5, w: FontWeight.w600, color: C.label),
      ),
      const SizedBox(height: 2),
      Text(value, style: ts(13, w: FontWeight.w800)),
    ],
  );
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
    decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(R.pill)),
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

/// Ad slots, clearly apart from the plan. Placeholders show where a sponsor would go.
class _Sponsors extends StatelessWidget {
  const _Sponsors(this.items);
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'SPONSORED',
          style: ts(9.5, w: FontWeight.w800, color: C.label, spacing: 0.6),
        ),
        const SizedBox(height: S.x2),
        for (final (i, s) in items.indexed) ...[if (i > 0) const SizedBox(height: S.x2), _Sponsor(s)],
      ],
    );
  }
}

class _Sponsor extends StatelessWidget {
  const _Sponsor(this.s);
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final placeholder = s['placeholder'] != false;
    final url = s['url'] as String?;
    return Semantics(
      label: '${placeholder ? 'Ad space' : 'Sponsored'}: ${str(s['name'])}. ${str(s['tagline'])}',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(S.x3),
        decoration: BoxDecoration(
          color: placeholder ? C.cream : C.card,
          borderRadius: R.tile,
          border: Border.all(color: placeholder ? C.tileBorder : C.orangeLine, width: placeholder ? 1 : 0.5),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: C.cream, borderRadius: R.control),
              child: Icon(_sponsorIcons[s['kind']] ?? Icons.campaign_rounded, size: 19, color: C.orangeText),
            ),
            const SizedBox(width: S.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    placeholder ? 'Ad space · ${str(s['name'])}' : str(s['name']),
                    style: ts(12.5, w: FontWeight.w800, height: 1.3, color: placeholder ? C.label : C.ink),
                  ),
                  if (str(s['tagline']).isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(str(s['tagline']), style: ts(11, height: 1.4, color: C.label)),
                  ],
                  if (!placeholder && url != null && url.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      Uri.tryParse(url)?.host ?? url,
                      style: ts(11, w: FontWeight.w700, color: C.orangeText),
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
