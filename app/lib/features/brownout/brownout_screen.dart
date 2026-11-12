// Brownout Advisor: GET /api/brownout. Opened from the Home banner and brownout alerts.
// Refetches on every live reading so the runtime estimate follows the load.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../common/ui.dart';

class BrownoutScreen extends ConsumerWidget {
  const BrownoutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(liveProvider.select((s) => s.telemetry?['ts']), (prev, next) {
      if (prev != null && next != prev) ref.invalidate(brownoutProvider);
    });
    final brownout = ref.watch(brownoutProvider);
    return Scaffold(
      backgroundColor: C.cream,
      appBar: AppBar(
        backgroundColor: C.cream,
        surfaceTintColor: Colors.transparent,
        title: Text('Brownout Advisor', style: ts(18, w: FontWeight.w700)),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(brownoutProvider.future).then((_) {}, onError: (_) {}),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          AsyncBody(value: brownout, onRetry: () => ref.invalidate(brownoutProvider), data: (b) => _Body(b)),
        ]),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.b);
  final Map<String, dynamic> b;

  @override
  Widget build(BuildContext context) {
    final active = b['active'] == true;
    final runtime = b['runtime_h'] as num?;
    final start = b['start_ts'] as int?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          gradient: active ? gradientOrange : const LinearGradient(colors: [Color(0xFF6BBF8E), C.green]),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(active ? Icons.power_off_rounded : Icons.power_rounded, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(active ? 'MAY BROWNOUT NGAYON' : 'MAY KURYENTE MULA SA GRID',
                  style: ts(11, w: FontWeight.w700, color: Colors.white.withValues(alpha: 0.85), spacing: 0.1)),
            ),
          ]),
          const SizedBox(height: 14),
          if (active) ...[
            Text(runtime == null ? '—' : '~${runtime.toStringAsFixed(1)} oras', style: ts(32, w: FontWeight.w900, color: Colors.white)),
            Text('tatagal pa ang battery sa kasalukuyang gamit', style: ts(11, color: Colors.white)),
          ] else
            Text('Walang brownout', style: ts(26, w: FontWeight.w900, color: Colors.white)),
        ]),
      ),
      const SizedBox(height: 16),
      TwoCol(children: [
        _Stat('Battery', '${b['batt_soc']}', '%'),
        _Stat('Home Usage', kwNum(b['load_w']), 'kW'),
        _Stat(active ? 'Nagsimula' : 'Huling brownout', start == null ? '—' : formatClock(start), '',
            note: start == null ? null : formatShortDate(start)),
        _Stat('Tagal', '${b['duration_min'] ?? '—'}', 'min'),
      ]),
      const SizedBox(height: 16),
      SCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Payo ni Sinag', style: ts(13, w: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(b['advice'] as String, style: ts(12, height: 1.45)),
        ]),
      ),
      const SizedBox(height: 12),
      Text('${b['outages_this_month']} brownout ngayong buwan', style: ts(11, color: C.muted)),
    ]);
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.unit, {this.note});
  final String label, value, unit;
  final String? note;

  @override
  Widget build(BuildContext context) => SCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: ts(9, w: FontWeight.w600, color: C.tileLabel)),
          const SizedBox(height: 8),
          Reading(value, unit, size: 20),
          if (note != null) Text(note!, style: ts(9, color: C.muted)),
        ]),
      );
}
