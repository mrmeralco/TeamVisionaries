// Energy (Figma "Energy"): GET /api/energy?period=day|week|month: totals, self-sufficiency, solar chart.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/charts.dart';
import '../common/ui.dart';

class EnergyScreen extends ConsumerStatefulWidget {
  const EnergyScreen({super.key});
  @override
  ConsumerState<EnergyScreen> createState() => _EnergyScreenState();
}

class _EnergyScreenState extends ConsumerState<EnergyScreen> {
  static const _periods = [('day', 'Today'), ('week', 'Week'), ('month', 'Month')];
  static const _subs = {
    'day': 'Electricity today, hour by hour.',
    'week': 'Daily electricity over the past 7 days.',
    'month': 'Daily electricity this month.',
  };
  String _period = 'day';

  @override
  Widget build(BuildContext context) {
    final energy = ref.watch(energyProvider(_period));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(energyProvider(_period).future).then((_) {}, onError: (_) {}),
      child: ListView(padding: EdgeInsets.zero, children: [
        SafeArea(bottom: false, child: PageHeader('Energy', _subs[_period]!)),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: _PeriodSwitch(options: _periods, value: _period, onChanged: (p) => setState(() => _period = p)),
        ),
        AsyncBody(value: energy, onRetry: () => ref.invalidate(energyProvider(_period)), data: (e) => _EnergyBody(e)),
      ]),
    );
  }
}

class _PeriodSwitch extends StatelessWidget {
  const _PeriodSwitch({required this.options, required this.value, required this.onChanged});
  final List<(String, String)> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        height: 38,
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: const LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [C.orange, C.yellow], stops: [0, 1.17]),
        ),
        child: Row(children: [
          for (final (key, label) in options)
            Expanded(
              child: Semantics(
                selected: key == value,
                button: true,
                child: GestureDetector(
                  onTap: () => onChanged(key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: key == value ? C.cream.withValues(alpha: 0.63) : Colors.transparent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(label, style: ts(11, w: FontWeight.w700)),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _EnergyBody extends StatelessWidget {
  const _EnergyBody(this.e);
  final Map<String, dynamic> e;

  /// "13:00" -> "1 PM"
  static String _hourLabel(String hhmm) {
    final h = int.tryParse(hhmm.split(':').first) ?? 0;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12 ${h < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    final t = (e['totals'] as Map).cast<String, dynamic>();
    final points = (e['points'] as List).cast<Map<String, dynamic>>();
    final hourly = e['bucket'] == 'hour';
    // Figma 22:160 / 41:492 / 41:497 / 41:507 (Grid Used = what the household paid for).
    final cards = [
      ('Solar Produced', kwhNum(t['pv_kwh']), 'kWh', C.yellowCard),
      ('Grid Used', kwhNum(t['grid_import_kwh']), 'kWh', C.yellowCard),
      ('Battery Used', kwhNum(t['batt_discharge_kwh']), 'kWh', C.yellowCard),
      ('Self-Sufficiency', pctNum(e['self_sufficiency_pct']), '%', C.peach),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 35, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TwoCol(gap: 9, runGap: 10, children: [
          for (final (label, value, unit, color) in cards)
            Container(
              constraints: const BoxConstraints(minHeight: 78),
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(15)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(label, style: ts(9, w: FontWeight.w500, color: const Color(0xB8292929))),
                const SizedBox(height: 14),
                Reading(value, unit, size: 22, unitColor: const Color(0xA8292929), unitWeight: FontWeight.w700),
              ]),
            ),
        ]),
        const SizedBox(height: 30),
        SCard(
          padding: const EdgeInsets.fromLTRB(16, 11, 13, 14),
          border: Border.all(color: C.orangeLine, width: 0.5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LineChartView(
              title: 'Solar Production',
              values: [for (final p in points) (p['pv_kwh'] as num).toDouble()],
              labels: [for (final p in points) hourly ? _hourLabel(p['label'] as String) : p['label'] as String],
            ),
          ]),
        ),
        const SizedBox(height: 12),
        SCard(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Saan galing ang kuryente mo', style: ts(12, w: FontWeight.w600, spacing: 0.12)),
            const SizedBox(height: 10),
            _Row('Grid (binayaran)', '${kwhNum(t['grid_import_kwh'])} kWh'),
            _Row('Battery charged', '${kwhNum(t['batt_charge_kwh'])} kWh'),
            _Row('Sent to grid', '${kwhNum(t['grid_export_kwh'])} kWh'),
          ]),
        ),
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: ts(11, color: C.muted))),
          Text(value, style: ts(11, w: FontWeight.w700)),
        ]),
      );
}
