// Brownout Advisor: GET /api/brownout. Opened from the Home banner and brownout alerts.
// Refetches on every live reading so the runtime estimate follows the load; the duration of an active
// brownout counts up on screen between readings. A meter-only home has no battery: no runtime, battery tile
// or 48-hour solar outlook, only when the power went out and what to do.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../common/ui.dart';

class BrownoutScreen extends ConsumerWidget {
  const BrownoutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(liveProvider.select((s) => s.readingTs), (prev, next) {
      if (prev != null && next != prev) ref.invalidate(brownoutProvider);
    });
    final solar = ref.watch(hasSolarProvider);
    final brownout = ref.watch(brownoutProvider);
    final outlook = solar ? ref.watch(outlookProvider) : null;
    return Scaffold(
      backgroundColor: C.cream,
      body: GlassBackdrop(child: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(outlookProvider);
          await ref.refresh(brownoutProvider.future).then((_) {}, onError: (_) {});
        },
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            BackHeader('Brownout Advisor',
                solar ? 'How long your battery lasts, and what to expect next.' : 'When the power went out, and what to do.'),
            Padding(
              padding: const EdgeInsets.fromLTRB(S.gutter, S.x4, S.gutter, S.x6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AsyncBody(value: brownout, onRetry: () => ref.invalidate(brownoutProvider), data: (b) => _Body(b, solar: solar)),
                  if (outlook != null) ...[
                    const SizedBox(height: S.x6),
                    const SectionTitle('Next 48 hours'),
                    const SizedBox(height: S.x3),
                    // The outlook is extra: if it fails, say so quietly instead of a full error card.
                    switch (outlook) {
                      AsyncValue(:final value?, hasValue: true) => _Outlook(value),
                      AsyncError() => Text('Hindi makuha ang forecast ngayon.', style: ts(12, color: C.muted)),
                      _ => const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
                    },
                  ],
                ],
              ),
            ),
          ],
        ),
      )),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.b, {this.solar = true});
  final Map<String, dynamic> b;
  final bool solar; // false: a meter-only home (no battery)

  @override
  Widget build(BuildContext context) {
    final active = b['active'] == true;
    final runtime = b['runtime_h'] as num?;
    final start = intOrNull(b['start_ts']);
    final reported = intOrNull(b['duration_min']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(S.x4),
          decoration: BoxDecoration(
            borderRadius: R.card,
            gradient: active ? gradientDeep : gradientGreen,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(active ? Icons.power_off_rounded : Icons.power_rounded, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      active ? 'Brownout in progress' : 'Grid power is on',
                      style: ts(13, w: FontWeight.w700, color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (active && !solar)
                Text('Walang kuryente', style: ts(26, w: FontWeight.w900, color: Colors.white))
              else if (active) ...[
                Text(
                  runtime == null ? '—' : '~${runtime.toStringAsFixed(1)} hrs',
                  style: ts(32, w: FontWeight.w900, color: Colors.white),
                ),
                Text('tatagal pa ang battery sa kasalukuyang gamit', style: ts(13, w: FontWeight.w500, color: Colors.white)),
              ] else
                Text('No brownout', style: ts(26, w: FontWeight.w900, color: Colors.white)),
            ],
          ),
        ),
        const SizedBox(height: S.x3),
        TwoCol(
          gap: S.x2,
          runGap: S.x2,
          children: [
            if (solar) _Stat('Battery', b['batt_soc'] is num ? pctNum(b['batt_soc']) : '—', '%'),
            if (solar) _Stat('Home usage', kwNum(b['load_w']), 'kW'),
            _Stat(
              active ? 'Started' : 'Last brownout',
              start == null ? '—' : formatClock(start),
              '',
              note: start == null ? null : formatShortDate(start),
            ),
            // While active, count up from start_ts every 30 s instead of waiting for the next reading.
            active && start != null
                ? Every(
                    const Duration(seconds: 30),
                    builder: (_) => _DurationStat(
                      ((DateTime.now().millisecondsSinceEpoch ~/ 1000 - start) ~/ 60).clamp(0, 1 << 30),
                      ongoing: true,
                    ),
                  )
                : _DurationStat(reported),
          ],
        ),
        const SizedBox(height: S.x3),
        SCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                MiraAvatar(size: 32),
                SizedBox(width: S.x2),
                Expanded(child: CardTitle('Mira’s advice')),
              ]),
              const SizedBox(height: S.x2),
              Text(str(b['advice']), style: ts(13, height: 1.45)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text('${str(b['outages_this_month'], '0')} brownout ngayong buwan', style: ts(12, color: C.muted)),
      ],
    );
  }
}

/// "45 min", or "1.4 hrs" from an hour up.
class _DurationStat extends StatelessWidget {
  const _DurationStat(this.minutes, {this.ongoing = false});
  final int? minutes;
  final bool ongoing;

  @override
  Widget build(BuildContext context) {
    final m = minutes;
    final (value, unit) = m == null ? ('—', '') : (m < 60 ? ('$m', 'min') : ((m / 60).toStringAsFixed(1), 'hrs'));
    return _Stat('Duration', value, unit, note: m == null ? null : (ongoing ? 'ongoing · ${formatDuration(m)}' : formatDuration(m)));
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.unit, {this.note});
  final String label, value, unit;
  final String? note;

  @override
  Widget build(BuildContext context) => Readout(
    label: label,
    value: value,
    unit: unit,
    note: note,
    child: SCard(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: ts(11, w: FontWeight.w600, color: C.label)),
          const SizedBox(height: S.x2),
          Reading(value, unit, size: 20),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(note!, style: ts(10, color: C.muted)),
          ],
        ],
      ),
    ),
  );
}

/// GET /api/outlook: tomorrow's sun vs. a typical day, when the battery reaches its reserve, how long a
/// brownout would last with the forecast sun counted, and the server's advice.
class _Outlook extends StatelessWidget {
  const _Outlook(this.o);
  final Map<String, dynamic> o;

  static String _when(Object? ts) => ts is int ? '${formatClock(ts)}, ${formatShortDate(ts)}' : 'beyond 48 hrs';

  @override
  Widget build(BuildContext context) {
    final battery = mapOf(o['battery']);
    final brownout = o['brownout'] is Map ? mapOf(o['brownout']) : null;
    final typical = o['solar_typical_kwh'] as num?;
    final tomorrow = o['solar_tomorrow_kwh'] as num?;
    final cloudy = typical != null && tomorrow != null && tomorrow < typical * 0.6;
    final hours = brownout?['hours'] as num?;
    final reserveTs = intOrNull(battery['reserve_ts']);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TwoCol(gap: S.x2, runGap: S.x2, children: [
        _Stat('Solar tomorrow', tomorrow == null ? '—' : kwhNum(tomorrow), 'kWh',
            note: typical == null ? null : 'typical: ${kwhNum(typical)} kWh${cloudy ? ' · cloudy' : ''}'),
        _Stat('Solar today', kwhNum(o['solar_today_kwh']), 'kWh'),
        _Stat('Battery at ${str(battery['reserve_pct'], '—')}%', reserveTs != null ? formatClock(reserveTs) : '—', '',
            note: reserveTs != null ? formatShortDate(reserveTs) : 'not within 48 hrs'),
        _Stat('If a brownout hits', brownout == null ? '—' : (hours == null ? '48+' : hours.toStringAsFixed(1)), 'hrs',
            note: brownout == null ? 'no reading yet' : 'until ${_when(brownout['lasts_until_ts'])}'),
      ]),
      const SizedBox(height: S.x3),
      SCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // A forecast: Mira thinking ahead (still: she isn't working on anything here).
          const MiraAvatar(mood: MiraMood.thinking, size: 32, animate: false),
          const SizedBox(width: S.x3),
          Expanded(child: Text(str(o['advice']), style: ts(13, height: 1.45))),
        ]),
      ),
      const SizedBox(height: 8),
      Text(
        o['source'] == 'weather'
            ? 'Batay sa weather forecast at sa gamit mo nitong mga nakaraang araw.'
            : 'Walang weather forecast ngayon: batay sa nakaraang 14 araw.',
        style: ts(11, color: C.muted),
      ),
    ]);
  }
}
