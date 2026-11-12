// Bill & Savings (Figma "Bill"): GET /api/bill: forecast + range, vs last month, savings, weekly costs.
// The tip comes from GET /api/outlook (weather-aware advice from the server) when it's available.
// System check at the bottom: GET /api/upgrade (does the setup still fit this household's use?).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../common/charts.dart';
import '../common/ui.dart';
import 'system_check.dart';

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
        ref.invalidate(upgradeProvider);
        await ref.refresh(billProvider.future).then((_) {}, onError: (_) {});
      },
      child: ListView(padding: EdgeInsets.zero, children: [
        const SafeArea(bottom: false, child: PageHeader('Bill & Savings', 'Track your bill and solar savings.')),
        AsyncBody(
          value: bill,
          onRetry: () => ref.invalidate(billProvider),
          // The system check is extra: if it fails or isn't ready, the bill still shows without it.
          data: (b) => _BillBody(b, advice: advice, upgrade: ref.watch(upgradeProvider).value),
        ),
      ]),
    );
  }
}

class _BillBody extends StatelessWidget {
  const _BillBody(this.b, {required this.advice, this.upgrade});
  final Map<String, dynamic> b;
  final String advice;
  final Map<String, dynamic>? upgrade; // GET /api/upgrade; null = not loaded or failed

  @override
  Widget build(BuildContext context) {
    final vs = b['vs_last_month_pct'] as num?;
    final last = b['last_month_php'] as num?;
    final forecast = numOr(b['forecast_php']);
    final diff = last == null ? null : last - forecast; // > 0: this month is cheaper
    final weeks = listOfMaps(b['weekly_costs']);

    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x4, S.gutter, kFabClearance),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(S.x4),
          decoration: BoxDecoration(borderRadius: R.card, gradient: gradientDeep),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Predicted bill for ${monthNameOf(str(b['month'], '2000-01'))}',
                style: ts(13, w: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: S.x1),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(_php(forecast), style: ts(34, w: FontWeight.w900, color: Colors.white)),
            ),
            if (vs != null || diff != null) ...[
              const SizedBox(height: S.x2),
              _TrendPill(vs: vs, diff: diff),
            ],
            const SizedBox(height: S.x4),
            Container(height: 1, color: Colors.white.withValues(alpha: 0.35)),
            const SizedBox(height: S.x3),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _Fig('Likely range', '${_php(b['forecast_low_php'])} – ${_php(b['forecast_high_php'])}')),
              if (last != null) Expanded(child: _Fig('Last month’s bill', _php(last), end: true)),
            ]),
          ]),
        ),
        const SizedBox(height: S.x2),
        Text(
          'So far: ${_php(b['month_to_date_php'])} · ${kwhNum(b['month_to_date_kwh'])} kWh from the grid · '
          'day ${str(b['days_elapsed'], '—')} of ${str(b['days_in_month'], '—')}',
          style: ts(12, color: C.muted),
        ),
        const SizedBox(height: S.x6),
        const SectionTitle('Your solar savings'),
        const SizedBox(height: S.x3),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _Saving('Saved today', formatPhp(numOr(b['savings_today_php'])))),
            const SizedBox(width: S.x2),
            Expanded(child: _Saving('Saved this month', _php(b['savings_month_php']))),
          ]),
        ),
        const SizedBox(height: S.x3),
        SCard(
          padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x4, S.x3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const CardTitle('Weekly energy cost'),
            const SizedBox(height: S.x1),
            Text('Tap a week to see its cost.', style: ts(11, color: C.muted)),
            const SizedBox(height: S.x3),
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
        const SizedBox(height: S.x3),
        _Tip(advice: advice),
        if (upgrade != null) ...[
          const SizedBox(height: S.x6),
          SystemCheckCard(upgrade!),   // above kFabClearance, so the floating Mira button never covers it
        ],
      ]),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.advice});
  final String advice; // from /api/outlook; empty → the general daytime-use tip

  @override
  Widget build(BuildContext context) => SCard(
        color: C.tipBg,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Mira's own advice carries her face; the general tip keeps the bulb.
          if (advice.isNotEmpty)
            const MiraAvatar(mood: MiraMood.happy, size: 36, cycles: 2)
          else
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Colors.white, borderRadius: R.control),
              child: svg('bulb', width: 12, height: 17),
            ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CardTitle(advice.isEmpty ? 'Tip' : 'Tip mula kay Mira'),
              const SizedBox(height: S.x1),
              if (advice.isNotEmpty)
                Text(advice, style: ts(13, height: 1.45))
              else
                Text.rich(TextSpan(style: ts(13, height: 1.45), children: [
                  const TextSpan(text: 'Running your washing machine or water pump between '),
                  TextSpan(text: '10:00 AM', style: ts(13, w: FontWeight.w700)),
                  const TextSpan(text: ' and '),
                  TextSpan(text: '2:00 PM', style: ts(13, w: FontWeight.w700)),
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
      padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: 6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(R.pill)),
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
            Text(label, style: ts(12, w: FontWeight.w500, color: Colors.white)),
            const SizedBox(height: S.x1),
            Text(value, textAlign: end ? TextAlign.end : TextAlign.start, style: ts(15, w: FontWeight.w800, color: Colors.white)),
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
          padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: ts(11, w: FontWeight.w600, color: C.label)),
            const SizedBox(height: S.x2),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: ts(20, w: FontWeight.w800, color: C.orangeDeep)),
            ),
          ]),
        ),
      );
}
