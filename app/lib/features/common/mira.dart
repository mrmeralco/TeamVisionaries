// Mira, the assistant: the Robo-Araw sprites (assets/images/mira-<mood>.svg) and how she moves.
//
// Each mood's sprite is cut at runtime into layers by its own SVG groups (the sun rays, eyes, mouth,
// thinking dots, sparkles, sound waves, sweat drop), so the parts can move on their own. The asset
// files are untouched. Under reduced motion, or with `animate: false`, she is the still sprite.
//
//   idle      rays sway, she floats, she blinks                      (loops)
//   thinking  rays turn, three dots pop up one by one, eyes wander     (loops while she works)
//   talking   mouth opens and closes, sound waves pulse                (a few beats, then rests)
//   happy     she hops, sparkles twinkle                               (a few beats)
//   error     sad: sweat drop runs down, she sighs, rays droop         (a few beats)
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_theme.dart';

/// Mira's moods, one sprite each (`assets/images/mira-<mood>.svg`). [error] is her sad face: failed
/// answers and bad news.
enum MiraMood { idle, talking, thinking, happy, error }

/// Mira at [size]. With [animate] (default) she moves in her [mood]: for [cycles] beats, then rests
/// still in [settleTo] (default: the same mood); with no [cycles] she keeps going while on screen.
/// A mood change cross-fades (150 ms). Decorative for screen readers: the text beside her always
/// says who is talking.
class MiraAvatar extends StatelessWidget {
  const MiraAvatar({
    super.key,
    this.mood = MiraMood.idle,
    this.size = 32,
    this.animate = true,
    this.cycles,
    this.settleTo,
  });
  final MiraMood mood;
  final double size;
  final bool animate;
  final int? cycles;
  final MiraMood? settleTo;

  @override
  Widget build(BuildContext context) {
    final still = reduceMotion(context);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: AnimatedSwitcher(
          duration: still ? Duration.zero : M.step,
          child: animate && !still
              ? _MiraLive(
                  key: ValueKey(('live', mood, cycles, settleTo)),
                  mood: mood,
                  size: size,
                  cycles: cycles,
                  settleTo: settleTo ?? mood,
                )
              : _still(mood, size),
        ),
      ),
    );
  }
}

Widget _still(MiraMood mood, double size) =>
    SvgPicture.asset('assets/images/mira-${mood.name}.svg', key: ValueKey(mood), width: size, height: size);

/// One movable piece of a sprite: a whole SVG (same 256 × 256 box) holding just that piece, and the
/// point it turns and scales about.
class MiraPart {
  const MiraPart(this.svg, this.origin);
  final String svg;
  final Alignment origin;
}

/// A mood's sprite cut into parts. Null parts are ones that mood doesn't have.
@visibleForTesting
class MiraRig {
  MiraRig._({
    required this.face,
    required this.rays,
    this.eyes,
    this.mouth,
    this.waves,
    this.drop,
    this.dots = const [],
    this.sparkles = const [],
  });
  final MiraPart face, rays;
  final MiraPart? eyes, mouth, waves, drop;
  final List<MiraPart> dots, sparkles;

  /// Pieces that move on their own, for tests.
  int get movingParts =>
      1 + [eyes, mouth, waves, drop].whereType<MiraPart>().length + dots.length + sparkles.length;

  static final _ready = <MiraMood, MiraRig?>{};
  static final _loading = <MiraMood, Future<MiraRig?>>{};

  static MiraRig? ready(MiraMood m) => _ready[m];

  static Future<MiraRig?> load(MiraMood m) => _loading[m] ??= rootBundle
      .loadString('assets/images/mira-${m.name}.svg')
      .then((s) => _ready[m] = cut(s), onError: (_) => null);

  // The sun's centre in the sprite box (rays turn about it): (128, 140) of 256.
  static const _sun = Alignment(0, 12 / 128);

  /// Cuts the sprite by its groups; null if it has no rays group (then she stays still).
  static MiraRig? cut(String svg) {
    var s = svg.replaceAll(RegExp(r'<metadata>[\s\S]*?</metadata>'), ''); // in-memory copy only
    final at = s.indexOf('<svg');
    if (at < 0) return null;
    final open = s.substring(at, s.indexOf('>', at) + 1);
    String wrap(String piece) => '$open$piece</svg>';
    String? take(RegExp re) {
      final m = re.firstMatch(s);
      if (m == null) return null;
      s = s.replaceFirst(m[0]!, '');
      return m[0];
    }

    RegExp group(String name) => RegExp('<g class="$name"[^>]*>[\\s\\S]*?</g>');
    final rays = take(group('rays'));
    if (rays == null) return null;
    final eyes = take(group('eyes'));
    final mouth = take(group('mouth'));
    final waves = take(group('waves'));
    final dots = take(group('dots'));
    final sparkles = take(group('sparkles'));
    final drop = take(RegExp(r'<path class="drop"[^>]*/>'));
    MiraPart? part(String? p) => p == null ? null : MiraPart(wrap(p), _origin(p));
    List<MiraPart> each(String? g) => g == null
        ? const []
        : [
            for (final m in RegExp(r'<(circle|ellipse|polygon|path)\b[^>]*/>').allMatches(g))
              MiraPart(wrap(m[0]!), _origin(m[0]!)),
          ];
    return MiraRig._(
      face: MiraPart(s, Alignment.center),
      rays: MiraPart(wrap(rays), _sun),
      eyes: part(eyes),
      mouth: part(mouth),
      waves: part(waves),
      drop: part(drop),
      dots: each(dots),
      sparkles: each(sparkles),
    );
  }

  /// Centre of a piece's bounding box, from its absolute coordinates (cx/cy, points, path d).
  static Alignment _origin(String el) {
    final xs = <double>[], ys = <double>[];
    final cx = RegExp(r'\bcx="([-\d.]+)"').allMatches(el).map((m) => double.parse(m[1]!)).toList();
    final cy = RegExp(r'\bcy="([-\d.]+)"').allMatches(el).map((m) => double.parse(m[1]!)).toList();
    for (var i = 0; i < math.min(cx.length, cy.length); i++) {
      xs.add(cx[i]);
      ys.add(cy[i]);
    }
    for (final attr in RegExp(r'\b(?:points|d)="([^"]*)"').allMatches(el)) {
      final n = RegExp(r'-?\d+(?:\.\d+)?').allMatches(attr[1]!).map((m) => double.parse(m[0]!)).toList();
      for (var i = 0; i + 1 < n.length; i += 2) {
        xs.add(n[i]);
        ys.add(n[i + 1]);
      }
    }
    if (xs.isEmpty) return Alignment.center;
    final x = (xs.reduce(math.min) + xs.reduce(math.max)) / 2;
    final y = (ys.reduce(math.min) + ys.reduce(math.max)) / 2;
    return Alignment(x / 128 - 1, y / 128 - 1);
  }
}

/// How long one beat of each mood lasts.
Duration _beat(MiraMood m) => Duration(
      milliseconds: switch (m) {
        MiraMood.idle => 3600,
        MiraMood.thinking => 1800,
        MiraMood.talking => 600,
        MiraMood.happy => 1200,
        MiraMood.error => 2400,
      },
    );

class _MiraLive extends StatefulWidget {
  const _MiraLive({
    super.key,
    required this.mood,
    required this.size,
    required this.cycles,
    required this.settleTo,
  });
  final MiraMood mood;
  final double size;
  final int? cycles;
  final MiraMood settleTo;

  @override
  State<_MiraLive> createState() => _MiraLiveState();
}

class _MiraLiveState extends State<_MiraLive> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  MiraRig? _rig;
  bool _done = false;
  final _pictures = <MiraPart, Widget>{};

  @override
  void initState() {
    super.initState();
    final beat = _beat(widget.mood);
    final n = widget.cycles;
    _c = AnimationController(vsync: this, duration: n == null ? beat : beat * n);
    if (n == null) {
      _c.repeat();
    } else {
      _c.forward().whenComplete(() {
        if (mounted) setState(() => _done = true);
      });
    }
    _rig = MiraRig.ready(widget.mood);
    if (_rig == null) {
      MiraRig.load(widget.mood).then((r) {
        if (mounted && r != null) setState(() => _rig = r);
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Each part's picture is built once and reused every frame (only its transform changes).
  Widget _pic(MiraPart p) =>
      _pictures[p] ??= SvgPicture.string(p.svg, width: widget.size, height: widget.size);

  Widget _layer(
    MiraPart? p, {
    double dx = 0,
    double dy = 0,
    double angle = 0,
    double sx = 1,
    double sy = 1,
    double opacity = 1,
  }) {
    if (p == null) return const SizedBox.shrink();
    final m = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..rotateZ(angle)
      ..scaleByDouble(sx, sy, 1, 1);
    final moved = Transform(alignment: p.origin, transform: m, child: _pic(p));
    return opacity >= 1 ? moved : Opacity(opacity: opacity.clamp(0, 1), child: moved);
  }

  @override
  Widget build(BuildContext context) {
    final rig = _rig;
    if (_done) return _still(widget.settleTo, widget.size);
    if (rig == null) return _still(widget.mood, widget.size);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final n = widget.cycles;
        final t = n == null ? _c.value : (_c.value * n) % 1; // where in the beat
        return Stack(children: _frame(rig, t, widget.size));
      },
    );
  }

  List<Widget> _frame(MiraRig r, double t, double s) {
    final wave = math.sin(2 * math.pi * t);
    switch (widget.mood) {
      case MiraMood.idle:
        // Sway, float, and one blink near the end of the beat.
        final blink = t > 0.86 && t < 0.92 ? 1 - 0.9 * math.sin((t - 0.86) / 0.06 * math.pi) : 1.0;
        final float = -0.025 * s * wave;
        return [
          _layer(r.rays, angle: 0.105 * wave),
          _layer(r.face, dy: float),
          _layer(r.eyes, dy: float, sy: blink),
          _layer(r.mouth, dy: float),
        ];
      case MiraMood.thinking:
        // The rays turn one ray-step (45°) a beat, so the turn never seems to restart; the dots pop up
        // one after another and fade together; the eyes wander up and to the side.
        double pop(int i) => Curves.easeOutBack.transform(((t - i * 0.18) / 0.16).clamp(0.0, 1.0));
        final fade = t > 0.8 ? 1 - (t - 0.8) / 0.2 : 1.0;
        return [
          _layer(r.rays, angle: math.pi / 4 * t),
          _layer(r.face),
          _layer(r.eyes, dx: 0.015 * s * wave, dy: -0.008 * s * (0.5 - 0.5 * math.cos(2 * math.pi * t))),
          _layer(r.mouth),
          for (var i = 0; i < r.dots.length; i++) _layer(r.dots[i], sx: pop(i), sy: pop(i), opacity: fade),
        ];
      case MiraMood.talking:
        // Mouth opens and closes once a beat; the sound waves pulse a half-beat behind.
        final open = 0.35 + 0.65 * (0.5 - 0.5 * math.cos(2 * math.pi * t));
        final pulse = 0.5 + 0.5 * math.sin(2 * math.pi * t - math.pi / 2);
        final bob = -0.012 * s * wave;
        return [
          _layer(r.rays, angle: 0.04 * wave),
          _layer(r.face, dy: bob),
          _layer(r.eyes, dy: bob),
          _layer(r.mouth, dy: bob, sy: open),
          _layer(r.waves, dy: bob, dx: 0.015 * s * pulse, opacity: 0.35 + 0.65 * pulse),
        ];
      case MiraMood.happy:
        // A hop each beat; the sparkles twinkle in turn.
        final hop = -0.07 * s * math.sin(math.pi * t);
        return [
          _layer(r.rays, angle: 0.12 * math.sin(math.pi * t)),
          _layer(r.face, dy: hop),
          _layer(r.eyes, dy: hop),
          _layer(r.mouth, dy: hop),
          for (var i = 0; i < r.sparkles.length; i++)
            _layer(
              r.sparkles[i],
              dy: hop,
              sx: 0.7 + 0.45 * (0.5 + 0.5 * math.sin(2 * math.pi * (t + i / 3))),
              sy: 0.7 + 0.45 * (0.5 + 0.5 * math.sin(2 * math.pi * (t + i / 3))),
              angle: 0.4 * math.sin(2 * math.pi * (t + i / 3)),
            ),
        ];
      case MiraMood.error:
        // Sad: a slow sigh (she sinks and comes back), the rays droop, the sweat drop runs down and
        // fades, then forms again.
        final sigh = 0.03 * s * (0.5 - 0.5 * math.cos(2 * math.pi * t));
        final run = Curves.easeIn.transform(t);
        return [
          _layer(r.rays, angle: -0.05 * (0.5 - 0.5 * math.cos(2 * math.pi * t)), sx: 0.97, sy: 0.97),
          _layer(r.face, dy: sigh),
          _layer(r.eyes, dy: sigh),
          _layer(r.mouth, dy: sigh),
          _layer(r.drop, dy: sigh + 0.12 * s * run, opacity: t < 0.65 ? 1 : 1 - (t - 0.65) / 0.35),
        ];
    }
  }
}
