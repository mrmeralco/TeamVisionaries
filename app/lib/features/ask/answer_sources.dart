// Ask Mira: "Where this answer comes from" under each reply. One card per fact the answer used
// (POST /api/chat `sources`): what it is, its value, the exact data sentence, where the backend got it
// (live reading / your history / forecast / settings / tip) and when. Tapping a card opens the screen
// with that data. Built by the backend from the same facts the reply was checked against.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../common/ui.dart';

class _Kind {
  const _Kind(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

Map<String, _Kind> get _kinds => {
  'live': _Kind('Live reading', Icons.sensors_rounded, C.green),
  'history': _Kind('Your history', Icons.history_rounded, C.seriesGrid),
  'forecast': _Kind('Forecast', Icons.trending_up_rounded, C.orangeText),
  'settings': _Kind('Your settings', Icons.tune_rounded, C.muted),
  'advice': _Kind('Solaris tip', Icons.lightbulb_outline_rounded, C.amber),
};

/// screen id from the API -> (route, opens on top of the tabs?, name for screen readers)
const _screens = {
  'home': (Routes.home, false, 'Home'),
  'energy': (Routes.energy, false, 'Energy'),
  'bill': (Routes.bill, false, 'Bill'),
  'alerts': (Routes.alerts, false, 'Alerts'),
  'brownout': (Routes.brownout, true, 'Brownout Advisor'),
  'settings': (Routes.settings, true, 'Settings'),
};

class AnswerSources extends StatefulWidget {
  const AnswerSources(this.sources, {super.key, this.now});
  final List<Map<String, dynamic>> sources;

  /// For tests: the clock used for "3 min ago".
  final DateTime? now;

  @override
  State<AnswerSources> createState() => _AnswerSourcesState();
}

class _AnswerSourcesState extends State<AnswerSources> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final n = widget.sources.length;
    return Padding(
      padding: const EdgeInsets.only(top: S.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            label: 'Where this answer comes from, $n ${n == 1 ? 'source' : 'sources'}',
            excludeSemantics: true,
            child: InkWell(
              borderRadius: R.control,
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kMinTap),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.fact_check_outlined, size: 16, color: C.orangeText),
                    const SizedBox(width: S.x2),
                    Flexible(
                      child: Text(
                        'Where this answer comes from · $n',
                        style: ts(11, w: FontWeight.w700, color: C.orangeText),
                      ),
                    ),
                    Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: C.orangeText),
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            for (final s in widget.sources) _SourceCard(s, now: widget.now),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard(this.s, {this.now});
  final Map<String, dynamic> s;
  final DateTime? now;

  String get _meta {
    final kind = _kinds[s['kind']]?.label ?? 'Your data';
    final parts = [kind, str(s['period'])].where((p) => p.isNotEmpty).toList();
    final ts = intOrNull(s['as_of_ts']);
    if (s['kind'] == 'live' && ts != null) {
      // A live reading says when it was measured. An old one says how old instead of "Right now",
      // so a stale answer is obvious.
      final age = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 - ts;
      if (age > 120) return [kind, 'Last reading ${formatAgo(ts, now: now).toLowerCase()}'].join('  ·  ');
      parts.add(formatClock(ts));
    }
    return parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final kind = _kinds[s['kind']] ?? _kinds['history']!;
    final value = str(s['value']);
    final target = _screens[s['screen']];
    final router = GoRouter.maybeOf(context);
    final open = target == null || router == null
        ? null
        : () => target.$2 ? router.push(target.$1) : router.go(target.$1);

    return Padding(
      padding: const EdgeInsets.only(top: S.x2),
      child: Semantics(
        button: open != null,
        label:
            '${str(s['label'])}${value.isEmpty ? '' : ', $value'}. ${str(s['detail'])} $_meta'
            '${target == null ? '' : '. Opens ${target.$3}'}',
        excludeSemantics: true,
        // The app's tappable-card recipe: sinks slightly while pressed.
        child: PressCard(
          onTap: open,
          side: BorderSide(color: C.tileBorder, width: 0.6),
          padding: const EdgeInsets.fromLTRB(S.x3, S.x3, S.x2, S.x3),
          minHeight: kMinTap,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(color: kind.color.withValues(alpha: 0.12), borderRadius: R.control),
                child: Icon(kind.icon, size: 15, color: kind.color),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            str(s['label']),
                            style: ts(12, w: FontWeight.w700, color: C.ink),
                          ),
                        ),
                        if (value.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            value,
                            style: ts(12, w: FontWeight.w800, color: C.orangeText),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(str(s['detail']), style: ts(11.5, height: 1.35, color: C.label)),
                    const SizedBox(height: 4),
                    Text(
                      _meta,
                      style: ts(10, w: FontWeight.w600, color: C.muted),
                    ), // colour lives in the icon (small text needs contrast)
                  ],
                ),
              ),
              if (open != null) ...[
                const SizedBox(width: S.x1),
                Padding(
                  padding: EdgeInsets.only(top: S.x1),
                  child: Icon(Icons.chevron_right_rounded, size: 18, color: C.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
