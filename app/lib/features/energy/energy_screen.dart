// Energy: day / week / month series (fl_chart goes here with the Figma design).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/data_providers.dart';
import '../common/placeholder.dart';

class EnergyScreen extends ConsumerStatefulWidget {
  const EnergyScreen({super.key});

  @override
  ConsumerState<EnergyScreen> createState() => _EnergyScreenState();
}

class _EnergyScreenState extends ConsumerState<EnergyScreen> {
  String _period = 'day';

  @override
  Widget build(BuildContext context) {
    final energy = ref.watch(energyProvider(_period));
    return PlaceholderPage(
      onRefresh: () => ref.refresh(energyProvider(_period).future),
      children: [
        const PlaceholderBanner('Energy'),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'day', label: Text('Day')),
            ButtonSegment(value: 'week', label: Text('Week')),
            ButtonSegment(value: 'month', label: Text('Month')),
          ],
          selected: {_period},
          onSelectionChanged: (s) => setState(() => _period = s.first),
        ),
        const SizedBox(height: 12),
        AsyncView(
          value: energy,
          onRetry: () => ref.invalidate(energyProvider(_period)),
          data: (e) => JsonView({
            'self_sufficiency_pct': e['self_sufficiency_pct'],
            'totals': e['totals'],
            'points': '${(e['points'] as List).length} points',
          }),
        ),
      ],
    );
  }
}
