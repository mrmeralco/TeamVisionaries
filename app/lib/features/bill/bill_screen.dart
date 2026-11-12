// Bill & Savings (Figma "Bill"): GET /api/bill: forecast + range, vs last month, savings, weekly costs.
// The tip comes from GET /api/outlook (weather-aware advice from the server) when it's available.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/charts.dart';
import '../common/ui.dart';

String _php(Object? v) => formatPhp(numOr(v), whole: true);

class BillScreen extends ConsumerWidget {
  const BillScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billProvider);
    final advice = str(ref.watch(outlookProvider).value?['advice']);
    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(outlookProvider);
        await ref.refresh(billProvider.future).then((_) {}, onError: (_) {});
      },
      child: ListView(padding: EdgeInsets.zero, children: [
        const SafeArea(bottom: false, child: PageHeader('Bill & Savings', 'Track your bill and solar savings.')),
        AsyncBody(value: bill, onRetry: () => ref.invalidate(billProvider), data: (b) => _BillBody(b, advice: advice)),
      ]),
    );
  }
}

class _BillBody extends StatelessWidget {
  const _BillBody(this.b, {required this.advice});
  final Map<String, dynamic> b;
  final String advice;

  @override
  Widget build(BuildContext context) {
    final vs = b['vs_last_month_pct'] as num?;
    final last = b['last_month_php'] as num?;
    final forecast = numOr(b['forecast_php']);
    final diff = last == null ? null : last - forecast; // > 0: this month is cheaper
    final weeks = listOfMaps(b['weekly_costs']);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), gradient: gradientDeep),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('PREDICTED BILL THIS MONTH · ${monthNameOf(str(b['month'], '2000-01')).toUpperCase()}',
                style: ts(11, w: FontWeight.w700, spacing: 0.2, color: Colors.white)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(_php(forecast), style: ts(34, w: FontWeight.w900, color: Colors.white)),
            ),
            if (vs != null || diff != null) ...[
              const SizedBox(height: 8),
              _TrendPill(vs: vs, diff: diff),
            ],
            const SizedBox(height: 14),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.35)),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _Fig('Likely Bill Range', '${_php(b['forecast_low_php'])} – ${_php(b['forecast_high_php'])}')),
              if (last != null) Expanded(child: _Fig('Last Month’s Bill', _php(last), end: true)),
            ]),
          ]),
        ),
        const SizedBox(height: 10),
        Text(
          'So far: ${_php(b['month_to_date_php'])} · ${kwhNum(b['month_to_date_kwh'])} kWh from the grid · '
          'day ${str(b['days_elapsed'], '—')} of ${str(b['days_in_month'], '—')}',
          style: ts(11, color: C.muted),
        ),
        const SizedBox(height: 22),
        Semantics(header: true, child: Text('Your Solar Savings', style: ts(15, w: FontWeight.w700, spacing: 0.14))),
        const SizedBox(height: 10),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _Saving('Saved today', formatPhp(numOr(b['savings_today_php'])))),
            const SizedBox(width: 13),
            Expanded(child: _Saving('Saved this month', _php(b['savings_month_php']))),
          ]),
        ),
        const SizedBox(height: 18),
        SCard(
          padding: const EdgeInsets.fromLTRB(15, 16, 15, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(header: true, child: Text('Weekly Energy Cost', style: ts(13, w: FontWeight.w700, spacing: 0.12))),
            const SizedBox(height: 4),
            Text('Tap a week to see its cost.', style: ts(10, color: C.muted)),
            const SizedBox(height: 10),
            if (weeks.isEmpty)
              Text('Wala pang data.', style: ts(12, color: C.muted))
            else
              BarChartView(
                values: [for (final w in weeks) numOr(w['php']).toDouble()],
                labels: [for (final w in weeks) str(w['label'])],
                format: _php,
                detail: (i) {
                  final w = weeks[i];
                  final current = i == weeks.length - 1;
                  return 'Week of ${str(w['label'])}: ${_php(w['php'])}${current ? ' so far' : ''}';
                },
              ),
          ]),
        ),
        const SizedBox(height: 16),
        _Tip(advice: advice),
      ]),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.advice});
  final String advice; // from /api/outlook; empty → the general daytime-use tip

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: C.tipBg,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: C.orangeLine, width: 0.7),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 31,
            height: 31,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4)),
            child: svg('bulb', width: 12, height: 17),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(advice.isEmpty ? 'Tip' : 'Tip mula kay Mira', style: ts(12, w: FontWeight.w800)),
              const SizedBox(height: 4),
              if (advice.isNotEmpty)
                Text(advice, style: ts(12, height: 1.45))
              else
                Text.rich(TextSpan(style: ts(12, height: 1.45), children: [
                  const TextSpan(text: 'Running your washing machine or water pump between '),
                  TextSpan(text: '10:00 AM', style: ts(12, w: FontWeight.w700)),
                  const TextSpan(text: ' and '),
                  TextSpan(text: '2:00 PM', style: ts(12, w: FontWeight.w700)),
                  const TextSpan(text: ' uses free daytime sunshine instead of paid evening electricity.'),
                ])),
            ]),
          ),
        ]),
      );
}

/// "₱709 less than last month (−21%)": the peso amount first, since that's what people budget in.
class _TrendPill extends StatelessWidget {
  const _TrendPill({this.vs, this.diff});
  final num? vs;
  final num? diff; // last month − this month's forecast

  @override
  Widget build(BuildContext context) {
    final lower = (diff ?? -(vs ?? 0)) >= 0;
    final pct = vs == null ? '' : ' (${lower ? '−' : '+'}${pctNum(vs!.abs())}%)';
    final text = diff == null
        ? '${pctNum(vs!.abs())}% ${lower ? 'lower' : 'higher'} than last month'
        : '${_php(diff!.abs())} ${lower ? 'less' : 'more'} than last month$pct';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(lower ? Icons.trending_down_rounded : Icons.trending_up_rounded, size: 16, color: lower ? C.green : C.red),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: ts(12, w: FontWeight.w700))),
      ]),
    );
  }
}

class _Fig extends StatelessWidget {
  const _Fig(this.label, this.value, {this.end = false});
  final String label, value;
  final bool end;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: Column(
          crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(label, style: ts(11, w: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 4),
            Text(value, textAlign: end ? TextAlign.end : TextAlign.start, style: ts(14, w: FontWeight.w800, color: Colors.white)),
          ],
        ),
      );
}

class _Saving extends StatelessWidget {
  const _Saving(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Readout(
        label: label,
        value: value,
        child: SCard(
          padding: const EdgeInsets.fromLTRB(16, 13, 12, 12),
          border: Border.all(color: C.orangeLine, width: 0.5),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: ts(11, w: FontWeight.w600, color: C.label)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: ts(20, w: FontWeight.w800, color: C.orangeDeep)),
            ),
          ]),
        ),
      );
}
