// Shared pieces of the Figma design: page header (title, subtitle, live-link dot, settings gear), cards,
// readings, a two-column grid, AsyncValue loading/error states and the bottom navigation bar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/live_providers.dart';
import '../../providers/server_providers.dart';
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
    child: InkResponse(
      onTap: () => context.push(Routes.settings),
      radius: 22,
      child: svg('gear', width: 27, height: 27),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: onDark ? 0.9 : 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: ts(9, w: FontWeight.w700, color: C.ink),
          ),
        ],
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
      const SizedBox(width: 10),
      const GearButton(),
    ],
  );
}

/// Title + subtitle, as on the Energy / Bill / Ask Sinag / Alerts frames.
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, this.sub, {super.key, this.trailing});
  final String title;
  final String sub;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TopBar(),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(title, style: ts(26, w: FontWeight.w700, spacing: -0.52)),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 4),
        Text(
          sub,
          style: ts(12, w: FontWeight.w300, color: C.muted),
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

/// Big number + small unit, baseline-aligned ("3.5 kW").
class Reading extends StatelessWidget {
  const Reading(
    this.value,
    this.unit, {
    super.key,
    this.size = 24,
    this.unitColor = C.unit,
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
        child: Text(
          value,
          style: ts(size, w: FontWeight.w900, color: valueColor),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(width: 6),
      Text(
        unit,
        style: ts(12, w: unitWeight, color: unitColor),
      ),
    ],
  );
}

/// Loading spinner / friendly error with retry / data, for one provider's AsyncValue.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.data, required this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncValue(:final value?, hasValue: true) => data(value), // keeps old data visible while refreshing
    AsyncError() => ErrorBox(onRetry: onRetry),
    _ => const Padding(
      padding: EdgeInsets.all(40),
      child: Center(child: CircularProgressIndicator()),
    ),
  };
}

class ErrorBox extends StatelessWidget {
  const ErrorBox({super.key, required this.onRetry, this.message});
  final VoidCallback onRetry;
  final String? message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: SCard(
      child: Column(
        children: [
          const Icon(Icons.wifi_off_rounded, color: C.orange, size: 32),
          const SizedBox(height: 8),
          Text(
            message ?? 'Hindi maabot ang Sinag server.',
            style: ts(13, w: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            'Check the server IP in Settings, then try again.',
            style: ts(11, color: C.muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(onPressed: onRetry, child: const Text('Subukan ulit')),
              OutlinedButton(onPressed: () => context.push(Routes.settings), child: const Text('Settings')),
            ],
          ),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------ bottom nav --
const navItems = [
  ('Home', 'home'),
  ('Energy', 'energy'),
  ('Bill', 'bill'),
  ('Ask Sinag', 'chat'),
  ('Alerts', 'alerts'),
];

/// Figma bottom bar: SVG icons on/off, orange indicator over the active tab, unread badge on Alerts.
class SinagNavBar extends StatelessWidget {
  const SinagNavBar({super.key, required this.index, required this.onTap, this.badge = 0});
  final int index;
  final ValueChanged<int> onTap;
  final int badge;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      top: false,
      child: SizedBox(
        height: 74,
        child: Row(
          children: [
            for (var i = 0; i < navItems.length; i++)
              Expanded(
                child: Semantics(
                  selected: i == index,
                  button: true,
                  child: InkWell(
                    onTap: () => onTap(i),
                    // Figma: active tab = 3.5 px orange bar over a 70 px peach block.
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 70,
                        color: i == index ? C.navActive : Colors.transparent,
                        child: Column(
                          children: [
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              height: 3.5,
                              width: 74,
                              color: i == index ? C.orange : Colors.transparent,
                            ),
                            const Spacer(),
                            Badge(
                              isLabelVisible: i == 4 && badge > 0,
                              label: Text('$badge'),
                              backgroundColor: C.red,
                              child: svg('nav-${navItems[i].$2}-${i == index ? 'on' : 'off'}', height: 18),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              navItems[i].$1,
                              maxLines: 1,
                              overflow: TextOverflow.visible,
                              softWrap: false,
                              style: ts(
                                12,
                                w: FontWeight.w600,
                                spacing: -0.36,
                                color: i == index ? C.orange : C.navOff,
                              ),
                            ),
                            const Spacer(),
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
  );
}
