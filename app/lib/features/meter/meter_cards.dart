// Smart meter mode (GET /api/meter + the live `meter` reading): for a home with a smart/Meralco meter, with or
// without solar. Every number comes from the backend; these widgets only lay it out.
//   MeterNowCard       Home (solar + meter): the meter's live reading next to the inverter tiles
//   MeterInsights      Home: Meralco level, peak hours, always-on use, voltage, the meter reading
//   UsagePatternCard   Energy: the typical day hour by hour, always-on use, peak, night share
//   MeralcoLevelCard   Bill: which Meralco consumption level this month lands in, and how close the next one is
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../common/ui.dart';

String meterTypeLabel(Object? type) => type == 'ansi-c12' ? 'Meralco meter' : 'Smart meter';

/// "8PM" for hour 20.
String hourLabel(int h) => '${h % 12 == 0 ? 12 : h % 12}${h < 12 ? 'AM' : 'PM'}';

/// "Up to 200 kWh" / "201–300 kWh" / "Over 400 kWh"
String levelLabel(num lo, num? hi) {
  if (hi == null) return 'Over ${lo.round()} kWh';
  return lo == 0 ? 'Up to ${hi.round()} kWh' : '${lo.round() + 1}–${hi.round()} kWh';
}

(Color, String) voltageStatus(Object? status) => switch (status) {
      'low' => (C.red, 'Low'),
      'high' => (C.red, 'High'),
      'off' => (C.muted, 'Off'),
      'normal' => (C.green, 'Normal'),
      _ => (C.muted, '—'),
    };

/// Solar + meter homes: what the utility meter reads right now (the inverter tiles stay above it).
class MeterNowCard extends ConsumerWidget {
  const MeterNowCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = ref.watch(liveProvider.select((l) => l.live?['meter']));
    final q = mapOf(ref.watch(meterProvider).value?['quality']);
    if (m is! Map) return const SizedBox.shrink();
    final reading = mapOf(m);
    final p = numOr(reading['power_w']);
    final (vColor, vText) = voltageStatus(q['voltage_status']);
    return SCard(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.electric_meter_rounded, size: 18, color: C.orangeText),
          const SizedBox(width: S.x2),
          Expanded(child: CardTitle(meterTypeLabel(reading['meter_type']))),
          Text('Utility side', style: ts(10, w: FontWeight.w600, color: C.muted)),
        ]),
        const SizedBox(height: S.x2),
        Wrap(spacing: S.x4, runSpacing: S.x2, children: [
          _Mini(p >= 0 ? 'From the grid' : 'To the grid', formatWatts(p.abs())),
          _Mini('Voltage', '${numOr(reading['voltage_v']).round()} V', note: vText, noteColor: vColor),
          if (reading['pf'] is num) _Mini('Power factor', numOr(reading['pf']).toStringAsFixed(2)),
          _Mini('Meter reading', '${_kwh1(reading['import_kwh'])} kWh'),
        ]),
      ]),
    );
  }
}

String _kwh1(Object? v) {
  final s = numOr(v).toStringAsFixed(1);
  final parts = s.split('.');
  final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$whole.${parts[1]}';
}

class _Mini extends StatelessWidget {
  const _Mini(this.label, this.value, {this.note, this.noteColor});
  final String label, value;
  final String? note;
  final Color? noteColor;

  @override
  Widget build(BuildContext context) => Readout(
        label: label,
        value: value,
        note: note,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: ts(10, w: FontWeight.w600, color: C.label)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: ts(14, w: FontWeight.w800)),
            if (note != null) ...[
              const SizedBox(width: 4),
              Text(note!, style: ts(10, w: FontWeight.w700, color: noteColor ?? C.muted)),
            ],
          ]),
        ]),
      );
}

/// The /api/meter insights as cards: warnings first (the backend's order).
class MeterInsights extends ConsumerWidget {
  const MeterInsights({super.key, this.title = 'Your electricity', this.skip = const {}});
  final String title;

  /// Insight ids shown elsewhere on the page (e.g. the meter reading next to the live tiles).
  final Set<String> skip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(meterProvider);
    final insights = listOfMaps(info.value?['insights']).where((i) => !skip.contains(i['id'])).toList();
    // Extra, like the solar tips: while loading or on error the page shows without it.
    if (insights.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x6, S.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SectionTitle(title),
        const SizedBox(height: 2),
        Text('Mula sa ${meterTypeLabel(mapOf(info.value?['reading'])['meter_type']).toLowerCase()} mo',
            style: ts(11, color: C.muted)),
        const SizedBox(height: S.x3),
        for (final i in insights) ...[InsightCard(i), const SizedBox(height: S.x2)],
      ]),
    );
  }
}

class InsightCard extends StatelessWidget {
  const InsightCard(this.i, {super.key});
  final Map<String, dynamic> i;

  static const _icons = {
    'voltage': Icons.bolt_rounded,
    'power_factor': Icons.speed_rounded,
    'tier_drop': Icons.trending_down_rounded,
    'tier_near': Icons.warning_amber_rounded,
    'tier': Icons.stairs_rounded,
    'peak_hours': Icons.schedule_rounded,
    'base_load': Icons.power_rounded,
    'reading': Icons.electric_meter_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final tone = str(i['tone'], 'info');
    final color = switch (tone) { 'warning' => C.red, 'good' => C.green, _ => C.orangeText };
    final evidence = listOfMaps(i['evidence']);
    return SCard(
      padding: const EdgeInsets.all(S.x3),
      border: tone == 'warning' ? Border.all(color: C.red.withValues(alpha: 0.5), width: 0.8) : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: R.control),
          child: Icon(_icons[i['id']] ?? Icons.info_outline_rounded, size: 18, color: color),
        ),
        const SizedBox(width: S.x3),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(str(i['title']), style: ts(13, w: FontWeight.w700, color: tone == 'warning' ? C.red : C.ink)),
            const SizedBox(height: 2),
            Text(str(i['body']), style: ts(12.5, height: 1.45)),
            if (evidence.isNotEmpty) ...[
              const SizedBox(height: S.x2),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final e in evidence)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: 3),
                    decoration: BoxDecoration(color: C.pill, borderRadius: BorderRadius.circular(R.pill)),
                    child: Text('${str(e['label'])}: ${str(e['value'])}', style: ts(10.5, w: FontWeight.w700)),
                  ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Energy tab: the household's typical day from the meter (last 7 days).
class UsagePatternCard extends ConsumerWidget {
  const UsagePatternCard({super.key, required this.gridOnly});

  /// True for a solar + meter home: the meter sees only what is bought from the grid, not all home use.
  final bool gridOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = mapOf(ref.watch(meterProvider).value?['usage']);
    if (u.isEmpty) return const SizedBox.shrink();
    final byHour = [for (final v in (u['by_hour_kwh'] as List? ?? const [])) numOr(v).toDouble()];
    final peaks = [for (final h in (u['peak_hours'] as List? ?? const [])) hourLabel(intOrNull(h) ?? 0)];
    final wk = u['weekday_kwh_day'], we = u['weekend_kwh_day'];
    return SCard(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CardTitle(gridOnly ? 'Your typical day on the grid' : 'Your typical day'),
        const SizedBox(height: 2),
        Text('Average kWh per hour, last ${str(u['days'], '7')} days · from your meter', style: ts(11, color: C.muted)),
        const SizedBox(height: S.x3),
        if (byHour.length == 24)
          _HourBars(byHour, peaks: {for (final h in (u['peak_hours'] as List? ?? const [])) intOrNull(h) ?? -1}),
        const SizedBox(height: S.x3),
        _Row(gridOnly ? 'Bought from the grid a day' : 'Used a day', '${kwhNum(u['import_kwh_day'])} kWh'),
        _Row('Always on (ref, router, standby)', formatWatts(numOr(u['base_w']))),
        _Row('Highest draw', formatWatts(numOr(u['peak_w']))),
        if (peaks.isNotEmpty) _Row('Busiest hours', peaks.join(', ')),
        _Row('At night (6PM–6AM)', '${str(u['night_share_pct'], '—')}%'),
        if (wk is num && we is num) _Row('Weekdays vs weekends', '${kwhNum(wk)} vs ${kwhNum(we)} kWh/day'),
      ]),
    );
  }
}

/// 24 thin bars, one per hour of the typical day; the busiest hours in orange. Tap a bar for its kWh.
class _HourBars extends StatefulWidget {
  const _HourBars(this.kwh, {required this.peaks});
  final List<double> kwh;
  final Set<int> peaks;

  @override
  State<_HourBars> createState() => _HourBarsState();
}

class _HourBarsState extends State<_HourBars> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final v = widget.kwh;
    final top = v.reduce((a, b) => a > b ? a : b).clamp(0.001, double.infinity);
    final sel = _sel ?? v.indexOf(v.reduce((a, b) => a > b ? a : b));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(color: C.pill, borderRadius: BorderRadius.circular(99)),
          child: Text('${hourLabel(sel)}: ${v[sel].toStringAsFixed(2)} kWh',
              style: ts(11, w: FontWeight.w700, color: C.orangeText)),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 80,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var h = 0; h < 24; h++)
            Expanded(
              child: Semantics(
                button: true,
                selected: h == sel,
                label: '${hourLabel(h)}: ${v[h].toStringAsFixed(2)} kWh',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _sel = h),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      height: (80 * v[h] / top).clamp(2.0, 80.0),
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                        color: h == sel ? C.ink : (widget.peaks.contains(h) ? C.orange : C.navOff.withValues(alpha: 0.8)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 4),
      Row(children: [
        for (final h in const [0, 6, 12, 18])
          Expanded(child: Text(hourLabel(h), style: ts(10, w: FontWeight.w600, color: C.muted))),
      ]),
    ]);
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: Text(label, style: ts(12.5, color: C.label))),
            const SizedBox(width: S.x2),
            // Long values ("16.3 vs 21.9 kWh/day") wrap on a small phone instead of overflowing.
            Flexible(flex: 2, child: Text(value, textAlign: TextAlign.end, style: ts(12.5, w: FontWeight.w700))),
          ]),
        ),
      );
}

/// Bill tab: Meralco charges the WHOLE month at the rate of the level its total kWh falls in.
class MeralcoLevelCard extends ConsumerWidget {
  const MeralcoLevelCard({super.key});

  static const _edges = [0.0, 200.0, 300.0, 400.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(meterProvider).value;
    final t = mapOf(info?['tier']);
    if (t.isEmpty) return const SizedBox.shrink();
    final fc = numOr(t['forecast_kwh']).toDouble();
    final mtd = numOr(t['month_to_date_kwh']).toDouble();
    final lo = numOr(t['level_min_kwh']);
    final hi = t['level_max_kwh'] as num?;
    final tierInsight = listOfMaps(info?['insights']).where((i) => str(i['id']).startsWith('tier')).firstOrNull;
    final top = [fc, mtd, 500.0].reduce((a, b) => a > b ? a : b) * 1.05;
    return SCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const CardTitle('Meralco level this month'),
        const SizedBox(height: 2),
        Text('Ang buong buwan ay sinisingil sa rate ng antas na kinalalagyan ng kabuuang kWh.',
            style: ts(11, color: C.muted)),
        const SizedBox(height: S.x3),
        // Wrap, not Row: with large system text the rate moves under the level instead of overflowing.
        Wrap(spacing: S.x3, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.end, children: [
          Text(levelLabel(lo, hi), style: ts(20, w: FontWeight.w900)),
          Text('≈ ${formatPhp(numOr(t['rate_php_per_kwh']))}/kWh', style: ts(12, w: FontWeight.w700, color: C.orangeText)),
        ]),
        const SizedBox(height: S.x3),
        Semantics(
          label: 'So far ${mtd.round()} kWh, forecast ${fc.round()} kWh, in the ${levelLabel(lo, hi)} level',
          excludeSemantics: true,
          child: LayoutBuilder(builder: (context, box) {
            final w = box.maxWidth;
            double x(double kwh) => (kwh / top).clamp(0.0, 1.0) * w;
            return SizedBox(
              height: 46,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 8,
                  height: 10,
                  child: Container(decoration: BoxDecoration(color: C.pill, borderRadius: BorderRadius.circular(R.pill))),
                ),
                Positioned(
                  left: 0,
                  top: 8,
                  height: 10,
                  width: x(mtd),
                  child: Container(decoration: BoxDecoration(color: C.orangeDeep, borderRadius: BorderRadius.circular(R.pill))),
                ),
                Positioned(left: x(fc) - 1, top: 2, width: 2, height: 22, child: const ColoredBox(color: C.ink)),
                for (final e in _edges.skip(1))
                  Positioned(
                    left: x(e) - 14,
                    top: 26,
                    width: 28,
                    child: Text('${e.round()}', textAlign: TextAlign.center, style: ts(9.5, w: FontWeight.w600, color: C.label)),
                  ),
              ]),
            );
          }),
        ),
        Text('So far ${kwhNum(mtd)} kWh · forecast ${kwhNum(fc)} kWh by month end', style: ts(11.5, color: C.label)),
        if (tierInsight != null) ...[
          const SizedBox(height: S.x3),
          Text(str(tierInsight['body']), style: ts(12.5, height: 1.45)),
        ],
      ]),
    );
  }
}
