// Energy (Figma "Energy"): GET /api/energy?period=day|week|month&back=N: totals, self-sufficiency, and a
// solar vs. home vs. grid chart. ‹ › step back to yesterday / last week / last month.
// Smart meter mode: a meter-only home sees its use and busiest time instead of solar/battery, and every home
// with a meter gets its typical day from GET /api/meter.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/charts.dart';
import '../common/ui.dart';
import '../meter/meter_cards.dart';

class EnergyScreen extends ConsumerStatefulWidget {
  const EnergyScreen({super.key});
  @override
  ConsumerState<EnergyScreen> createState() => _EnergyScreenState();
}

class _EnergyScreenState extends ConsumerState<EnergyScreen> {
  static const _periods = [('day', 'Today'), ('week', 'Week'), ('month', 'Month')];
  static const _maxBack = {'day': 30, 'week': 12, 'month': 12};
  String _period = 'day';
  int _back = 0;

  /// Last data shown, kept on screen (dimmed, with a progress bar) while another period loads, so the
  /// layout doesn't jump to a spinner and back.
  Map<String, dynamic>? _shown;

  (String, int) get _q => (_period, _back);

  String _sub() => switch ((_period, _back)) {
        ('day', 0) => 'Electricity today, hour by hour.',
        ('day', _) => 'Electricity for one day, hour by hour.',
        ('week', 0) => 'Daily electricity over the past 7 days.',
        ('week', _) => 'Daily electricity for one week.',
        ('month', 0) => 'Daily electricity this month.',
        _ => 'Daily electricity for one month.',
      };

  /// "Today", "Yesterday", "Nov 9"; "Past 7 days", "Oct 30 – Nov 5"; "November 2026".
  static String _rangeLabel(String period, int back, Map<String, dynamic>? e) {
    final start = intOrNull(e?['start_ts']);
    final end = intOrNull(e?['end_ts']);
    switch (period) {
      case 'day':
        if (back == 0) return 'Today';
        if (back == 1) return 'Yesterday';
        return start == null ? '$back days ago' : DateFormat('EEE, MMM d').format(manilaTime(start));
      case 'week':
        if (back == 0) return 'Past 7 days';
        if (start == null || end == null) return '$back weeks ago';
        return '${formatShortDate(start)} – ${formatShortDate(end - 1)}';
      default:
        if (back == 0) return 'This month';
        return start == null ? '$back months ago' : DateFormat('MMMM yyyy').format(manilaTime(start));
    }
  }

  @override
  Widget build(BuildContext context) {
    final energy = ref.watch(energyProvider(_q));
    final setup = ref.watch(setupProvider);
    if (energy.hasValue && !energy.isLoading) _shown = energy.value;
    final loading = energy.isLoading;
    final stale = !energy.hasValue || energy.isLoading;

    final Widget body;
    if (energy.hasError && !energy.isLoading) {
      body = ErrorBox(onRetry: () => ref.invalidate(energyProvider(_q)), error: energy.error);
    } else if (_shown == null) {
      body = const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
    } else {
      body = AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: stale && loading ? 0.45 : 1,
        child: IgnorePointer(ignoring: stale && loading, child: _EnergyBody(_shown!, setup: setup)),
      );
    }

    return RefreshIndicator(
      onRefresh: () {
        ref.invalidate(meterProvider);
        return ref.refresh(energyProvider(_q).future).then((_) {}, onError: (_) {});
      },
      child: ListView(padding: EdgeInsets.zero, children: [
        SafeArea(bottom: false, child: PageHeader('Energy', _sub())),
        Padding(
          padding: const EdgeInsets.fromLTRB(S.gutter, S.x4, S.gutter, 0),
          child: _PeriodSwitch(
            options: _periods,
            value: _period,
            onChanged: (p) => setState(() {
              _period = p;
              _back = 0;
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: _RangeStepper(
            label: _rangeLabel(_period, _back, energy.value ?? (loading ? null : _shown)),
            canBack: _back < _maxBack[_period]!,
            canForward: _back > 0,
            onBack: () => setState(() => _back++),
            onForward: () => setState(() => _back--),
          ),
        ),
        SizedBox(height: 2, child: loading ? const LinearProgressIndicator(minHeight: 2) : null),
        body,
      ]),
    );
  }
}

class _PeriodSwitch extends StatelessWidget {
  const _PeriodSwitch({required this.options, required this.value, required this.onChanged});
  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;

  /// One indicator slides to the tapped period (240 ms, the UI ease); it jumps under reduced motion.
  @override
  Widget build(BuildContext context) {
    final n = options.length;
    final i = options.indexWhere((o) => o.$1 == value).clamp(0, n - 1);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.all(S.x1),
      decoration: BoxDecoration(borderRadius: R.tile, gradient: gradientOrange),
      child: Stack(children: [
        Positioned.fill(
          child: AnimatedAlign(
            alignment: Alignment(n == 1 ? 0 : -1 + 2 * i / (n - 1), 0),
            duration: reduceMotion(context) ? Duration.zero : M.slide,
            curve: M.ease,
            child: FractionallySizedBox(
              widthFactor: 1 / n,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: C.cream.withValues(alpha: 0.9),
                  borderRadius: R.control,
                  boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 3, offset: Offset(0, 1))],
                ),
              ),
            ),
          ),
        ),
        Row(children: [
          for (final (key, label) in options)
            Expanded(
              child: Semantics(
                selected: key == value,
                button: true,
                inMutuallyExclusiveGroup: true,
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: R.control,
                    onTap: () => onChanged(key),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: kMinTap),
                      alignment: Alignment.center,
                      child: Text(label, style: ts(13, w: key == value ? FontWeight.w800 : FontWeight.w600)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

/// ‹  Yesterday  › under the period switch.
class _RangeStepper extends StatelessWidget {
  const _RangeStepper({
    required this.label,
    required this.canBack,
    required this.canForward,
    required this.onBack,
    required this.onForward,
  });
  final String label;
  final bool canBack, canForward;
  final VoidCallback onBack, onForward;

  @override
  Widget build(BuildContext context) => Row(children: [
        IconButton(
          tooltip: 'Earlier',
          onPressed: canBack ? onBack : null,
          icon: const Icon(Icons.chevron_left_rounded),
          color: C.ink,
        ),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: Text(label, textAlign: TextAlign.center, style: ts(13, w: FontWeight.w700)),
          ),
        ),
        IconButton(
          tooltip: 'Later',
          onPressed: canForward ? onForward : null,
          icon: const Icon(Icons.chevron_right_rounded),
          color: C.ink,
        ),
      ]);
}

class _EnergyBody extends StatelessWidget {
  const _EnergyBody(this.e, {this.setup = 'solar'});
  final Map<String, dynamic> e;
  final String setup; // solar | meter_only | solar_and_meter

  /// "13:00" -> "1 PM"
  static String _hourLabel(String hhmm) {
    final h = int.tryParse(hhmm.split(':').first) ?? 0;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12 ${h < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final t = mapOf(e['totals']);
    final points = listOfMaps(e['points']);
    final hourly = e['bucket'] == 'hour';
    List<double> col(String k) => [for (final p in points) numOr(p[k]).toDouble()];
    final solar = setup != 'meter_only';
    // Meter only: the busiest hour (day view) or day (week, month) instead of solar, battery and self-sufficiency.
    final use = col('load_kwh');
    final busiest = use.isEmpty || use.every((v) => v <= 0) ? -1 : use.indexOf(use.reduce((a, b) => a > b ? a : b));
    final busiestLabel = busiest < 0 ? '—' : (hourly ? _hourLabel(str(points[busiest]['label'])) : str(points[busiest]['label']));
    // Figma 22:160 / 41:492 / 41:497 / 41:507 (Grid Used = what the household paid for).
    final cards = solar
        ? [
            ('Solar produced', kwhNum(t['pv_kwh']), 'kWh', C.yellowCard),
            ('Grid used', kwhNum(t['grid_import_kwh']), 'kWh', C.yellowCard),
            ('Battery used', kwhNum(t['batt_discharge_kwh']), 'kWh', C.yellowCard),
            ('Self-sufficiency', pctNum(e['self_sufficiency_pct']), '%', C.peach),
          ]
        : [
            ('Electricity used', kwhNum(t['grid_import_kwh']), 'kWh', C.yellowCard),
            (hourly ? 'Busiest hour' : 'Busiest day', busiestLabel, '', C.peach),
          ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, kFabClearance),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TwoCol(gap: S.x2, runGap: S.x2, children: [
          for (final (label, value, unit, color) in cards)
            Readout(
              label: label,
              value: value,
              unit: unit,
              child: Container(
                constraints: const BoxConstraints(minHeight: 78),
                padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
                decoration: BoxDecoration(color: color, borderRadius: R.card),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label, style: ts(11, w: FontWeight.w600, color: C.labelOnYellow)),
                    const SizedBox(height: 12),
                    Reading(value, unit, size: 22, unitColor: C.labelOnYellow, unitWeight: FontWeight.w700),
                  ],
                ),
              ),
            ),
        ]),
        const SizedBox(height: S.x4),
        SCard(
          padding: const EdgeInsets.fromLTRB(S.x3, S.x4, S.x3, S.x3),
          child: points.isEmpty
              ? Text('Wala pang data para sa panahong ito.', style: ts(12, color: C.muted))
              : LineChartView(
                  title: solar ? 'Solar vs. Home vs. Grid (kWh)' : 'Home use from the grid (kWh)',
                  labels: [for (final p in points) hourly ? _hourLabel(str(p['label'])) : str(p['label'])],
                  series: solar
                      ? [
                          ChartSeries('Solar', C.seriesSolar, col('pv_kwh'), primary: true),
                          ChartSeries('Home', C.seriesHome, col('load_kwh')),
                          ChartSeries('Grid', C.seriesGrid, col('grid_import_kwh')),
                        ]
                      : [ChartSeries('Home', C.seriesGrid, col('grid_import_kwh'), primary: true)],
                ),
        ),
        if (solar) ...[
          const SizedBox(height: S.x3),
          SCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const CardTitle('Where your power went'),
              const SizedBox(height: S.x2),
              _Row('Home used', '${kwhNum(t['load_kwh'])} kWh'),
              _Row('Bought from the grid', '${kwhNum(t['grid_import_kwh'])} kWh'),
              _Row('Battery charged', '${kwhNum(t['batt_charge_kwh'])} kWh'),
              _Row('Sent to the grid', '${kwhNum(t['grid_export_kwh'])} kWh'),
            ]),
          ),
        ],
        if (setup != 'solar') ...[
          const SizedBox(height: S.x3),
          UsagePatternCard(gridOnly: solar),
        ],
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(child: Text(label, style: ts(13, color: C.label))),
            Text(value, style: ts(13, w: FontWeight.w700)),
          ]),
        ),
      );
}
