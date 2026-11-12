// Home hero, Tesla-style: the house drawn large across the full width (assets/images/house-hero.svg,
// viewBox 393 × 360), on a sky that fades into the page. Each part carries a live label on a thin
// vertical line: SOLAR and HOME in the sky above the roof, BATTERY and GRID on the lawn below.
//
// The parts and their labels are tappable: the house zooms in on that part in place and explains the
// number in a sentence. Tap the same part, open ground or the close button to zoom back out; tap
// another part to fly to it.
//
// Responsive: the drawing is laid out in its own units and scaled to the screen width (320 px phones
// up to the 480 px app width); labels keep a fixed, readable size and are kept inside the drawing.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart' show SvgPicture;

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';

const kSceneW = 393.0;
const kSceneH = 360.0;
const _sceneAsset = 'assets/images/house-hero.svg';

/// house-hero.svg draws house-scene.svg (353 × 215) at 1.5×, flush right: this maps a point of that
/// drawing to the hero's units, so the parts can be measured on the original.
Offset _h(double x, double y) => Offset(x * 1.5 - 136.5, y * 1.5 - 42);

enum Spot { solar, home, battery, grid }

class _SpotGeo {
  const _SpotGeo({required this.hit, required this.anchor, required this.zoom, required this.above});

  /// Tap area on the drawing, a bit larger than the part so a finger finds it.
  final List<Offset> hit;

  /// The dot on the part; its leader line ends here and the zoom centres on it.
  final Offset anchor;

  /// How far the house zooms in on it.
  final double zoom;

  /// Label in the sky above the roof (true) or on the lawn below the house (false).
  final bool above;
}

List<Offset> _rect(double l, double t, double r, double b) => [_h(l, t), _h(r, t), _h(r, b), _h(l, b)];

/// Checked in this order: the small parts sit on top of the house.
const _order = [Spot.grid, Spot.battery, Spot.solar, Spot.home];

final _geo = <Spot, _SpotGeo>{
  // Meter on the right wall, and the window it hangs on.
  Spot.grid: _SpotGeo(hit: _rect(329, 156, 353, 194), anchor: _h(341.5, 174.7), zoom: 2.8, above: false),
  // Battery by the corner of the house, dot on its status light.
  Spot.battery: _SpotGeo(hit: _rect(221, 168, 247, 215), anchor: _h(232.5, 188.6), zoom: 2.4, above: false),
  // The whole roof slope with the panels; dot on the middle of the array.
  Spot.solar: _SpotGeo(
    hit: [_h(197, 80), _h(353, 117), _h(353, 152), _h(236, 138)],
    anchor: _h(285.7, 115),
    zoom: 2.0,
    above: true,
  ),
  // Walls, windows and door; dot on the gable window.
  Spot.home: _SpotGeo(
    hit: [_h(163, 214), _h(163, 172), _h(196, 80), _h(239, 135), _h(353, 145), _h(353, 214)],
    anchor: _h(204, 128),
    zoom: 1.7,
    above: true,
  ),
};

/// Top labels sit on this line (their bottom edge); bottom labels stand on the lawn this far up from
/// the drawing's bottom edge. Hero units.
const _skyLine = 74.0;
const _lawnPad = 8.0;

final _hitPaths = {for (final e in _geo.entries) e.key: Path()..addPolygon(e.value.hit, true)};

/// Which part of the drawing is at [p] (hero units), if any.
Spot? spotAt(Offset p) {
  for (final s in _order) {
    if (_hitPaths[s]!.contains(p)) return s;
  }
  return null;
}

/// Where a part's dot is, in hero units (for tests and the zoom).
Offset spotAnchor(Spot s) => _geo[s]!.anchor;

/// What one label says, built from the live telemetry (Contract B fields).
class SpotInfo {
  const SpotInfo({
    required this.title,
    required this.value,
    required this.detail,
    required this.color,
    this.state,
    this.note,
  });
  final String title, value, detail;

  /// One word under the resting label, the way the old tiles said it: Charging, Exporting, Brownout.
  final String? state;

  /// The zoomed label's longer version: Producing, Charging 1.2 kW…
  final String? note;
  final Color color;
}

String _kw(num w) => '${(w.abs() / 1000).toStringAsFixed(1)} kW';

SpotInfo spotInfo(Spot s, Map<String, dynamic> t, {bool offline = false}) {
  const color = C.orangeText; // small text on white: 6.0:1
  final title = switch (s) {
    Spot.solar => 'Solar',
    Spot.home => 'Home',
    Spot.battery => 'Battery',
    Spot.grid => 'Grid',
  };
  if (offline || t.isEmpty) {
    return SpotInfo(
      title: title,
      value: '—',
      detail: 'Wala pang reading mula sa Solaris device. Lalabas dito kapag naka-online na.',
      color: color,
    );
  }
  switch (s) {
    case Spot.solar:
      final pv = numOr(t['pv_w']);
      return SpotInfo(
        title: title,
        value: _kw(pv),
        note: pv > 20 ? 'Producing' : 'Idle',
        detail: pv > 20
            ? 'Kuryenteng gawa ng solar panels mo ngayon. Libre ito.'
            : 'Walang araw ngayon, kaya hindi gumagawa ng kuryente ang panels.',
        color: color,
      );
    case Spot.home:
      return SpotInfo(
        title: title,
        value: _kw(numOr(t['load_w'])),
        note: 'In use',
        detail: 'Lahat ng kuryenteng ginagamit ng bahay ngayon: ilaw, ref, electric fan, at iba pa.',
        color: color,
      );
    case Spot.battery:
      final soc = numOr(t['batt_soc']).round();
      final bw = numOr(t['batt_w']); // + discharging, − charging
      final (state, note, detail) = bw < -20
          ? ('Charging', 'Charging ${_kw(bw)}', 'Nag-iipon ng sobrang solar para magamit mamayang gabi o sa brownout.')
          : bw > 20
              ? ('In use', 'In use ${_kw(bw)}', 'Ang battery ang nagpapatakbo sa bahay ngayon.')
              : (null, 'Standby', 'Hindi nagcha-charge o ginagamit ang battery ngayon.');
      return SpotInfo(title: title, value: '$soc%', state: state, note: note, detail: detail, color: color);
    case Spot.grid:
      if (t['grid_on'] == false) {
        return SpotInfo(
          title: title,
          value: 'Off',
          state: 'Brownout',
          note: 'Brownout',
          detail: 'Walang kuryente mula sa Meralco ngayon. Solar at battery muna ang gamit ng bahay.',
          color: C.red,
        );
      }
      final gw = numOr(t['grid_w']); // + import, − export
      final (state, note, detail) = gw > 20
          ? ('Importing', 'Importing', 'Kumukuha ng kuryente sa Meralco. Ito ang may bayad sa bill mo.')
          : gw < -20
              ? ('Exporting', 'Exporting', 'Sobra ang solar mo, kaya napupunta sa grid ang sobra.')
              : (null, 'Not in use', 'Hindi ka kumukuha ng kuryente sa Meralco ngayon.');
      return SpotInfo(title: title, value: _kw(gw), state: state, note: note, detail: detail, color: color);
  }
}

/// The house with its four live labels, filling the width it's given. Transparent around the
/// drawing: the hero's sky gradient shows through, and the lawn fades into the page below.
class HouseScene extends StatefulWidget {
  const HouseScene({super.key, required this.telemetry, this.offline = false});

  final Map<String, dynamic> telemetry;
  final bool offline;

  @override
  State<HouseScene> createState() => _HouseSceneState();
}

class _HouseSceneState extends State<HouseScene> with SingleTickerProviderStateMixin {
  /// The zoomed part's dot lands here (fractions of the drawing), leaving room for the label above.
  static const _target = Offset(0.5, 0.68);
  static const _leader = 24.0;

  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420), value: 1);
  Spot? _spot; // where the house is zoomed (or zooming) to
  Spot? _was; // where it came from
  Matrix4? _fromM; // the view when the current move began
  Size _size = Size.zero; // the drawing on screen
  double _u = 1; // screen pixels per hero unit

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Matrix4 _view(Spot? s) {
    if (s == null) return Matrix4.identity();
    final g = _geo[s]!;
    final a = g.anchor * _u;
    final z = g.zoom;
    final tx = (_size.width * _target.dx - z * a.dx).clamp(_size.width * (1 - z), 0.0).toDouble();
    final ty = (_size.height * _target.dy - z * a.dy).clamp(_size.height * (1 - z), 0.0).toDouble();
    return Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(z, z, 1, 1);
  }

  double get _t => M.ease.transform(_c.value);

  Matrix4 _current() {
    final to = _view(_spot);
    final from = _fromM;
    if (from == null || _c.isCompleted) return to;
    return Matrix4Tween(begin: from, end: to).transform(_t);
  }

  void _go(Spot? s) {
    if (s == _spot) return;
    setState(() {
      _fromM = _current();
      _was = _spot;
      _spot = s;
    });
    if (reduceMotion(context)) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  void _onTap(Offset local, Matrix4 m) {
    final inv = Matrix4.tryInvert(m);
    if (inv == null) return;
    final s = spotAt(MatrixUtils.transformPoint(inv, local) / _u);
    // Same part or open ground: back to the whole house. Another part: fly there.
    _go(s == null || s == _spot ? null : s);
  }

  /// 1 at rest, 0 while zoomed in, cross-fading during the move.
  double get _rest {
    if (_spot != null) return _was == null ? 1 - _t : 0;
    return _was == null ? 1 : _t;
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: kSceneW / kSceneH,
      child: LayoutBuilder(
        builder: (context, box) {
          _size = Size(box.maxWidth, box.maxHeight);
          _u = box.maxWidth / kSceneW;
          return AnimatedBuilder(animation: _c, builder: (context, _) => _drawing(context));
        },
      ),
    );
  }

  Widget _drawing(BuildContext context) {
    final u = _u;
    final m = _current();
    final zoomed = _spot != null;
    final rest = _rest;
    // The zoom label fades in once the move has mostly landed, and out quickly on the way back.
    final zoomLabel = zoomed
        ? (_was == null ? const Interval(0.55, 1).transform(_c.value) : 1.0)
        : (1 - _c.value * 3).clamp(0.0, 1.0);
    final shown = _spot ?? _was;
    final dots = {for (final s in Spot.values) s: MatrixUtils.transformPoint(m, _geo[s]!.anchor * u)};
    final infos = {for (final s in Spot.values) s: spotInfo(s, widget.telemetry, offline: widget.offline)};

    return ClipRect(
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2, // labels sit on fixed points of the picture
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onTap(d.localPosition, m),
                child: Transform(
                  transform: m,
                  child: ExcludeSemantics(child: SvgPicture.asset(_sceneAsset, fit: BoxFit.fill)),
                ),
              ),
            ),
            // The resting labels and their leader lines.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: zoomed,
                child: Opacity(
                  opacity: rest,
                  child: CustomMultiChildLayout(
                    delegate: _TagsLayout(
                      dots: {for (final s in Spot.values) s: _geo[s]!.anchor * u},
                      skyLine: _skyLine * u,
                      lawnPad: _lawnPad * u,
                    ),
                    children: [
                      for (final s in Spot.values) ...[
                        LayoutId(
                          id: (s, _TagsLayout.line),
                          // The line starts on the part's dot: taps there belong to the part.
                          child: IgnorePointer(child: ColoredBox(color: C.ink.withValues(alpha: 0.45))),
                        ),
                        LayoutId(
                          id: (s, _TagsLayout.tag),
                          child: _Tag(info: infos[s]!, onTap: () => _go(s), hidden: zoomed),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _DotsPainter(dots: dots, selected: zoomed || zoomLabel > 0 ? shown : null, rest: rest)),
              ),
            ),
            if (shown != null && zoomLabel > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: zoomLabel,
                    child: CustomMultiChildLayout(
                      delegate: _ZoomLayout(dots[shown]!, _leader),
                      children: [
                        LayoutId(id: _ZoomLayout.label, child: _Label(infos[shown]!)),
                        LayoutId(id: _ZoomLayout.line, child: ColoredBox(color: C.ink.withValues(alpha: 0.75))),
                      ],
                    ),
                  ),
                ),
              ),
            if (zoomed)
              Positioned(
                top: S.x1,
                left: S.x3,
                child: Opacity(
                  opacity: zoomLabel,
                  child: IconButton(
                    tooltip: 'Zoom out',
                    onPressed: () => _go(null),
                    style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.94), foregroundColor: C.ink),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lays out the resting labels the Tesla way: each label centred over its part's dot on a vertical
/// line, SOLAR and HOME standing on the sky line above the roof, BATTERY and GRID on the lawn. A label
/// near an edge slides inward but its line stays on the dot.
class _TagsLayout extends MultiChildLayoutDelegate {
  _TagsLayout({required this.dots, required this.skyLine, required this.lawnPad});
  static const tag = 'tag', line = 'line';
  static const _edge = S.x2;
  final Map<Spot, Offset> dots;
  final double skyLine, lawnPad;

  @override
  void performLayout(Size size) {
    for (final s in Spot.values) {
      final d = dots[s]!;
      final l = layoutChild((s, tag), BoxConstraints(maxWidth: size.width / 2));
      final above = _geo[s]!.above;
      final y = above ? math.max(0.0, skyLine - l.height) : size.height - lawnPad - l.height;
      final x = (d.dx - l.width / 2).clamp(_edge, math.max(_edge, size.width - _edge - l.width)).toDouble();
      positionChild((s, tag), Offset(x, y));
      // The line runs from the label's near edge to the dot.
      final from = above ? y + l.height : d.dy;
      final to = above ? d.dy : y;
      layoutChild((s, line), BoxConstraints.tight(Size(1, math.max(0.0, to - from))));
      positionChild((s, line), Offset(d.dx - 0.5, from));
    }
  }

  @override
  bool shouldRelayout(_TagsLayout old) =>
      old.skyLine != skyLine || old.lawnPad != lawnPad || Spot.values.any((s) => old.dots[s] != dots[s]);
}

/// Lays out the zoomed part's label: centred above its dot on a short leader line, or below it
/// when there's no room above, always inside the drawing and clear of the close button (top-left).
class _ZoomLayout extends MultiChildLayoutDelegate {
  _ZoomLayout(this.anchor, this.leader);
  static const label = 'label', line = 'line';
  static const _edge = S.x3;
  static const _button = 56.0; // the close button's corner
  final Offset anchor;
  final double leader;

  @override
  void performLayout(Size size) {
    final maxW = math.max(0.0, math.min(240.0, size.width - _button - _edge * 2));
    final l = layoutChild(label, BoxConstraints(maxWidth: maxW));
    final aboveY = anchor.dy - leader - l.height;
    final above = aboveY >= _edge;
    final y = above ? aboveY : math.max(_edge, math.min(anchor.dy + leader, size.height - _edge - l.height));
    final lo = y < _button ? _button + S.x1 : _edge;
    final hi = math.max(lo, size.width - _edge - l.width);
    final x = (anchor.dx - l.width / 2).clamp(lo, hi).toDouble();
    positionChild(label, Offset(x, y));

    final top = above ? y + l.height : anchor.dy;
    final len = above ? anchor.dy - top : y - anchor.dy;
    layoutChild(line, BoxConstraints.tight(Size(1.2, math.max(0.0, len))));
    positionChild(line, Offset(anchor.dx - 0.6, top));
  }

  @override
  bool shouldRelayout(_ZoomLayout old) => old.anchor != anchor || old.leader != leader;
}

/// A resting label, Tesla-style: plain text on the picture, the part's name small and spaced, its
/// live number large, and for the battery and grid which way the power is going. Tap to zoom in.
class _Tag extends StatelessWidget {
  const _Tag({required this.info, required this.onTap, this.hidden = false});
  final SpotInfo info;
  final VoidCallback onTap;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      hidden: hidden,
      label: '${info.title}: ${info.value}${info.state == null ? '' : ', ${info.state}'}',
      hint: 'Zoom in',
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: S.x2, vertical: S.x1),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(info.title.toUpperCase(), style: ts(10.5, w: FontWeight.w700, color: C.labelOnYellow, spacing: 1.2)),
              Text(info.value, style: ts(18, w: FontWeight.w700, height: 1.25)),
              if (info.state != null)
                Text(info.state!, style: ts(11, w: FontWeight.w700, color: info.color == C.red ? C.red : C.orangeText)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The zoomed part's label: name, number, what it's doing, and one sentence on what it means.
class _Label extends StatelessWidget {
  const _Label(this.info);
  final SpotInfo info;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(S.x3, S.x2, S.x3, S.x2 + 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: R.tile,
        boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 10, offset: Offset(0, 3))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(info.title.toUpperCase(), style: ts(10, w: FontWeight.w700, color: C.label, spacing: 0.8)),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: S.x2,
            children: [
              Text(info.value, style: ts(20, w: FontWeight.w800)),
              if (info.note != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(info.note!, style: ts(11, w: FontWeight.w700, color: info.color)),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(info.detail, style: ts(11, height: 1.35, color: C.label)),
        ],
      ),
    );
  }
}

/// A dot on each part (white ring, orange centre): where each label's line lands.
class _DotsPainter extends CustomPainter {
  _DotsPainter({required this.dots, required this.selected, required this.rest});
  final Map<Spot, Offset> dots;
  final Spot? selected;
  final double rest;

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in Spot.values) {
      final on = s == selected;
      final o = on ? 1.0 : rest;
      if (o <= 0) continue;
      final p = dots[s]!;
      final r = on ? 5.5 : 4.0;
      canvas.drawCircle(p, r + 2.5, Paint()..color = Colors.white.withValues(alpha: 0.35 * o));
      canvas.drawCircle(p, r, Paint()..color = Colors.white.withValues(alpha: o));
      canvas.drawCircle(p, r - 1.6, Paint()..color = C.orange.withValues(alpha: o));
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) =>
      old.selected != selected || old.rest != rest || Spot.values.any((s) => old.dots[s] != dots[s]);
}
