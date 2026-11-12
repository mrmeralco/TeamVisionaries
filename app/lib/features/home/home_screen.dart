// Home (Figma "Home"): live status from /ws/live, readings, saved today, est. bill, yesterday's recap.
// States (TESTING.md): solar | battery | grid | brownout | fault | offline, and empty (telemetry null).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'house_scene.dart';

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

    Future<void> refresh() async {
      ref.invalidate(billProvider);
      ref.invalidate(serverSettingsProvider);
      ref.invalidate(brownoutProvider);
      ref.invalidate(outlookProvider);
      await ref.refresh(dailySummaryProvider.future).then((_) {}, onError: (_) {});
    }

    final rate = (data?['rate_php_per_kwh'] as num?) ?? (bill?['rate_php_per_kwh'] as num?);
    final forecast = bill?['forecast_php'];
    // During a brownout the advisor leads the page (it replaces the alert banner); otherwise it sits
    // after the money cards.
    final inBrownout = _BrownoutAdvisor.active(live);
    const advisor = _BrownoutAdvisor();

    return ColoredBox(
      color: C.cream,
      child: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            // The house leads the page, Tesla-style: greeting and live status on the sky, then the
            // house across the full width, its lawn fading into the dashboard below.
            _Sky(
              state: str(data?['state'], 'offline'),
              child: SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const TopBar(onDark: true),
                          // Dark text: white on the orange → yellow sky was 1.5:1 to 2.8:1.
                          EnterOnce(
                            id: 'home-greeting',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    '${_greeting()}${name.isEmpty ? '' : ', $name'}!',
                                    style: ts(24, w: FontWeight.w700, spacing: -0.48),
                                  ),
                                ),
                                const SizedBox(height: S.x1),
                                Padding(
                                  padding: const EdgeInsets.only(right: S.x2),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      str(data?['status_line'], 'Kumokonekta sa Solaris… Ilang saglit lang.'),
                                      style: ts(13, w: FontWeight.w500, height: 1.4),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    EnterOnce(
                      id: 'home-hero',
                      delay: const Duration(milliseconds: 80),
                      child: HouseScene(
                        telemetry: mapOf(data?['telemetry']),
                        offline: str(data?['state'], 'offline') == 'offline' || live.telemetry == null,
                      ),
                    ),
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
                    padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
                    child: Freshness(readingTs: intOrNull(live.telemetry?['ts']), link: live.link),
                  ),
                  _StateBanner(live: live),
                  if (inBrownout) advisor,
                  if (live.telemetry == null) const _NoReadings(),
                  if (live.telemetry != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
                      child: _DeviceHealth(telemetry: live.telemetry!, device: live.device),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
                    child: EnterOnce(
                      id: 'home-stats',
                      delay: const Duration(milliseconds: 160),
                      child: SCard(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            _Row(
                              Icons.savings_outlined,
                              'Saved today',
                              formatPhp(numOr(data['saved_today_php'])),
                              caption: rate == null ? null : 'At ${formatPhp(rate)}/kWh',
                            ),
                            const Divider(height: 1, thickness: 0.5, indent: 68, color: C.divider),
                            _Row(
                              Icons.receipt_long_outlined,
                              'Est. monthly bill',
                              forecast is num ? formatPhp(forecast, whole: true) : '—',
                              caption: 'See bill details',
                              onTap: () => context.go(Routes.bill),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!inBrownout) advisor,
                ],
                const Padding(
                  padding: EdgeInsets.fromLTRB(S.gutter, S.x6, S.gutter, 0),
                  child: SectionTitle('Yesterday’s summary'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, kFabClearance),
                  child: AsyncBody(
                    value: summary,
                    onRetry: () => ref.invalidate(dailySummaryProvider),
                    data: (s) => _Summary(
                      s,
                      onAsk: () {
                        ref.read(chatProvider.notifier).send('Kumusta ang solar at kuryente ko kahapon?');
                        context.push(Routes.ask);
                      },
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// The sky behind the greeting and the house: the state's colours from the top, easing toward the
/// page so the house's lawn fades straight into the dashboard.
class _Sky extends StatelessWidget {
  const _Sky({required this.state, required this.child});
  final String state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final (top, low) = switch (state) {
      'brownout' => (C.heroBrownout[1], C.heroBrownout[0]),
      'fault' => (C.heroFault[1], C.heroFault[0]),
      'offline' => (C.heroOffline[1], C.heroOffline[0]),
      _ => (C.orange, C.yellow),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, low, Color.lerp(low, C.cream, 0.55)!],
          stops: const [0, 0.5, 1],
        ),
      ),
      child: child,
    );
  }
}

/// Fault / offline get a tappable banner so the user knows what to do next. A brownout gets the
/// Brownout advisor card in this place instead ([_BrownoutAdvisor]).
class _StateBanner extends ConsumerWidget {
  const _StateBanner({required this.live});
  final LiveState live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastSeen = intOrNull(live.device?['last_seen_ts']);
    final (IconData, Color, String, String, VoidCallback?)? b = switch (live.state) {
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
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
      child: PressCard(
        color: color.withValues(alpha: 0.1),
        side: BorderSide(color: color.withValues(alpha: 0.35), width: 0.5),
        onTap: onTap,
        minHeight: kMinTap,
        padding: const EdgeInsets.all(S.x3),
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
                      Text(sub, style: ts(12)),
                    ],
                  ),
                ),
                if (onTap != null) Icon(Icons.chevron_right_rounded, color: color),
              ],
            ),
      ),
    );
  }
}

/// The Brownout Advisor on the dashboard: is the grid on, and how long the battery would carry the
/// house. Brownout or not comes from the live reading (state, grid_on), so it never disagrees with the
/// tiles above it. During a brownout: hours left at today's use and Mira's advice (GET /api/brownout,
/// refetched on every reading). Otherwise: how long the battery would last if one hit (GET
/// /api/outlook). Tap: the full advisor with the 48-hour outlook.
class _BrownoutAdvisor extends ConsumerWidget {
  const _BrownoutAdvisor();

  static bool active(LiveState live) => live.state == 'brownout' || live.telemetry?['grid_on'] == false;

  static String _hours(num? h) => h == null ? '—' : '~${h.toStringAsFixed(1)}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final on = active(live);
    ref.listen(liveProvider.select((s) => s.telemetry?['ts']), (prev, next) {
      if (prev != null && next != prev && active(ref.read(liveProvider))) ref.invalidate(brownoutProvider);
    });
    final b = ref.watch(brownoutProvider).value;
    final outlook = ref.watch(outlookProvider).value;
    final ifHits = outlook?['brownout'] is Map ? mapOf(outlook!['brownout']) : null;
    final soc = live.telemetry?['batt_soc'];
    final outages = b?['outages_this_month'];

    final color = on ? C.orangeDeep : C.green;
    final title = on ? 'May brownout ngayon' : 'May kuryente mula sa grid';
    final value = on
        ? _hours(b?['runtime_h'] as num?)
        : (ifHits == null ? '—' : (ifHits['hours'] == null ? '48+' : _hours(ifHits['hours'] as num)));
    final caption = on ? 'tatagal pa ang battery sa kasalukuyang gamit' : 'kakayanin ng battery kung mag-brownout';
    final start = intOrNull(b?['start_ts']);
    final facts = [
      if (on && start != null) 'Nagsimula ${formatClock(start)}',
      if (soc is num) 'Battery ${pctNum(soc)}%',
      if (outages != null) '$outages brownout ngayong buwan',
    ].join(' · ');
    final advice = on ? str(b?['advice']) : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(S.gutter, S.x6, S.gutter, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle('Brownout advisor'),
          const SizedBox(height: S.x3),
          Semantics(
            button: true,
            label: '$title. $value hours: $caption.${facts.isEmpty ? '' : ' $facts.'} Open Brownout Advisor',
            excludeSemantics: true,
            child: PressCard(
              color: on ? C.orangeDeep.withValues(alpha: 0.08) : C.card,
              side: on ? BorderSide(color: C.orangeDeep.withValues(alpha: 0.5), width: 0.5) : kCardLine,
              onTap: () => context.push(Routes.brownout),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: R.control),
                      child: Icon(on ? Icons.power_off_rounded : Icons.power_rounded, size: 18, color: color),
                    ),
                    const SizedBox(width: S.x3),
                    Expanded(child: Text(title, style: ts(14, w: FontWeight.w700, color: on ? C.orangeDeep : C.ink))),
                    Icon(Icons.chevron_right_rounded, color: color),
                  ]),
                  const SizedBox(height: S.x3),
                  Reading(value, 'hrs', size: 28, valueColor: on ? C.orangeDeep : C.ink),
                  const SizedBox(height: S.x1),
                  Text(caption, style: ts(12, color: C.label)),
                  if (advice.isNotEmpty) ...[
                    const SizedBox(height: S.x3),
                    Text(advice, maxLines: 3, overflow: TextOverflow.ellipsis, style: ts(13, height: 1.45)),
                  ],
                  if (facts.isNotEmpty) ...[
                    const SizedBox(height: S.x3),
                    Text(facts, style: ts(11, color: C.muted)),
                  ],
                  const SizedBox(height: S.x3),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Open Brownout Advisor', style: ts(12, w: FontWeight.w700, color: C.orangeText)),
                    const SizedBox(width: S.x1),
                    const Icon(Icons.arrow_forward_rounded, size: 14, color: C.orangeText),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown under the house until the Solaris device sends its first reading.
class _NoReadings extends StatelessWidget {
  const _NoReadings();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
        child: SCard(
          padding: const EdgeInsets.symmetric(vertical: S.x6, horizontal: S.x3),
          child: Column(
            children: [
              const Icon(Icons.solar_power_rounded, color: C.orangeDeep, size: 32),
              const SizedBox(height: S.x2),
              Text('Wala pang reading mula sa device.', style: ts(13, w: FontWeight.w700), textAlign: TextAlign.center),
              const SizedBox(height: 2),
              Text(
                'Lalabas sa bahay ang solar, battery at grid kapag naka-on na ang Solaris device.',
                style: ts(11, color: C.label),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}

/// One row of the dashboard list, Tesla-style: icon, label, the number, a short caption, and a
/// chevron when it opens something.
class _Row extends StatelessWidget {
  const _Row(this.icon, this.label, this.value, {this.caption, this.onTap});
  final IconData icon;
  final String label, value;
  final String? caption;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: C.cream, borderRadius: R.control),
            child: Icon(icon, size: 22, color: C.orangeDeep),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: ts(12, w: FontWeight.w600, color: C.label)),
                Text(value, style: ts(18, w: FontWeight.w700, height: 1.3)),
                if (caption != null)
                  Text(
                    caption!,
                    style: ts(
                      11,
                      w: onTap == null ? FontWeight.w500 : FontWeight.w700,
                      color: onTap == null ? C.label : C.orangeText,
                    ),
                  ),
              ],
            ),
          ),
          if (onTap != null) const Icon(Icons.chevron_right_rounded, color: C.orangeText),
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: '$label: $value${caption == null ? '' : '. $caption'}',
      excludeSemantics: true,
      child: onTap == null ? row : InkWell(onTap: onTap, borderRadius: R.card, child: row),
    );
  }
}

/// Figma 35:422: AI recap with sparkle icon; numbers in bold; "Ask Mira about yesterday →".
class _Summary extends StatelessWidget {
  const _Summary(this.s, {required this.onAsk});
  final Map<String, dynamic> s;
  final VoidCallback onAsk;

  /// Bold every figure in the recap (₱92.50, 88%, 14.7 kWh), as in the design.
  static final _figure = RegExp(r'₱\s?[\d,]+(?:\.\d+)?|\d[\d,]*(?:\.\d+)?\s?(?:%|kWh)');

  List<TextSpan> _spans(String text) {
    final light = ts(13, height: 1.45);
    final bold = ts(13, w: FontWeight.w700, height: 1.45);
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
      padding: const EdgeInsets.fromLTRB(S.x4, S.x4, S.x2, S.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const MiraAvatar(size: 32), // Mira wrote the recap
          const SizedBox(width: S.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: summary.isEmpty
                      ? Text('Wala pang buod para kahapon.', style: ts(13, color: C.muted))
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
              borderRadius: R.control,
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

    return SCard(
      padding: const EdgeInsets.symmetric(horizontal: S.x3, vertical: S.x1),
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
