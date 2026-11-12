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
import '../../providers/live_providers.dart';
import '../../providers/server_providers.dart';
import '../../services/api_service.dart';
import '../../services/live_connection.dart';

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
    final link = ref.watch(liveProvider.select((s) => s.link));
    final mock = ref.watch(serverConfigProvider.select((c) => c.useMock));
    final (color, label) = switch (link) {
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
          color: Colors.white.withValues(alpha: onDark ? 0.9 : 1),
          borderRadius: BorderRadius.circular(20),
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
    padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
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
            if (trailing != null) Flexible(child: trailing!),
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
  const BackHeader(this.title, this.sub, {super.key});
  final String title;
  final String sub;

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
                icon: const Icon(Icons.arrow_back_rounded, color: C.ink),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              const LinkIndicator(),
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

class SCard extends StatelessWidget {
  const SCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = C.card,
    this.border,
  });
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(15),
      border: border ?? Border.all(color: C.tileBorder, width: 0.5),
    ),
    child: child,
  );
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
    this.unitColor = C.orangeText,
    this.valueColor = C.ink,
    this.unitWeight = FontWeight.w600,
  });
  final String value;
  final String unit;
  final double size;
  final Color unitColor;
  final Color valueColor;
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
            style: ts(size, w: FontWeight.w900, color: valueColor),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      if (unit.isNotEmpty) ...[
        const SizedBox(width: 6),
        Text(unit, style: ts(12, w: unitWeight, color: unitColor)),
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
  const Freshness({super.key, required this.readingTs, required this.link});
  final int? readingTs; // telemetry.ts, Unix seconds
  final LinkStatus link;

  @override
  Widget build(BuildContext context) => Every(
    const Duration(seconds: 30),
    builder: (context) {
      final t = readingTs;
      final age = t == null ? null : DateTime.now().millisecondsSinceEpoch ~/ 1000 - t;
      final when = t == null ? '' : (age! < 60 ? 'just now' : formatAgo(t).toLowerCase());
      final (icon, color, text) = switch (link) {
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
      padding: const EdgeInsets.all(20),
      child: SCard(
        child: Column(
          children: [
            Icon(icon, color: C.orangeDeep, size: 32),
            const SizedBox(height: 8),
            Text(message ?? f.title, style: ts(13, w: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(f.hint, style: ts(11, color: C.muted), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton(onPressed: onRetry, child: const Text('Try again')),
                if (f.kind == ErrorKind.offline)
                  OutlinedButton(onPressed: () => context.push(Routes.settings), child: const Text('Settings')),
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
        const Icon(Icons.arrow_forward_rounded, size: 14, color: C.orangeText),
      ],
    ),
  );
}

// ------------------------------------------------------------ bottom nav --
const navItems = [
  ('Home', 'home'),
  ('Energy', 'energy'),
  ('Bill', 'bill'),
  ('Ask Mira', 'chat'),
  ('Alerts', 'alerts'),
];

/// "99+" past 99.
String badgeText(int n) => n > 99 ? '99+' : '$n';

/// Figma bottom bar: SVG icons on/off, orange indicator over the active tab, unread badge on Alerts.
/// Grows with the system text size instead of clipping at a fixed 74 px.
class SolarisNavBar extends StatelessWidget {
  const SolarisNavBar({super.key, required this.index, required this.onTap, this.badge = 0});
  final int index;
  final ValueChanged<int> onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < navItems.length; i++)
                Expanded(
                  child: Semantics(
                    selected: i == index,
                    button: true,
                    label: i == 4 && badge > 0 ? '${navItems[i].$1}, ${badgeText(badge)} unread' : navItems[i].$1,
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: () => onTap(i),
                      // Figma: active tab = 3.5 px orange bar over a 70 px peach block.
                      child: Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          constraints: const BoxConstraints(maxWidth: 74),
                          color: i == index ? C.navActive : Colors.transparent,
                          child: Column(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                height: 3.5,
                                color: i == index ? C.orange : Colors.transparent,
                              ),
                              const SizedBox(height: 10),
                              Badge(
                                isLabelVisible: i == 4 && badge > 0,
                                label: Text(badgeText(badge)),
                                backgroundColor: C.red,
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
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
