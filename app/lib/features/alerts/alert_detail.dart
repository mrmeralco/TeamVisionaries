// One alert, explained: what happened, what it means, what to do, plus a next step (Brownout Advisor,
// Home, or ask Mira). Opened from the Alerts list and from Home's fault banner.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/chat_providers.dart';
import '../../providers/data_providers.dart';
import '../common/ui.dart';

/// Icon and colour for an alert type / severity.
(IconData, Color) alertLook(String type, String severity) => (
      switch (type) {
        'fault' => Icons.error_outline_rounded,
        'brownout' => Icons.power_off_rounded,
        'grid_restored' => Icons.power_rounded,
        'low_battery' => Icons.battery_alert_rounded,
        'high_temp' => Icons.thermostat_rounded,
        'device_offline' => Icons.cloud_off_rounded,
        'device_online' => Icons.cloud_done_rounded,
        _ => Icons.notifications_rounded,
      },
      severityColor(severity),
    );

Color severityColor(String severity) => switch (severity) { 'critical' => C.red, 'warning' => C.amber, _ => C.green };

String severityLabel(String severity) => switch (severity) { 'critical' => 'Critical', 'warning' => 'Warning', _ => 'Info' };

/// (what it means, what to do) per alert type, in the app's Taglish voice. [solar] false: a meter-only home,
/// where a brownout means no power at all (no battery or solar to fall back on).
(String, String) alertExplanation(String type, {bool solar = true}) => switch (type) {
      'brownout' when !solar => (
        'Walang kuryente mula sa grid, at walang solar o battery na sasalo, kaya patay ang kuryente sa bahay.',
        'Hugutin ang aircon, ref, TV at computer para hindi sila tamaan ng biglang pagbalik ng kuryente.',
      ),
      'grid_restored' when !solar => (
        'Bumalik na ang kuryente mula sa grid.',
        'Isaksak ulit ang mga appliance nang paisa-isa, ref muna.',
      ),
      'fault' => (
        'May error code ang inverter, kaya puwedeng huminto o bumaba ang solar output.',
        'I-off at i-on ulit ang inverter. Kung bumalik ang fault, tawagan ang installer at sabihin ang fault code.',
      ),
      'high_temp' => (
        'Mainit ang inverter, kaya kusa nitong binabawasan ang output para hindi masira.',
        'Siguraduhing may hangin sa paligid nito at hindi ito direktang nasisikatan ng araw.',
      ),
      'brownout' => (
        'Walang kuryente mula sa grid. Battery at solar ang gamit ng bahay mo ngayon.',
        'Bawasan muna ang aircon, plantsa at iba pang mabibigat na gamit para tumagal ang battery.',
      ),
      'grid_restored' => (
        'Bumalik na ang kuryente mula sa grid.',
        'Wala kang kailangang gawin: magcha-charge ulit ang battery.',
      ),
      'low_battery' => (
        'Mababa na ang battery, kaya baka grid na ang gamitin o maputol ang kuryente kung may brownout.',
        'Iwasan muna ang mabibigat na gamit hanggang mag-charge ulit ang battery sa araw.',
      ),
      'device_offline' => (
        'Hindi nakakapagpadala ng reading ang Solaris device, kaya luma ang mga numero sa app.',
        'Tingnan kung naka-on ang device at kung may Wi-Fi. Babalik ang readings pag nakakonekta ulit.',
      ),
      'device_online' => (
        'Nakakonekta na ulit ang Solaris device.',
        'Wala kang kailangang gawin: live na ulit ang readings.',
      ),
      _ => ('Update tungkol sa solar system mo.', 'Tanungin si Mira kung may tanong ka.'),
    };

/// Next step for an alert type: (button label, action), or null.
(String, void Function(BuildContext))? alertAction(String type) => switch (type) {
      'brownout' || 'low_battery' => ('Open Brownout Advisor', (c) => c.push(Routes.brownout)),
      'grid_restored' || 'device_offline' || 'device_online' || 'fault' || 'high_temp' => (
        'View on Home',
        (c) => c.go(Routes.home),
      ),
      _ => null,
    };

/// Bottom sheet with the alert's full text and explanation. Marks it read.
Future<void> showAlertDetail(BuildContext context, WidgetRef ref, Map<String, dynamic> a) {
  final id = intOrNull(a['id']);
  if (id != null && a['read'] != true) {
    ref.read(alertsProvider.notifier).markRead(id).catchError((_) {}); // best effort; the list can retry
  }
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    constraints: const BoxConstraints(maxWidth: kMaxAppWidth),
    builder: (sheet) => _AlertSheet(a: a, ref: ref, outer: context),
  );
}

class _AlertSheet extends StatelessWidget {
  const _AlertSheet({required this.a, required this.ref, required this.outer});
  final Map<String, dynamic> a;
  final WidgetRef ref;
  final BuildContext outer;

  @override
  Widget build(BuildContext context) {
    final type = str(a['type']);
    final severity = str(a['severity'], 'info');
    final title = str(a['title'], 'Alert');
    final message = str(a['message']);
    final ts0 = intOrNull(a['ts']);
    final (icon, color) = alertLook(type, severity);
    final (meaning, todo) = alertExplanation(type, solar: ref.read(hasSolarProvider));
    final action = alertAction(type);

    void close() => Navigator.of(context).pop();

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(S.gutter, 0, S.gutter, S.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: R.control),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: S.x3),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(title, style: ts(17, w: FontWeight.w700))),
                  Text(
                    '${severityLabel(severity)}${ts0 == null ? '' : '  ·  ${formatWhen(ts0)}'}',
                    style: ts(11, w: FontWeight.w600, color: color),
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: S.x4),
            if (message.isNotEmpty) Text(message, style: ts(14, height: 1.45)),
            const SizedBox(height: S.x4),
            _Section('Ano ang ibig sabihin nito?', meaning),
            const SizedBox(height: S.x2),
            _Section('Ano ang gagawin?', todo),
            const SizedBox(height: S.x6),
            Wrap(spacing: S.x2, runSpacing: S.x2, children: [
              if (action != null)
                FilledButton(
                  onPressed: () {
                    close();
                    action.$2(outer);
                  },
                  child: Text(action.$1),
                ),
              OutlinedButton.icon(
                icon: const MiraAvatar(size: 22),
                label: const Text('Ask Mira about this'),
                onPressed: () {
                  close();
                  ref.read(chatProvider.notifier).send('Ipaliwanag mo ang alert na ito: $title. $message');
                  outer.push(Routes.ask);
                },
              ),
              TextButton(onPressed: close, child: const Text('Close')),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.body);
  final String title, body;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(S.x3),
        decoration: BoxDecoration(color: C.cream, borderRadius: R.tile),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: ts(13, w: FontWeight.w700)),
          const SizedBox(height: S.x1),
          Text(body, style: ts(13, height: 1.45)),
        ]),
      );
}
