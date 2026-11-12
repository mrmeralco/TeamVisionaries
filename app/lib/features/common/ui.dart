// Shared pieces of the Figma design: page header (title, subtitle, live-link dot, settings gear), back header
// for pushed screens, cards, readings, a two-column grid, AsyncValue loading/error states, data freshness
// and the bottom navigation bar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart' show SettingsNotKept;
import '../../providers/live_providers.dart';
import '../../providers/server_providers.dart';
import '../../services/api_service.dart';
import '../../services/live_connection.dart';
import 'mira.dart';

export 'mira.dart'; // Mira is part of the shared kit: screens import ui.dart

Widget svg(String name, {double? width, double? height, Color? color}) => SvgPicture.asset(
  'assets/images/$name.svg',
  width: width,
  height: height,
  colorFilter: color == null ? null : ColorFilter.mode(color, BlendMode.srcIn),
);

class GearButton extends StatelessWidget {
  const GearButton({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Settings',
    child: SizedBox.square(
      dimension: kMinTap,
      child: InkResponse(
        onTap: () => context.push(Routes.settings),
        radius: kMinTap / 2,
        child: Center(child: svg('gear', width: 27, height: 27)),
      ),
    ),
  );
}

/// Small dot + label: Live / Connecting / Reconnecting / Mock (state of /ws/live).
class LinkIndicator extends ConsumerWidget {
  const LinkIndicator({super.key, this.onDark = false});
  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final link = live.link;
    final mock = ref.watch(serverConfigProvider.select((c) => c.useMock));
    final (color, label) = switch (link) {
      LinkStatus.connected when !mock && live.device?['online'] == false => (C.red, 'Device offline'),
      LinkStatus.connected => (C.green, mock ? 'Mock' : 'Live'),
      LinkStatus.connecting => (C.amber, 'Connecting'),
      LinkStatus.waiting => (C.red, 'Reconnecting'),
    };
    return Semantics(
      label: 'Connection: $label',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: C.card.withValues(alpha: onDark ? 0.9 : 1),
          borderRadius: BorderRadius.circular(R.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: color),
            const SizedBox(width: 5),
            Text(label, style: ts(10, w: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// The row above every page title: link status + settings gear.
class TopBar extends StatelessWidget {
  const TopBar({super.key, this.onDark = false});
  final bool onDark;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
      LinkIndicator(onDark: onDark),
      const SizedBox(width: 4),
      const GearButton(),
    ],
  );
}

/// Title + subtitle, as on the Energy / Bill / Ask Mira / Alerts frames.
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, this.sub, {super.key, this.trailing});
  final String title;
  final String sub;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(S.gutter, S.x2, S.x3, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TopBar(),
        Row(
          children: [
            Expanded(
              child: Semantics(header: true, child: Text(title, style: ts(26, w: FontWeight.w700, spacing: -0.52))),
            ),
            // Flexible: at large text sizes a trailing button ("Mark all read") wraps instead of overflowing.
            if (trailing != null) Flexible(child: Align(alignment: Alignment.centerRight, child: trailing!)),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(sub, style: ts(12, color: C.muted)),
        ),
      ],
    ),
  );
}

/// Header for screens pushed on top of the tabs (Settings, Brownout Advisor): back button + link status,
/// then the same 26 px title and subtitle as [PageHeader], so pushed screens look like the tabs.
class BackHeader extends StatelessWidget {
  const BackHeader(this.title, this.sub, {super.key, this.trailing});
  final String title;
  final String sub;
  final Widget? trailing; // beside the link status, e.g. Ask Mira's "New conversation"

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                icon: Icon(Icons.arrow_back_rounded, color: C.ink),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              const LinkIndicator(),
              if (trailing != null) ...[const SizedBox(width: S.x1), trailing!],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(title, style: ts(26, w: FontWeight.w700, spacing: -0.52))),
              const SizedBox(height: 4),
              Text(sub, style: ts(12, color: C.muted)),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The one card recipe: white, [R.lg] corners, a 0.5 px orange hairline, no shadow.
BorderSide get kCardLine => BorderSide(color: C.orangeLine, width: 0.5);

class SCard extends StatelessWidget {
  const SCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(S.x4),
    this.color,
    this.border,
  });
  final Widget child;
  final EdgeInsets padding;
  final Color? color; // default [C.card]
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: color ?? C.card,
      borderRadius: R.card,
      border: border ?? Border.fromBorderSide(kCardLine),
    ),
    child: child,
  );
}

/// A card you can tap: the same recipe as [SCard], with a ripple, and it sinks slightly
/// (scale .98, 90 ms in, 120 ms out) while pressed, so the finger sees it answer. Drags cancel it;
/// it stays still under reduced motion.
class PressCard extends StatefulWidget {
  const PressCard({
    super.key,
    required this.child,
    this.onTap,
    this.color,
    this.side,
    this.padding = const EdgeInsets.all(S.x4),
    this.minHeight = 0,
  });
  final Widget child;
  final VoidCallback? onTap;
  final Color? color; // default [C.card]
  final BorderSide? side; // default [kCardLine]
  final EdgeInsets padding;
  final double minHeight;

  @override
  State<PressCard> createState() => _PressCardState();
}

class _PressCardState extends State<PressCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: _down && !reduceMotion(context) ? 0.98 : 1,
    duration: _down ? M.press : M.release,
    curve: M.ease,
    child: Material(
      color: widget.color ?? C.card,
      shape: RoundedRectangleBorder(borderRadius: R.card, side: widget.side ?? kCardLine),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (v) => setState(() => _down = v),
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: widget.minHeight),
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    ),
  );
}

/// Heading for a block of cards on a page ("Yesterday's summary", "Your solar savings").
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Semantics(header: true, child: Text(text, style: ts(15, w: FontWeight.w700, spacing: -0.15)));
}

/// Heading inside a card ("Weekly energy cost", "Mira's advice"). One step below [SectionTitle].
class CardTitle extends StatelessWidget {
  const CardTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Semantics(header: true, child: Text(text, style: ts(13, w: FontWeight.w700)));
}

/// The first screen arrives once per app launch: it rises 12 px and fades in over 600 ms
/// ([M.easeEnter]), after [delay]. Seen ids stand still from then on (tab switches, rebuilds), and
/// under reduced motion it never moves. Only transform and opacity change, so the layout never shifts.
class EnterOnce extends StatefulWidget {
  const EnterOnce({super.key, required this.id, required this.child, this.delay = Duration.zero});
  final String id;
  final Widget child;
  final Duration delay;

  static final _seen = <String>{};

  @override
  State<EnterOnce> createState() => _EnterOnceState();
}

class _EnterOnceState extends State<EnterOnce> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    if (EnterOnce._seen.add(widget.id)) {
      final total = widget.delay + M.enter;
      final start = widget.delay.inMicroseconds / total.inMicroseconds;
      _c = AnimationController(vsync: this, duration: total)..forward();
      _t = CurvedAnimation(parent: _c!, curve: Interval(start, 1, curve: M.easeEnter));
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_c == null || reduceMotion(context)) return widget.child;
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(offset: Offset(0, 12 * (1 - _t.value)), child: child),
      ),
      child: widget.child,
    );
  }
}

/// Two-column grid whose rows grow with their content (no fixed aspect ratio, so large system
/// font sizes and small phones never overflow).
class TwoCol extends StatelessWidget {
  const TwoCol({super.key, required this.children, this.gap = 12, this.runGap = 12});
  final List<Widget> children;
  final double gap, runGap;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var i = 0; i < children.length; i += 2) ...[
        if (i > 0) SizedBox(height: runGap),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: children[i]),
              SizedBox(width: gap),
              Expanded(child: i + 1 < children.length ? children[i + 1] : const SizedBox.shrink()),
            ],
          ),
        ),
      ],
    ],
  );
}

/// Big number + small unit, baseline-aligned ("3.5 kW"). A new value fades in instead of jumping.
class Reading extends StatelessWidget {
  const Reading(
    this.value,
    this.unit, {
    super.key,
    this.size = 24,
    this.unitColor,
    this.valueColor,
    this.unitWeight = FontWeight.w600,
  });
  final String value;
  final String unit;
  final double size;
  final Color? unitColor; // default [C.orangeText]
  final Color? valueColor; // default [C.ink]
  final FontWeight unitWeight;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      Flexible(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
          child: Text(
            value,
            key: ValueKey(value),
            style: ts(size, w: FontWeight.w900, color: valueColor ?? C.ink),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      if (unit.isNotEmpty) ...[
        const SizedBox(width: 6),
        Text(unit, style: ts(12, w: unitWeight, color: unitColor ?? C.orangeText)),
      ],
    ],
  );
}

/// Reads a label + value + unit tile as one phrase for screen readers ("Solar Production: 3.2 kW, Charging")
/// instead of three separate fragments.
class Readout extends StatelessWidget {
  const Readout({super.key, required this.label, required this.value, this.unit = '', this.note, required this.child});
  final String label, value, unit;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$label: $value${unit.isEmpty ? '' : ' $unit'}${note == null ? '' : ', $note'}',
    excludeSemantics: true,
    child: child,
  );
}

/// Rebuilds [builder] every [every] (for "2 min ago" texts and running timers).
class Every extends StatefulWidget {
  const Every(this.every, {super.key, required this.builder});
  final Duration every;
  final WidgetBuilder builder;
  @override
  State<Every> createState() => _EveryState();
}

class _EveryState extends State<Every> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.every, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// "Updated 2 min ago" for live readings. When the socket is down or the reading is old it says so,
/// so the user knows the numbers on screen may not be current.
class Freshness extends StatelessWidget {
  const Freshness({super.key, required this.readingTs, required this.link, this.deviceOnline});
  final bool? deviceOnline;
  final int? readingTs; // telemetry.ts, Unix seconds
  final LinkStatus link;

  @override
  Widget build(BuildContext context) => Every(
    const Duration(seconds: 30),
    builder: (context) {
      final t = readingTs;
      final age = t == null ? null : DateTime.now().millisecondsSinceEpoch ~/ 1000 - t;
      final when = t == null ? '' : (age! < 60 ? 'just now' : formatAgo(t).toLowerCase());
      final lastReceived = age != null && age < 60 ? '${age.clamp(0, 59)} sec ago' : when;
      final (icon, color, text) = switch (link) {
        LinkStatus.connected when deviceOnline == false => (
          Icons.cloud_off_rounded, C.red, t == null ? 'Device offline' : 'Device offline · last received $lastReceived'),
        LinkStatus.connected when age != null && age > 120 => (Icons.schedule_rounded, C.amber, 'Last reading $when'),
        LinkStatus.connected => (Icons.check_circle_outline_rounded, C.muted, t == null ? 'Live' : 'Updated $when'),
        _ => (
          Icons.cloud_off_rounded,
          C.red,
          t == null ? 'Not connected' : 'Not connected · showing the reading from $when',
        ),
      };
      return Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Expanded(child: Text(text, style: ts(11, w: FontWeight.w600, color: color))),
          ],
        ),
      );
    },
  );
}

/// Loading spinner / friendly error with retry / data, for one provider's AsyncValue. While a refresh is
/// running over existing data, the data stays and a thin progress bar shows above it.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.data, required this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncValue(:final value?, hasValue: true, :final isLoading) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 2, child: isLoading ? const LinearProgressIndicator(minHeight: 2) : null),
        data(value),
      ],
    ),
    AsyncError(:final error) => ErrorBox(onRetry: onRetry, error: error),
    _ => const Padding(
      padding: EdgeInsets.all(40),
      child: Center(child: CircularProgressIndicator()),
    ),
  };
}

enum ErrorKind { offline, server, data }

/// What went wrong, in words the user can act on.
class FriendlyError {
  const FriendlyError(this.kind, this.title, this.hint);
  final ErrorKind kind;
  final String title, hint;
}

FriendlyError friendlyError(Object? e) {
  if (e is SettingsNotKept) {
    return FriendlyError(
      ErrorKind.server,
      e.fields.contains('setup')
          ? 'Hindi naitago ng server ang setup ng bahay.'
          : 'Hindi naitago ng server ang ilang settings.',
      'Baka luma ang Solaris server: i-update ito (git pull), i-restart, tapos subukan ulit.',
    );
  }
  if (e is ApiException) {
    return FriendlyError(
      ErrorKind.server,
      'May problema sa Solaris server (error ${e.statusCode}).',
      'Subukan ulit mamaya. Kung tuloy-tuloy, i-restart ang server.',
    );
  }
  // dart:io SocketException can't be imported on web, so match it by name.
  final unreachable = e == null ||
      e is TimeoutException ||
      e is http.ClientException ||
      e.runtimeType.toString().contains('Socket') ||
      e.runtimeType.toString().contains('WebSocket');
  if (unreachable) {
    return const FriendlyError(
      ErrorKind.offline,
      'Hindi maabot ang Solaris server.',
      'Tingnan ang server address sa Settings, tapos subukan ulit.',
    );
  }
  // TypeError, FormatException…: the server answered, but not with what this app expects.
  return const FriendlyError(
    ErrorKind.data,
    'Hindi mabasa ang sagot ng server.',
    'Baka magkaiba ang version ng app at server. I-update pareho, tapos subukan ulit.',
  );
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.onRetry, this.error, this.message});
  final VoidCallback onRetry;
  final Object? error;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final f = friendlyError(error);
    final icon = switch (f.kind) {
      ErrorKind.offline => Icons.wifi_off_rounded,
      ErrorKind.server => Icons.dns_rounded,
      ErrorKind.data => Icons.report_gmailerrorred_rounded,
    };
    return Padding(
      padding: const EdgeInsets.all(S.gutter),
      child: SCard(
        child: Column(
          children: [
            Icon(icon, color: C.orangeDeep, size: 32),
            const SizedBox(height: 8),
            Text(message ?? f.title, style: ts(13, w: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(f.hint, style: ts(12, color: C.muted, height: 1.4), textAlign: TextAlign.center),
            const SizedBox(height: S.x4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(onPressed: onRetry, child: const Text('Try again')),
                if (f.kind == ErrorKind.offline)
                  OutlinedButton(onPressed: () => context.push(Routes.settings), child: const Text('Open Settings')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Text button with a 44 px tap target and an arrow, for "Ask Mira about yesterday →"-style links.
class LinkButton extends StatelessWidget {
  const LinkButton(this.label, {super.key, required this.onTap, this.size = 11});
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      minimumSize: const Size(kMinTap, kMinTap),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: C.orangeText,
      tapTargetSize: MaterialTapTargetSize.padded,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: Text(label, style: ts(size, w: FontWeight.w700, color: C.orangeText))),
        const SizedBox(width: 4),
        Icon(Icons.arrow_forward_rounded, size: 14, color: C.orangeText),
      ],
    ),
  );
}

// ------------------------------------------------------------ bottom nav --
/// Ask Mira is not a tab: it opens from [MiraButton], floating on every tab.
const navItems = [
  ('Home', 'home'),
  ('Energy', 'energy'),
  ('Bill', 'bill'),
  ('Alerts', 'alerts'),
];

/// Index of the Alerts tab (it carries the unread badge; snackbars jump to it).
final alertsTab = navItems.indexWhere((n) => n.$2 == 'alerts');

/// Space the last thing on a tab leaves below itself, so [MiraButton] (64 px + 16 px margin) never covers it.
const kFabClearance = 96.0;

/// Ask Mira: Mira herself, idling (see [MiraAvatar]), floating at the lower right of every tab on a
/// 64 px white disc. Opens the chat on top of the tabs.
class MiraButton extends StatelessWidget {
  const MiraButton({super.key});

  static const size = 64.0;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        sizeConstraints: BoxConstraints.tightFor(width: size, height: size),
      ),
    ),
    child: FloatingActionButton(
      heroTag: 'ask-mira',
      tooltip: 'Ask Mira',
      backgroundColor: C.card,
      elevation: 3,
      highlightElevation: 1,
      shape: CircleBorder(side: kCardLine),
      onPressed: () => context.push(Routes.ask),
      child: const MiraAvatar(size: 58),
    ),
  );
}

/// "99+" past 99.
String badgeText(int n) => n > 99 ? '99+' : '$n';

/// Figma bottom bar: SVG icons on/off, orange indicator over the active tab, unread badge on Alerts.
/// Grows with the system text size instead of clipping at a fixed 74 px.
///
/// The indicator (3.5 px orange bar over a peach block) is one piece that fills its tab exactly and
/// slides to the tapped tab (240 ms, the UI ease), so there is never a gap: it doesn't fade out on
/// one tab while fading in on another, and it lines up with the tab's tap ink. It jumps under
/// reduced motion.
class SolarisNavBar extends StatelessWidget {
  const SolarisNavBar({super.key, required this.index, required this.onTap, this.badge = 0});
  final int index;
  final ValueChanged<int> onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Material(
    color: C.card,
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: IntrinsicHeight(
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedAlign(
                  alignment: Alignment(-1 + 2 * index.clamp(0, navItems.length - 1) / (navItems.length - 1), 0),
                  duration: reduceMotion(context) ? Duration.zero : M.slide,
                  curve: M.ease,
                  child: FractionallySizedBox(
                    widthFactor: 1 / navItems.length,
                    heightFactor: 1,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: C.navActive,
                        border: Border(top: BorderSide(color: C.orange, width: 3.5)),
                      ),
                    ),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < navItems.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: i == index,
                        button: true,
                        label: i == alertsTab && badge > 0 ? '${navItems[i].$1}, ${badgeText(badge)} unread' : navItems[i].$1,
                        excludeSemantics: true,
                        child: InkWell(
                          onTap: () => onTap(i),
                          child: Center(
                            child: Column(
                              children: [
                                const SizedBox(height: 3.5 + 10), // 3.5: under the indicator's bar
                                Badge(
                                  isLabelVisible: i == alertsTab && badge > 0,
                                  label: Text(badgeText(badge)),
                                  backgroundColor: C.redFill,
                                  child: svg('nav-${navItems[i].$2}-${i == index ? 'on' : 'off'}', height: 18),
                                ),
                                const SizedBox(height: 6),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 2),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      navItems[i].$1,
                                      maxLines: 1,
                                      style: ts(
                                        12,
                                        w: FontWeight.w600,
                                        spacing: -0.36,
                                        color: i == index ? C.orangeText : C.navOffText,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
