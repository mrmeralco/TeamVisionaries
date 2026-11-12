// First run, with Mira: she bounces in and talks the household through Solaris in a speech bubble.
//   0  Hello            who Mira is
//   1  How it works     the device reads the home, Mira turns numbers into advice, alerts
//   2  How to use it    the four tabs and what is on each, the house's dots, the Mira button
//   3  More help        Brownout Advisor (+ 48-hour outlook), system check, notifications, Settings
//   4  Your name        what Mira calls you (user_name)
//   5  Your home        solar (with or without a smart meter too) or a smart meter only (setup)
// Steps 0–3 can be skipped. The name and setup are saved together (PUT /api/settings) at the end; the
// setup decides what every tab shows: a meter-only home never sees solar, battery or brownout-runtime
// numbers, only its use, its bill and ways to save. Both can be changed later in Settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/data_providers.dart';
import '../../providers/onboarding_providers.dart';
import '../common/ui.dart';

enum _Home { solar, meter }

const _steps = 6;
const _nameStep = 4;
const _setupStep = 5;

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController();
  int _step = 0;
  _Home? _home;
  bool _alsoMeter = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _setup => _home == _Home.meter ? 'meter_only' : (_alsoMeter ? 'solar_and_meter' : 'solar');
  String get _who => _name.text.trim();

  void _go(int step) => setState(() {
        _step = step;
        _error = null;
      });

  Future<void> _finish() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(serverSettingsProvider.notifier).save({'setup': _setup, 'user_name': _who});
      await ref.read(onboardedProvider.notifier).complete();
      if (mounted) context.go(Routes.home);
    } catch (e) {
      final f = friendlyError(e);
      if (mounted) setState(() => _error = '${f.title} ${f.hint}');
    }
    if (mounted) setState(() => _saving = false);
  }

  /// What Mira says on each step.
  String get _says => switch (_step) {
        0 => 'Hi! Ako si Mira, ang energy assistant mo. Ako ang bahala sa pagbabantay ng kuryente ng bahay mo, '
            'para ikaw ay makatipid at handa sa brownout.',
        1 => 'Ganito tayo magtutulungan:',
        2 => 'Madali lang gamitin ang Solaris. Ito ang makikita mo sa ibaba:',
        3 => 'May iba pa akong maitutulong:',
        4 => 'Bago tayo magsimula, ano ang pangalan mo? Para alam ko kung paano kita babatiin.',
        _ => _error != null
            ? 'Naku, hindi ko na-save. Tingnan natin ang koneksyon sa server.'
            : 'Salamat, $_who! Huling tanong: ano ang meron sa bahay mo?',
      };

  MiraMood get _mood => switch (_step) {
        0 => MiraMood.happy,
        _ when _error != null => MiraMood.error,
        _ => MiraMood.talking,
      };

  (String, VoidCallback?) get _primary => switch (_step) {
        0 => ('Kumusta, Mira!', () => _go(1)),
        1 || 2 || 3 => ('Sige, tuloy', () => _go(_step + 1)),
        4 => ('Tuloy', _who.isEmpty ? null : () => _go(_setupStep)),
        _ => (_saving ? 'Sine-save…' : 'Simulan na', _home == null || _saving ? null : _finish),
      };

  @override
  Widget build(BuildContext context) {
    final (label, onPressed) = _primary;
    return Scaffold(
      backgroundColor: C.cream,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              step: _step,
              onBack: _step == 0 ? null : () => _go(_step - 1),
              onSkip: _step < _nameStep ? () => _go(_nameStep) : null,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.gutter, S.x2, S.gutter, S.x4),
                children: [
                  Center(
                    child: _Entrance(
                      // A new step: she starts talking again, then rests.
                      child: MiraAvatar(
                        key: ValueKey((_step, _mood)),
                        mood: _mood,
                        size: 112,
                        cycles: 3,
                        settleTo: _mood == MiraMood.error ? MiraMood.error : MiraMood.idle,
                      ),
                    ),
                  ),
                  const SizedBox(height: S.x3),
                  _Swap(id: ('bubble', _step, _error != null), child: _Bubble(_says)),
                  const SizedBox(height: S.x4),
                  _Swap(id: ('body', _step), child: _body()),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(S.gutter, 0, S.gutter, S.x4),
              child: FilledButton(
                key: Key(_step == _setupStep ? 'onboard-continue' : 'onboard-next'),
                onPressed: onPressed,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: Text(label),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() => switch (_step) {
        0 => const SizedBox.shrink(),
        1 => const _Points([
            (
              Icons.sensors_rounded,
              'Binabasa ng Solaris device ang bahay mo',
              'Mula sa inverter ng solar o sa smart meter, kada ilang segundo, buong araw.',
            ),
            (
              Icons.lightbulb_outline_rounded,
              'Ginagawa kong simpleng payo ang mga numero',
              'Kailan gagamitin ang mga appliance, magkano ang aabutin ng bill, at paano makatipid.',
            ),
            (
              Icons.notifications_active_outlined,
              'Sinasabihan kita agad',
              'May brownout, mababang boltahe o may sira? Makakatanggap ka agad ng alert.',
            ),
          ]),
        2 => const _Points([
            (
              Icons.home_rounded,
              'Home',
              'Ang bahay mo ngayon: pindutin ang mga tuldok sa bahay para sa detalye. Nandito rin ang buod ko '
                  'ng kahapon, mga tip para makatipid, at ang routine ng bahay mo.',
            ),
            (
              Icons.bar_chart_rounded,
              'Energy',
              'Gamit mo kada araw, linggo at buwan, at ikumpara sa mga nakaraan.',
            ),
            (
              Icons.receipt_long_rounded,
              'Bill',
              'Tantiya ng bill ngayong buwan at sa mga susunod na buwan, gastos kada linggo, at paano ito '
                  'mapapababa. May smart meter? Makikita mo rin ang Meralco level mo.',
            ),
            (
              Icons.notifications_rounded,
              'Alerts',
              'Brownout, mababang boltahe o sira. Pindutin ang alert para sa paliwanag at kung ano ang gagawin.',
            ),
            (
              Icons.chat_bubble_outline_rounded,
              'Ako, si Mira',
              'Pindutin ako sa kanang ibaba para magtanong, sa Tagalog o English, anumang oras. Ipinapakita ko '
                  'kung saan galing ang sagot ko.',
            ),
          ]),
        3 => const _Points([
            (
              Icons.power_off_rounded,
              'Brownout Advisor',
              'Kapag nawalan ng kuryente: ano ang dapat gawin, at kung may battery, gaano ito katagal tatagal. '
                  'May forecast din ng araw sa susunod na 48 oras. Bukas mula sa Home o sa alert.',
            ),
            (
              Icons.fact_check_outlined,
              'System check',
              'May solar? Sa Bill, sinusuri ko kung sapat pa ang panels, battery at inverter sa gamit ng bahay mo.',
            ),
            (
              Icons.notifications_active_outlined,
              'Notifications',
              'I-on ang "Notify me about alerts" sa Settings para hindi mo ma-miss ang brownout o sira.',
            ),
            (
              Icons.settings_rounded,
              'Settings',
              'Ang gear sa kanang itaas: pangalan, setup ng bahay, Meralco rate para tama ang bill, at Light o '
                  'Dark mode.',
            ),
          ]),
        4 => TextField(
            key: const Key('onboard-name'),
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            style: ts(16, w: FontWeight.w600),
            onSubmitted: (_) => _who.isEmpty ? null : _go(_setupStep),
            decoration: const InputDecoration(
              hintText: 'Hal. Juan',
              prefixIcon: Icon(Icons.person_outline_rounded),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            ),
          ),
        _ => _setupChoice(),
      };

  Widget _setupChoice() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Option(
            key: const Key('onboard-solar'),
            icon: Icons.solar_power_rounded,
            title: 'May solar ako',
            body: 'Solar panels at hybrid inverter. Makikita mo ang solar, battery, brownout backup, tipid at bill.',
            selected: _home == _Home.solar,
            onTap: () => setState(() => _home = _Home.solar),
          ),
          if (_home == _Home.solar)
            Padding(
              padding: const EdgeInsets.only(top: S.x2),
              child: SCard(
                padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x1),
                child: Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const Key('onboard-also-meter'),
                    contentPadding: EdgeInsets.zero,
                    value: _alsoMeter,
                    onChanged: (v) => setState(() => _alsoMeter = v),
                    title: Text('May smart meter din ako', style: ts(13, w: FontWeight.w700)),
                    subtitle: Text('Para sa eksaktong basa ng Meralco bill at boltahe.', style: ts(11, color: C.muted)),
                  ),
                ),
              ),
            ),
          const SizedBox(height: S.x3),
          _Option(
            key: const Key('onboard-meter_only'),
            icon: Icons.electric_meter_rounded,
            title: 'Smart meter lang',
            body: 'Wala pang solar. Babasahin ang meter mo para sa gamit, bill, at mga paraan para makatipid '
                'batay sa gamit ng bahay mo.',
            selected: _home == _Home.meter,
            onTap: () => setState(() => _home = _Home.meter),
          ),
          const SizedBox(height: S.x2),
          Text('Mababago mo ito anytime sa Settings.', style: ts(11.5, color: C.muted)),
          if (_error != null) ...[
            const SizedBox(height: S.x3),
            Semantics(
              liveRegion: true,
              child: Text('Hindi na-save. $_error', style: ts(12, w: FontWeight.w600, color: C.red)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.push(Routes.settings),
                icon: const Icon(Icons.settings_rounded, size: 16),
                label: const Text('Server settings'),
              ),
            ),
          ],
        ],
      );
}

/// Back, the step dots, and "Laktawan" (skip the introduction).
class _TopBar extends StatelessWidget {
  const _TopBar({required this.step, this.onBack, this.onSkip});
  final int step;
  final VoidCallback? onBack, onSkip;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(S.x1, S.x1, S.x2, 0),
        child: Row(children: [
          SizedBox(
            width: 48,
            child: onBack == null
                ? null
                : IconButton(
                    key: const Key('onboard-back'),
                    tooltip: 'Back',
                    onPressed: onBack,
                    icon: Icon(Icons.arrow_back_rounded, color: C.ink),
                  ),
          ),
          Expanded(
            child: Semantics(
              label: 'Step ${step + 1} of $_steps',
              excludeSemantics: true,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (var i = 0; i < _steps; i++)
                  AnimatedContainer(
                    duration: reduceMotion(context) ? Duration.zero : M.slide,
                    curve: M.ease,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == step ? 20 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i <= step ? C.orange : C.navOff,
                      borderRadius: BorderRadius.circular(R.pill),
                    ),
                  ),
              ]),
            ),
          ),
          SizedBox(
            width: 92,
            child: onSkip == null
                ? null
                : TextButton(key: const Key('onboard-skip'), onPressed: onSkip, child: const Text('Laktawan')),
          ),
        ]),
      );
}

/// Mira's first appearance: she drops in from above and bounces into place, once. Still under reduced
/// motion.
class _Entrance extends StatelessWidget {
  const _Entrance({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.elasticOut,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, -40 * (1 - t)),
          child: Transform.scale(scale: 0.4 + 0.6 * t, child: child),
        ),
      ),
      child: child,
    );
  }
}

/// A step's content slides up and fades in when the step changes.
class _Swap extends StatelessWidget {
  const _Swap({required this.id, required this.child});
  final Object id;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: reduceMotion(context) ? Duration.zero : const Duration(milliseconds: 320),
        switchInCurve: M.easeEnter,
        layoutBuilder: (current, previous) =>
            Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(a),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(id), child: child),
      );
}

/// Mira's speech bubble, its tail pointing up at her.
class _Bubble extends StatelessWidget {
  const _Bubble(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final fill = C.night ? const Color(0xFF2B3760) : const Color(0xFFFFE6B3);
    return Semantics(
      liveRegion: true,
      label: 'Mira: $text',
      excludeSemantics: true,
      child: Column(children: [
        CustomPaint(size: const Size(22, 11), painter: _Tail(fill)),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, S.x3 + 2),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(18)),
          child: Text(text, textAlign: TextAlign.center, style: ts(15, w: FontWeight.w600, height: 1.45)),
        ),
      ]),
    );
  }
}

class _Tail extends CustomPainter {
  _Tail(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
        Path()
          ..moveTo(0, size.height)
          ..lineTo(size.width / 2, 0)
          ..lineTo(size.width, size.height)
          ..close(),
        Paint()..color = color,
      );

  @override
  bool shouldRepaint(_Tail old) => old.color != color;
}

/// Icon, a bold line and a short explanation, one card per point.
class _Points extends StatelessWidget {
  const _Points(this.points);
  final List<(IconData, String, String)> points;

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final (icon, title, body) in points) ...[
          SCard(
            padding: const EdgeInsets.all(S.x3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: C.orange.withValues(alpha: 0.14), borderRadius: R.control),
                child: Icon(icon, size: 22, color: C.orangeText),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: ts(13.5, w: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(body, style: ts(12, height: 1.45, color: C.label)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: S.x2),
        ],
      ]);
}

/// One answer: a big card you tap, outlined in orange with a check when chosen.
class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title, body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? C.yellow.withValues(alpha: C.night ? 0.12 : 0.25) : C.card,
        shape: RoundedRectangleBorder(
          borderRadius: R.card,
          side: selected ? const BorderSide(color: C.orange, width: 2) : kCardLine,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(S.x4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: C.orange.withValues(alpha: 0.14), borderRadius: R.control),
                child: Icon(icon, color: C.orangeText),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: ts(15, w: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(body, style: ts(12, height: 1.45, color: C.label)),
                ]),
              ),
              const SizedBox(width: S.x2),
              ExcludeSemantics(
                child: Icon(
                  selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  color: selected ? C.orangeText : C.navOff,
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
