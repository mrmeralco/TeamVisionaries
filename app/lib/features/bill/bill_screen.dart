// Bill & Savings (Figma "Bill"): GET /api/bill: forecast + range, vs last month, savings, weekly costs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/charts.dart';
import '../common/ui.dart';

String _php(Object? v) => formatPhp(v is num ? v : 0, whole: true);

class BillScreen extends ConsumerWidget {
  const BillScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billProvider);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(billProvider.future).then((_) {}, onError: (_) {}),
      child: ListView(padding: EdgeInsets.zero, children: [
        const SafeArea(bottom: false, child: PageHeader('Bill & Savings', 'Track your bill and solar savings.')),
        AsyncBody(value: bill, onRetry: () => ref.invalidate(billProvider), data: (b) => _BillBody(b)),
      ]),
    );
  }
}

class _BillBody extends StatelessWidget {
  const _BillBody(this.b);
  final Map<String, dynamic> b;

  @override
  Widget build(BuildContext context) {
    final vs = b['vs_last_month_pct'] as num?;
    final last = b['last_month_php'] as num?;
    final save = last == null ? null : last - (b['forecast_php'] as num);
    final weeks = (b['weekly_costs'] as List).cast<Map<String, dynamic>>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 30, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), gradient: gradientOrange),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PREDICTED BILL THIS MONTH · ${monthNameOf(b['month'] as String).toUpperCase()}',
                style: ts(10, w: FontWeight.w700, spacing: 0.1, color: Colors.white.withValues(alpha: 0.78))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(_php(b['forecast_php']), style: ts(32, w: FontWeight.w900, color: Colors.white)),
                ),
              ),
              if (vs != null) _TrendPill(vs),
            ]),
            const SizedBox(height: 14),
            Container(height: 1.5, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 11),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _Fig('Likely Bill Range', '${_php(b['forecast_low_php'])} – ${_php(b['forecast_high_php'])}')),
              if (last != null)
                Expanded(
                  child: _Fig('Last Month’s Bill', '${_php(last)}${save != null && save > 0 ? ' (Save ${_php(save)})' : ''}', end: true),
                ),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        Text(
          'So far: ${_php(b['month_to_date_php'])} · ${kwhNum(b['month_to_date_kwh'])} kWh from the grid · '
          'day ${b['days_elapsed']} of ${b['days_in_month']}',
          style: ts(10, color: C.muted),
        ),
        const SizedBox(height: 22),
        Text('Your Solar Savings', style: ts(14, w: FontWeight.w700, spacing: 0.14)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _Saving('Today', formatPhp(b['savings_today_php'] as num))),
          const SizedBox(width: 13),
          Expanded(child: _Saving('This Month', _php(b['savings_month_php']))),
        ]),
        const SizedBox(height: 18),
        SCard(
          padding: const EdgeInsets.fromLTRB(15, 16, 15, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Weekly Energy Cost', style: ts(12, w: FontWeight.w600, spacing: 0.12)),
            const SizedBox(height: 14),
            if (weeks.isEmpty)
              Text('Wala pang data.', style: ts(11, color: C.muted))
            else
              BarChartView(
                values: [for (final w in weeks) (w['php'] as num).toDouble()],
                labels: [for (final w in weeks) w['label'] as String],
                format: _php,
              ),
          ]),
        ),
        const SizedBox(height: 16),
        const _Tip(),
      ]),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0x47FF9D42),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: C.unit),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 31,
            height: 31,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4)),
            child: svg('bulb', width: 12, height: 17),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Text.rich(TextSpan(style: ts(12, height: 17 / 12, spacing: 0.12), children: [
              const TextSpan(text: 'Tip: Running your washing machine or water pump between '),
              TextSpan(text: '10:00 AM', style: ts(12, w: FontWeight.w700)),
              const TextSpan(text: ' and '),
              TextSpan(text: '2:00 PM', style: ts(12, w: FontWeight.w700)),
              const TextSpan(text: ' uses free daytime sunshine instead of paid evening electricity.'),
            ])),
          ),
        ]),
      );
}

class _TrendPill extends StatelessWidget {
  const _TrendPill(this.vs);
  final num vs;

  @override
  Widget build(BuildContext context) {
    final lower = vs <= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.71), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        lower ? svg('trend-down', width: 11, height: 8) : const Icon(Icons.trending_up_rounded, size: 12, color: C.red),
        const SizedBox(width: 5),
        Text('${pctNum(vs.abs())}% ${lower ? 'lower' : 'higher'} than last month',
            style: ts(8, w: FontWeight.w500, color: C.ink.withValues(alpha: 0.76))),
      ]),
    );
  }
}

class _Fig extends StatelessWidget {
  const _Fig(this.label, this.value, {this.end = false});
  final String label, value;
  final bool end;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(label, style: ts(8, w: FontWeight.w600, color: Colors.white.withValues(alpha: 0.65))),
          const SizedBox(height: 4),
          Text(value, textAlign: end ? TextAlign.end : TextAlign.start, style: ts(10, w: FontWeight.w700, color: Colors.white)),
        ],
      );
}

class _Saving extends StatelessWidget {
  const _Saving(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => SCard(
        padding: const EdgeInsets.fromLTRB(16, 13, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: ts(8, w: FontWeight.w700, color: C.label55, spacing: 0.08)),
          const SizedBox(height: 10),
          Text(value, style: ts(15, w: FontWeight.w700, color: C.orange, spacing: 0.15)),
        ]),
      );
}
