// Home (Figma "Home"): live status from /ws/live, readings, saved today, est. bill, yesterday's recap.
// States (TESTING.md): solar | battery | grid | brownout | fault | offline, and empty (telemetry null).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../../services/live_connection.dart';
import '../common/ui.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static String _greeting() {
    final h = manilaNow().hour;
    if (h < 12) return 'Magandang umaga';
    if (h < 18) return 'Magandang hapon';
    return 'Magandang gabi';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final bill = ref.watch(billProvider).value;
    final summary = ref.watch(dailySummaryProvider);
    final name = ref.watch(serverSettingsProvider).value?['user_name'] as String? ?? '';
    final data = live.live;
    final w = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top; // status bar

    Future<void> refresh() async {
      ref.invalidate(billProvider);
      ref.invalidate(serverSettingsProvider);
      await ref.refresh(dailySummaryProvider.future).then((_) {}, onError: (_) {});
    }

    return ColoredBox(
      color: Colors.white,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: Stack(children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            // Ends just below the hero card (Figma: 278 of 852) whatever the screen width.
            child: SvgPicture.asset('assets/images/header-circle.svg', width: w, height: 278 + top, fit: BoxFit.fill),
          ),
          ListView(padding: EdgeInsets.zero, children: [
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const TopBar(onDark: true),
                  const SizedBox(height: 4),
                  Text('${_greeting()}${name.isEmpty ? '' : ', $name'}!',
                      style: ts(24, w: FontWeight.w700, color: Colors.white, spacing: -0.48)),
                  const SizedBox(height: 4),
                  Text('Here’s what’s happening at home.', style: ts(12, color: Colors.white.withValues(alpha: 0.7))),
                  const SizedBox(height: 18),
                  _Hero(live: data),
                ]),
              ),
            ),
            if (data == null && live.link == LinkStatus.waiting)
              ErrorBox(onRetry: () => ref.invalidate(liveProvider))
            else if (data == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else ...[
              _StateBanner(live: live),
              Padding(padding: const EdgeInsets.fromLTRB(19, 16, 19, 0), child: _Stats(telemetry: live.telemetry)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(children: [
                  Expanded(child: _Money('Saved Today', formatPhp(data['saved_today_php'] as num? ?? 0))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Money('Est. Monthly Bill', bill == null ? '—' : formatPhp(bill['forecast_php'] as num, whole: true)),
                  ),
                ]),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
              child: Text('Yesterday’s Summary', style: ts(14, w: FontWeight.w700, spacing: 0.14)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(19, 10, 19, 24),
              child: AsyncBody(value: summary, onRetry: () => ref.invalidate(dailySummaryProvider), data: (s) => _Summary(s)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.live});
  final Map<String, dynamic>? live;

  @override
  Widget build(BuildContext context) {
    final state = live?['state'] as String? ?? 'offline';
    final t = live?['telemetry'] as Map?;
    final sunny = ((t?['pv_w'] as num?) ?? 0) > 0;
    final text = live?['status_line'] as String? ?? 'Kumokonekta sa Sinag… Ilang saglit lang.';
    final colors = switch (state) {
      'brownout' => const [Color(0xFFFFB37A), Color(0xFFF47721)],
      'fault' => const [Color(0xFFFFA48F), Color(0xFFE5533D)],
      'offline' => const [Color(0xFFE7E1D8), Color(0xFFCFC6BA)],
      _ => const [Color(0xFFFED47D), Color(0xFFFFC142)],
    };
    return Container(
      height: 154,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors, stops: const [0.02, 0.65]),
      ),
      child: Stack(children: [
        Positioned(left: 0, bottom: 0, width: 264, height: 98, child: Image.asset('assets/images/trees.png', fit: BoxFit.fill)),
        Positioned(right: 0, bottom: 0, width: 194, height: 143, child: Image.asset('assets/images/house.png', fit: BoxFit.fill)),
        if (sunny) ...[
          Positioned(left: 95.4, top: 56.6, child: SvgPicture.asset('assets/images/arrow-up.svg', width: 6, height: 39)),
          Positioned(left: 98, top: 94.65, child: SvgPicture.asset('assets/images/arrow-right.svg', width: 74, height: 1)),
        ],
        Positioned(
          left: 22,
          top: 14,
          width: 160,
          child: Text(text, maxLines: 4, overflow: TextOverflow.ellipsis, style: ts(11, w: FontWeight.w600)),
        ),
      ]),
    );
  }
}

/// Brownout / fault / offline get a tappable banner so the user knows what to do next.
class _StateBanner extends StatelessWidget {
  const _StateBanner({required this.live});
  final LiveState live;

  @override
  Widget build(BuildContext context) {
    final lastSeen = live.device?['last_seen_ts'];
    final (IconData, Color, String, String, VoidCallback?)? b = switch (live.state) {
      'brownout' => (Icons.power_off_rounded, C.orangeDeep, 'May brownout ngayon', 'Tingnan kung gaano katagal ang battery →',
          () => context.push(Routes.brownout)),
      'fault' => (Icons.warning_amber_rounded, C.red, 'May problema ang inverter', 'Buksan ang Alerts para sa paliwanag →',
          () => context.go(Routes.alerts)),
      'offline' => (Icons.cloud_off_rounded, C.muted, 'Offline ang Sinag device',
          lastSeen is int ? 'Huling reading: ${formatAgo(lastSeen)}' : 'Wala pang natatanggap na reading', null),
      _ => null,
    };
    if (b == null) return const SizedBox.shrink();
    final (icon, color, title, sub, onTap) = b;
    return Padding(
      padding: const EdgeInsets.fromLTRB(19, 14, 19, 0),
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: ts(12, w: FontWeight.w700, color: color)),
                  Text(sub, style: ts(10)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.telemetry});
  final Map<String, dynamic>? telemetry;

  static String? _battNote(num? w) {
    if (w == null || w.abs() < 20) return null;
    return w < 0 ? 'Charging' : 'Ginagamit';
  }

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    final Widget body;
    if (t == null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 12),
        child: Column(children: [
          const Icon(Icons.solar_power_rounded, color: C.orange, size: 32),
          const SizedBox(height: 8),
          Text('Wala pang reading mula sa device.', style: ts(12, w: FontWeight.w700)),
          Text('Lalabas dito ang solar, battery at grid kapag naka-on na ang Sinag device.',
              style: ts(10, color: C.muted), textAlign: TextAlign.center),
        ]),
      );
    } else {
      final gridOn = t['grid_on'] != false;
      body = TwoCol(children: [
        _Tile('Solar Production', kwNum(t['pv_w']), 'kW'),
        _Tile('Home Usage', kwNum(t['load_w']), 'kW'),
        _Tile('Battery Level', '${t['batt_soc']}', '%', note: _battNote(t['batt_w'] as num?)),
        _Tile('Grid Power', gridOn ? kwNum(t['grid_w']) : 'Off', gridOn ? 'kW' : '', note: gridOn ? null : 'Brownout'),
      ]);
    }
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: C.cream, borderRadius: BorderRadius.circular(15)),
      child: body,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.unit, {this.note});
  final String label, value, unit;
  final String? note;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 73),
        padding: const EdgeInsets.fromLTRB(13, 10, 10, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.tileBorder, width: 0.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Expanded(child: Text(label, style: ts(9, w: FontWeight.w600, color: C.tileLabel))),
            if (note != null)
              Flexible(child: Text(note!, overflow: TextOverflow.ellipsis, style: ts(8, w: FontWeight.w600, color: C.orange))),
          ]),
          const SizedBox(height: 10),
          Reading(value, unit),
        ]),
      );
}

class _Money extends StatelessWidget {
  const _Money(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 62),
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 10),
        decoration: BoxDecoration(color: C.cream, borderRadius: BorderRadius.circular(15)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: ts(8, w: FontWeight.w700, color: C.label55, spacing: 0.08)),
          const SizedBox(height: 8),
          Text(value, style: ts(15, w: FontWeight.w700, color: C.orange, spacing: 0.15)),
        ]),
      );
}

class _Summary extends StatelessWidget {
  const _Summary(this.s);
  final Map<String, dynamic> s;

  @override
  Widget build(BuildContext context) {
    final t = (s['totals'] as Map).cast<String, dynamic>();
    return SCard(
      color: C.cream,
      border: Border.all(color: Colors.transparent),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s['summary'] as String, style: ts(12, height: 1.45)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Chip('Solar', '${kwhNum(t['pv_kwh'])} kWh'),
          _Chip('Gastos', formatPhp(t['cost_php'] as num, whole: true)),
          _Chip('Natipid', formatPhp(t['savings_php'] as num, whole: true)),
          if (t['self_sufficiency_pct'] != null) _Chip('Galing sa solar', '${pctNum(t['self_sufficiency_pct'])}%'),
        ]),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$label  ', style: ts(9, w: FontWeight.w600, color: C.label55)),
          TextSpan(text: value, style: ts(10, w: FontWeight.w700, color: C.orange)),
        ])),
      );
}
