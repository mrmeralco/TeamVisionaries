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
    final offline = live.state == 'offline' || live.device?['online'] == false;
    final w = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top; // status bar

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
                        // The first screen arrives once per launch: greeting, then the hero card.
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
                              Text('Here’s what’s happening at home.', style: ts(13, w: FontWeight.w500)),
                            ],
                          ),
                        ),
                        const SizedBox(height: S.x4),
                        Padding(
                          padding: const EdgeInsets.only(right: S.x2),
                          child: EnterOnce(
                            id: 'home-hero',
                            delay: const Duration(milliseconds: 80),
                            child: _Hero(live: data),
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
                    child: Freshness(readingTs: intOrNull(live.telemetry?['ts']), link: live.link,
                        deviceOnline: live.device?['online'] as bool?),
                  ),
                  _StateBanner(live: live),
                  if (inBrownout) advisor,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
                    child: EnterOnce(
                      id: 'home-stats',
                      delay: const Duration(milliseconds: 160),
                      child: _Stats(telemetry: live.telemetry, outdated: offline),
                    ),
                  ),
                  if (live.telemetry != null || offline)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
                      child: _DeviceHealth(telemetry: live.telemetry ?? const {}, device: live.device, offline: offline),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(S.gutter, S.x3, S.gutter, 0),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _Money(
                              'Saved today',
                              formatPhp(numOr(data['saved_today_php'])),
                              caption: rate == null ? null : 'At ${formatPhp(rate)}/kWh',
                            ),
                          ),
                          const SizedBox(width: S.x2),
                          Expanded(
                            child: _Money(
                              'Est. monthly bill',
                              forecast is num ? formatPhp(forecast, whole: true) : '—',
                              caption: 'See bill details',
                              onTap: () => context.go(Routes.bill),
                            ),
                          ),
                        ],
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
    final text = state == 'offline' && t.isNotEmpty
        ? 'Offline ang Solaris device. Huling reading ang ipinapakita.'
        : str(live?['status_line'], 'Kumokonekta sa Solaris… Ilang saglit lang.');
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
            borderRadius: R.card,
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

/// Fault / offline get a tappable banner so the user knows what to do next. A brownout gets the
/// Brownout advisor card in this place instead ([_BrownoutAdvisor]).
class _StateBanner extends ConsumerWidget {
  const _StateBanner({required this.live});
  final LiveState live;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        'Walang bagong data. Tingnan kung naka-on ang Solaris at konektado sa hotspot.',
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

  static bool active(LiveState live) => live.state != 'offline' && live.device?['online'] != false &&
      (live.state == 'brownout' || live.telemetry?['grid_on'] == false);

  static String _hours(num? h) => h == null ? '—' : '~${h.toStringAsFixed(1)}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    if (live.state == 'offline' || live.device?['online'] == false) return const SizedBox.shrink();
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

class _Stats extends StatelessWidget {
  const _Stats({required this.telemetry, this.outdated = false});
  final Map<String, dynamic>? telemetry;
  final bool outdated;

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
        gap: S.x2,
        runGap: S.x2,
        children: [
          _Tile('Solar production', kwNum(t['pv_w']), 'kW', outdated: outdated),
          _Tile('Home usage', kwNum(t['load_w']), 'kW', outdated: outdated),
          _Tile('Battery level', soc is num ? pctNum(soc) : '—', '%',
              note: _battNote(t['batt_w'] as num?), outdated: outdated),
          _Tile(
            'Grid power',
            gridOn ? kwNum(t['grid_w']) : 'Off',
            gridOn ? 'kW' : '',
            note: gridOn ? _gridNote(t['grid_w'] as num?) : 'Brownout',
            outdated: outdated,
          ),
        ],
      );
    }
    // Figma 22:122: yellow panel, 353 × 192, drop shadow 0 2 4 rgba(0,0,0,.25).
    return Container(
      padding: const EdgeInsets.all(S.x3),
      decoration: BoxDecoration(
        color: C.yellow,
        borderRadius: R.card,
        boxShadow: const [BoxShadow(color: C.shadow, blurRadius: 4, offset: Offset(0, 2))],
      ),
      child: body,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.unit, {this.note, this.outdated = false});
  final String label, value, unit;
  final String? note;
  final bool outdated;

  @override
  Widget build(BuildContext context) => Readout(
    label: label,
    value: value,
    unit: unit,
    note: outdated ? 'Last reading, outdated' : note,
    child: Container(
      constraints: const BoxConstraints(minHeight: 77),
      padding: const EdgeInsets.fromLTRB(S.x3, S.x3, S.x2, S.x2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: R.tile,
        border: Border.all(color: C.tileBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: ts(11, w: FontWeight.w600, color: C.label, spacing: -0.1)),
          if (outdated)
            Text('Outdated', style: ts(10, w: FontWeight.w700, color: C.muted))
          else if (note != null)
            Text(note!, style: ts(10, w: FontWeight.w700, color: C.orangeText)),
          const SizedBox(height: 8),
          Reading(value, unit, valueColor: outdated ? C.muted : C.orangeDeep, unitWeight: FontWeight.w700),
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
    child: PressCard(
      onTap: onTap,
      minHeight: 76,
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x3, S.x3),
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
  const _DeviceHealth({required this.telemetry, this.device, this.offline = false});
  final Map<String, dynamic> telemetry;
  final Map<String, dynamic>? device;
  final bool offline;

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
    final tempColor = offline || temp == null ? C.muted : (temp > 60 ? C.red : (temp >= 55 ? C.amber : C.green));
    final (signal, signalColor) = offline || device?['online'] == false
        ? ('Offline', C.red)
        : _signal(device?['rssi'] as num?);

    Widget item(IconData icon, Color color, String label, String value, {String? note, VoidCallback? onTap}) => Expanded(
          child: Semantics(
            button: onTap != null,
            label: '$label: $value${note == null ? '' : '. $note'}',
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
                        Text(value, overflow: offline ? TextOverflow.visible : TextOverflow.ellipsis,
                            style: ts(11, w: FontWeight.w700, color: color)),
                        if (note != null) Text(note, style: ts(10, color: C.muted)),
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
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          item(Icons.thermostat_rounded, tempColor, 'Inverter', temp == null ? '—' : '${temp.round()}°C',
              note: offline && temp != null ? 'Last reading' : null),
          item(
            offline ? Icons.help_outline_rounded : (fault == 0 ? Icons.check_circle_rounded : Icons.error_rounded),
            offline ? C.muted : (fault == 0 ? C.green : C.red),
            'Inverter status',
            offline ? 'Unavailable' : (fault == 0 ? 'No issues' : 'Fault $fault'),
            onTap: !offline && fault != 0 ? () => context.go(Routes.alerts) : null,
          ),
          item(offline ? Icons.wifi_off_rounded : Icons.wifi_rounded, signalColor, 'Solaris device', signal),
        ]),
        if (offline && fault != 0)
          LinkButton('Last reported fault: $fault', onTap: () => context.go(Routes.alerts)),
      ]),
    );
  }
}
