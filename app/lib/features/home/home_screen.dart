// Home (Figma "Home"): live status from /ws/live, readings, saved today, est. bill, yesterday's recap.
// States (TESTING.md): solar | battery | grid | brownout | fault | offline, and empty (telemetry null).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart' show SvgPicture;
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/chat_providers.dart';
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

    final rate = (data?['rate_php_per_kwh'] as num?) ?? (bill?['rate_php_per_kwh'] as num?);

    return ColoredBox(
      color: C.cream,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              // Ends just below the hero card (Figma: 278 of 852) whatever the screen width.
              child: SvgPicture.asset('assets/images/header-circle.svg', width: w, height: 278 + top, fit: BoxFit.fill),
            ),
            ListView(
              padding: EdgeInsets.zero,
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const TopBar(onDark: true),
                        const SizedBox(height: 4),
                        Text(
                          '${_greeting()}${name.isEmpty ? '' : ', $name'}!',
                          style: ts(24, w: FontWeight.w700, color: Colors.white, spacing: -0.48),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Here’s what’s happening at home.',
                          style: ts(12, color: Colors.white.withValues(alpha: 0.7)),
                        ),
                        const SizedBox(height: 18),
                        _Hero(live: data),
                      ],
                    ),
                  ),
                ),
                if (data == null && live.link == LinkStatus.waiting)
                  ErrorBox(onRetry: () => ref.invalidate(liveProvider))
                else if (data == null)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  _StateBanner(live: live),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: _Stats(telemetry: live.telemetry),
                  ),
                  if (live.telemetry != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: _DeviceHealth(telemetry: live.telemetry!, device: live.device),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _Money(
                              'Saved Today',
                              formatPhp(data['saved_today_php'] as num? ?? 0),
                              caption: rate == null ? null : 'At ${formatPhp(rate)}/kWh',
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: _Money(
                              'Est. Monthly Bill',
                              bill == null ? '—' : formatPhp(bill['forecast_php'] as num, whole: true),
                              caption: 'Tap for Bill Details',
                              onTap: () => context.go(Routes.bill),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Text(
                    'Yesterday’s Summary',
                    style: ts(12, w: FontWeight.w700, color: Colors.black, spacing: -0.24),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                  child: AsyncBody(
                    value: summary,
                    onRetry: () => ref.invalidate(dailySummaryProvider),
                    data: (s) => _Summary(
                      s,
                      onAsk: () {
                        ref.read(chatProvider.notifier).send('Kumusta ang solar at kuryente ko kahapon?');
                        context.go(Routes.ask);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
          stops: const [0.02, 0.65],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 0,
            bottom: 0,
            width: 264,
            height: 98,
            child: Image.asset('assets/images/trees.png', fit: BoxFit.fill),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: 194,
            height: 143,
            child: Image.asset('assets/images/house.png', fit: BoxFit.fill),
          ),
          if (sunny) ...[
            Positioned(
              left: 95.4,
              top: 56.6,
              child: SvgPicture.asset('assets/images/arrow-up.svg', width: 6, height: 39),
            ),
            Positioned(
              left: 98,
              top: 94.65,
              child: SvgPicture.asset('assets/images/arrow-right.svg', width: 74, height: 1),
            ),
          ],
          Positioned(
            left: 22,
            top: 14,
            width: 160,
            child: Text(
              text,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: ts(11, w: FontWeight.w600),
            ),
          ),
        ],
      ),
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
      'brownout' => (
        Icons.power_off_rounded,
        C.orangeDeep,
        'May brownout ngayon',
        'Tingnan kung gaano katagal ang battery →',
        () => context.push(Routes.brownout),
      ),
      'fault' => (
        Icons.warning_amber_rounded,
        C.red,
        'May problema ang inverter',
        'Buksan ang Alerts para sa paliwanag →',
        () => context.go(Routes.alerts),
      ),
      'offline' => (
        Icons.cloud_off_rounded,
        C.muted,
        'Offline ang Sinag device',
        lastSeen is int ? 'Huling reading: ${formatAgo(lastSeen)}' : 'Wala pang natatanggap na reading',
        null,
      ),
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
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: ts(12, w: FontWeight.w700, color: color),
                      ),
                      Text(sub, style: ts(10)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.telemetry});
  final Map<String, dynamic>? telemetry;

  /// Contract B: grid_w is + import, − export. The tile shows the size; the note says which way.
  static String? _gridNote(num? w) {
    if (w == null || w.abs() < 20) return null;
    return w > 0 ? 'Importing' : 'Exporting';
  }

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
        child: Column(
          children: [
            const Icon(Icons.solar_power_rounded, color: C.orange, size: 32),
            const SizedBox(height: 8),
            Text('Wala pang reading mula sa device.', style: ts(12, w: FontWeight.w700)),
            Text(
              'Lalabas dito ang solar, battery at grid kapag naka-on na ang Sinag device.',
              style: ts(10, color: C.muted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    } else {
      final gridOn = t['grid_on'] != false;
      body = TwoCol(
        gap: 7,
        runGap: 9,
        children: [
          _Tile('Solar Production', kwNum(t['pv_w']), 'kW'),
          _Tile('Home Usage', kwNum(t['load_w']), 'kW'),
          _Tile('Battery Level', '${t['batt_soc']}', '%', note: _battNote(t['batt_w'] as num?)),
          _Tile(
            'Grid Power',
            gridOn ? kwNum(t['grid_w']) : 'Off',
            gridOn ? 'kW' : '',
            note: gridOn ? _gridNote(t['grid_w'] as num?) : 'Brownout',
          ),
        ],
      );
    }
    // Figma 22:122: yellow panel, 353 × 192, radius 15, drop shadow 0 2 4 rgba(0,0,0,.25).
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
      decoration: BoxDecoration(
        color: C.yellow,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 2))],
      ),
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
    constraints: const BoxConstraints(minHeight: 77),
    padding: const EdgeInsets.fromLTRB(13, 11, 10, 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: C.tileBorder, width: 0.5),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: ts(9, w: FontWeight.w600, color: const Color(0x6B292929), spacing: -0.18),
              ),
            ),
            if (note != null)
              Flexible(
                child: Text(
                  note!,
                  overflow: TextOverflow.ellipsis,
                  style: ts(8, w: FontWeight.w600, color: C.orange),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Reading(value, unit, valueColor: C.orange, unitColor: const Color(0x82F47721), unitWeight: FontWeight.w700),
      ],
    ),
  );
}

/// Figma 22:139 / 29:403: white card, orange hairline, label + value + small caption.
class _Money extends StatelessWidget {
  const _Money(this.label, this.value, {this.caption, this.onTap});
  final String label, value;
  final String? caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
      side: const BorderSide(color: C.orangeLine, width: 0.5),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 71),
        padding: const EdgeInsets.fromLTRB(16, 11, 12, 9),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: ts(8, w: FontWeight.w600, color: C.label55, spacing: -0.16),
                ),
                const SizedBox(height: 10),
                Text(value, style: ts(15, w: FontWeight.w700, spacing: 0.15)),
                const SizedBox(height: 8),
                if (caption != null)
                  Text(
                    caption!,
                    style: ts(
                      7.5,
                      w: onTap == null ? FontWeight.w400 : FontWeight.w500,
                      color: onTap == null ? C.label55 : C.peachText,
                      spacing: -0.15,
                    ),
                  ),
              ],
            ),
            if (onTap != null) Positioned(top: 2, right: 0, child: svg('chevron-right', width: 4, height: 7)),
          ],
        ),
      ),
    ),
  );
}

/// Figma 35:422: AI recap with sparkle icon; numbers in bold; "Ask Sinag about yesterday →".
class _Summary extends StatelessWidget {
  const _Summary(this.s, {required this.onAsk});
  final Map<String, dynamic> s;
  final VoidCallback onAsk;

  /// Bold every figure in the recap (₱92.50, 88%, 14.7 kWh), as in the design.
  static final _figure = RegExp(r'₱\s?[\d,]+(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:%|kWh)');

  List<TextSpan> _spans(String text) {
    final light = ts(10, w: FontWeight.w300, height: 1.4);
    final bold = ts(10, w: FontWeight.w700, height: 1.4);
    final out = <TextSpan>[];
    var i = 0;
    for (final m in _figure.allMatches(text)) {
      if (m.start > i) out.add(TextSpan(text: text.substring(i, m.start), style: light));
      out.add(TextSpan(text: m.group(0), style: bold));
      i = m.end;
    }
    if (i < text.length) out.add(TextSpan(text: text.substring(i), style: light));
    return out;
  }

  @override
  Widget build(BuildContext context) => SCard(
    padding: const EdgeInsets.fromLTRB(16, 15, 16, 10),
    border: Border.all(color: C.orangeLine, width: 0.5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        svg('sparkles', width: 15, height: 15),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(TextSpan(children: _spans(s['summary'] as String))),
              const SizedBox(height: 6),
              InkWell(
                onTap: onAsk,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Ask Sinag about yesterday',
                        style: ts(7, w: FontWeight.w600, color: C.orange, height: 13 / 7),
                      ),
                      const SizedBox(width: 6),
                      svg('link-arrow', width: 6, height: 5),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Inverter + Sinag device status (presentation slide 5): inverter temperature, fault code, Wi-Fi signal.
/// Temperature colours follow the server's high-temp alert (on above 60 °C, warning from 55 °C).
class _DeviceHealth extends StatelessWidget {
  const _DeviceHealth({required this.telemetry, this.device});
  final Map<String, dynamic> telemetry;
  final Map<String, dynamic>? device;

  static (String, Color) _signal(num? rssi) => switch (rssi) {
        null => ('—', C.muted),
        >= -60 => ('Malakas', C.green),
        >= -75 => ('Katamtaman', C.amber),
        _ => ('Mahina', C.red),
      };

  @override
  Widget build(BuildContext context) {
    final temp = telemetry['inv_temp_c'] as num?;
    final fault = (telemetry['fault_code'] as num?)?.toInt() ?? 0;
    final tempColor = temp == null ? C.muted : (temp > 60 ? C.red : (temp >= 55 ? C.amber : C.green));
    final (signal, signalColor) = _signal(device?['rssi'] as num?);

    Widget item(IconData icon, Color color, String label, String value, {VoidCallback? onTap}) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Flexible(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: ts(7.5, w: FontWeight.w600, color: C.label55)),
                    Text(value, overflow: TextOverflow.ellipsis, style: ts(10, w: FontWeight.w700, color: color)),
                  ]),
                ),
              ]),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.orangeLine, width: 0.5),
      ),
      child: Row(children: [
        item(Icons.thermostat_rounded, tempColor, 'Inverter', temp == null ? '—' : '${temp.round()}°C'),
        item(
          fault == 0 ? Icons.check_circle_rounded : Icons.error_rounded,
          fault == 0 ? C.green : C.red,
          'Status',
          fault == 0 ? 'Walang problema' : 'Fault $fault',
          onTap: fault == 0 ? null : () => context.go(Routes.alerts),
        ),
        item(Icons.wifi_rounded, signalColor, 'Sinag device', signal),
      ]),
    );
  }
}
