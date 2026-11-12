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
import '../alerts/alert_detail.dart';
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
    final name = str(ref.watch(serverSettingsProvider).value?['user_name']);
    final data = live.live;
    final w = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top; // status bar

    Future<void> refresh() async {
      ref.invalidate(billProvider);
      ref.invalidate(serverSettingsProvider);
      await ref.refresh(dailySummaryProvider.future).then((_) {}, onError: (_) {});
    }

    final rate = (data?['rate_php_per_kwh'] as num?) ?? (bill?['rate_php_per_kwh'] as num?);
    final forecast = bill?['forecast_php'];

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
              // Ends just below the hero card (Figma: 278 of 852). Width is capped by the app's max width,
              // so the stretch stays mild on tablets and the web.
              child: SvgPicture.asset('assets/images/header-circle.svg', width: w, height: 278 + top, fit: BoxFit.fill),
            ),
            ListView(
              padding: EdgeInsets.zero,
              children: [
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const TopBar(onDark: true),
                        // Dark text: white on the orange → yellow header was 1.5:1 to 2.8:1.
                        Semantics(
                          header: true,
                          child: Text(
                            '${_greeting()}${name.isEmpty ? '' : ', $name'}!',
                            style: ts(24, w: FontWeight.w700, spacing: -0.48),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text('Here’s what’s happening at home.', style: ts(12, w: FontWeight.w500)),
                        const SizedBox(height: 18),
                        Padding(padding: const EdgeInsets.only(right: 8), child: _Hero(live: data)),
                      ],
                    ),
                  ),
                ),
                if (data == null && live.link == LinkStatus.waiting)
                  ErrorBox(onRetry: () => ref.invalidate(liveProvider), error: live.error)
                else if (data == null)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: Freshness(readingTs: intOrNull(live.telemetry?['ts']), link: live.link),
                  ),
                  _StateBanner(live: live),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
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
                              formatPhp(numOr(data['saved_today_php'])),
                              caption: rate == null ? null : 'At ${formatPhp(rate)}/kWh',
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: _Money(
                              'Est. Monthly Bill',
                              forecast is num ? formatPhp(forecast, whole: true) : '—',
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
                  child: Semantics(
                    header: true,
                    child: Text('Yesterday’s Summary', style: ts(13, w: FontWeight.w700, spacing: -0.24)),
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

/// Figma hero card: status sentence on the left, trees + house art at the bottom. Sizes scale with the
/// card's width (designed at 353 px), and the card grows with the text, so a 320 px phone or a large
/// system font never puts the house over the words or cuts the sentence off.
class _Hero extends StatelessWidget {
  const _Hero({required this.live});
  final Map<String, dynamic>? live;

  @override
  Widget build(BuildContext context) {
    final state = str(live?['state'], 'offline');
    final t = mapOf(live?['telemetry']);
    final sunny = numOr(t['pv_w']) > 0;
    final text = str(live?['status_line'], 'Kumokonekta sa Solaris… Ilang saglit lang.');
    final colors = switch (state) {
      'brownout' => C.heroBrownout,
      'fault' => C.heroFault,
      'offline' => C.heroOffline,
      _ => C.heroSunny,
    };
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final k = w / 353; // Figma card width
        return Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: 154 * k.clamp(0.85, 1.2)),
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
                width: 264 * k,
                height: 98 * k,
                child: ExcludeSemantics(child: Image.asset('assets/images/trees.png', fit: BoxFit.fill)),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                width: 194 * k,
                height: 143 * k,
                child: ExcludeSemantics(child: Image.asset('assets/images/house.png', fit: BoxFit.fill)),
              ),
              if (sunny) ...[
                Positioned(
                  left: 95.4 * k,
                  bottom: 58.4 * k,
                  child: SvgPicture.asset('assets/images/arrow-up.svg', width: 6 * k, height: 39 * k),
                ),
                Positioned(
                  left: 98 * k,
                  bottom: 58.4 * k,
                  child: SvgPicture.asset('assets/images/arrow-right.svg', width: 74 * k, height: 1),
                ),
              ],
              // The only non-positioned child: it sets the card's height. It stops before the house
              // (which starts at 45 % of the width) and leaves room under it for the trees.
              Padding(
                padding: EdgeInsets.fromLTRB(18, 14, 0, 70 * k),
                child: SizedBox(
                  width: w * 0.45 - 22,
                  child: Semantics(
                    liveRegion: true,
                    child: Text(text, style: ts(12, w: FontWeight.w600, height: 1.3)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Brownout / fault / offline get a tappable banner so the user knows what to do next.
class _StateBanner extends ConsumerWidget {
  const _StateBanner({required this.live});
  final LiveState live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastSeen = intOrNull(live.device?['last_seen_ts']);
    final (IconData, Color, String, String, VoidCallback?)? b = switch (live.state) {
      'brownout' => (
        Icons.power_off_rounded,
        C.orangeDeep,
        'May brownout ngayon',
        'Tingnan kung gaano katagal ang battery',
        () => context.push(Routes.brownout),
      ),
      'fault' => (
        Icons.warning_amber_rounded,
        C.red,
        'May problema ang inverter',
        'Tingnan ang paliwanag at kung ano ang gagawin',
        () {
          // Open the newest inverter alert's explanation (Alerts tab underneath), or just the tab.
          final alerts = listOfMaps(ref.read(alertsProvider).value?['alerts']);
          final fault = alerts.where((a) => a['type'] == 'fault' || a['type'] == 'high_temp').firstOrNull;
          context.go(Routes.alerts);
          if (fault != null) showAlertDetail(context, ref, fault);
        },
      ),
      'offline' => (
        Icons.cloud_off_rounded,
        C.muted,
        'Offline ang Solaris device',
        lastSeen != null ? 'Huling reading: ${formatAgo(lastSeen)}' : 'Wala pang natatanggap na reading',
        null,
      ),
      _ => null,
    };
    if (b == null) return const SizedBox.shrink();
    final (icon, color, title, sub, onTap) = b;
    return Padding(
      padding: const EdgeInsets.fromLTRB(19, 10, 19, 0),
      child: Material(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: kMinTap),
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: ts(13, w: FontWeight.w700, color: color == C.muted ? C.ink : color)),
                      const SizedBox(height: 2),
                      Text(sub, style: ts(11)),
                    ],
                  ),
                ),
                if (onTap != null) Icon(Icons.chevron_right_rounded, color: color),
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
    return w < 0 ? 'Charging' : 'In use';
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
            const Icon(Icons.solar_power_rounded, color: C.orangeDeep, size: 32),
            const SizedBox(height: 8),
            Text('Wala pang reading mula sa device.', style: ts(13, w: FontWeight.w700), textAlign: TextAlign.center),
            const SizedBox(height: 2),
            Text(
              'Lalabas dito ang solar, battery at grid kapag naka-on na ang Solaris device.',
              style: ts(11, color: C.labelOnYellow),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    } else {
      final gridOn = t['grid_on'] != false;
      final soc = t['batt_soc'];
      body = TwoCol(
        gap: 7,
        runGap: 9,
        children: [
          _Tile('Solar Production', kwNum(t['pv_w']), 'kW'),
          _Tile('Home Usage', kwNum(t['load_w']), 'kW'),
          _Tile('Battery Level', soc is num ? pctNum(soc) : '—', '%', note: _battNote(t['batt_w'] as num?)),
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
        boxShadow: const [BoxShadow(color: C.shadow, blurRadius: 4, offset: Offset(0, 2))],
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
  Widget build(BuildContext context) => Readout(
    label: label,
    value: value,
    unit: unit,
    note: note,
    child: Container(
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
          Text(label, style: ts(11, w: FontWeight.w600, color: C.label, spacing: -0.1)),
          if (note != null) Text(note!, style: ts(10, w: FontWeight.w700, color: C.orangeText)),
          const SizedBox(height: 8),
          Reading(value, unit, valueColor: C.orangeDeep, unitWeight: FontWeight.w700),
        ],
      ),
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
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$label: $value${caption == null ? '' : '. $caption'}',
    excludeSemantics: true,
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: const BorderSide(color: C.orangeLine, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 76),
          padding: const EdgeInsets.fromLTRB(16, 11, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Expanded(child: Text(label, style: ts(11, w: FontWeight.w600, color: C.label))),
                  if (onTap != null) const Icon(Icons.chevron_right_rounded, size: 18, color: C.orangeText),
                ],
              ),
              const SizedBox(height: 6),
              Text(value, style: ts(17, w: FontWeight.w700, spacing: 0.15)),
              if (caption != null) ...[
                const SizedBox(height: 6),
                Text(
                  caption!,
                  style: ts(
                    10,
                    w: onTap == null ? FontWeight.w500 : FontWeight.w700,
                    color: onTap == null ? C.label : C.orangeText,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Figma 35:422: AI recap with sparkle icon; numbers in bold; "Ask Mira about yesterday →".
class _Summary extends StatelessWidget {
  const _Summary(this.s, {required this.onAsk});
  final Map<String, dynamic> s;
  final VoidCallback onAsk;

  /// Bold every figure in the recap (₱92.50, 88%, 14.7 kWh), as in the design.
  static final _figure = RegExp(r'₱\s?[\d,]+(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:%|kWh)');

  List<TextSpan> _spans(String text) {
    final light = ts(12, height: 1.45);
    final bold = ts(12, w: FontWeight.w700, height: 1.45);
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
  Widget build(BuildContext context) {
    final summary = str(s['summary']);
    return SCard(
      padding: const EdgeInsets.fromLTRB(16, 15, 8, 4),
      border: Border.all(color: C.orangeLine, width: 0.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: svg('sparkles', width: 15, height: 15)),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: summary.isEmpty
                      ? Text('Wala pang buod para kahapon.', style: ts(12, color: C.muted))
                      : Text.rich(TextSpan(children: _spans(summary))),
                ),
                Transform.translate(offset: const Offset(-8, 0), child: LinkButton('Ask Mira about yesterday', onTap: onAsk)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Inverter + Solaris device status (presentation slide 5): inverter temperature, fault code, Wi-Fi signal.
/// Temperature colours follow the server's high-temp alert (on above 60 °C, warning from 55 °C).
class _DeviceHealth extends StatelessWidget {
  const _DeviceHealth({required this.telemetry, this.device});
  final Map<String, dynamic> telemetry;
  final Map<String, dynamic>? device;

  static (String, Color) _signal(num? rssi) => switch (rssi) {
        null => ('—', C.muted),
        >= -60 => ('Strong', C.green),
        >= -75 => ('Fair', C.amber),
        _ => ('Weak', C.red),
      };

  @override
  Widget build(BuildContext context) {
    final temp = telemetry['inv_temp_c'] as num?;
    final fault = (telemetry['fault_code'] as num?)?.toInt() ?? 0;
    final tempColor = temp == null ? C.muted : (temp > 60 ? C.red : (temp >= 55 ? C.amber : C.green));
    final (signal, signalColor) = _signal(device?['rssi'] as num?);

    Widget item(IconData icon, Color color, String label, String value, {VoidCallback? onTap}) => Expanded(
          child: Semantics(
            button: onTap != null,
            label: '$label: $value',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: kMinTap),
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: ts(10, w: FontWeight.w600, color: C.label)),
                        Text(value, overflow: TextOverflow.ellipsis, style: ts(11, w: FontWeight.w700, color: color)),
                      ],
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
          fault == 0 ? 'No issues' : 'Fault $fault',
          onTap: fault == 0 ? null : () => context.go(Routes.alerts),
        ),
        item(Icons.wifi_rounded, signalColor, 'Solaris device', signal),
      ]),
    );
  }
}
