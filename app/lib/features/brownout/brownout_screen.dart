// Brownout Advisor: status, battery runtime estimate, Taglish advice. Opened from Home / Alerts.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/data_providers.dart';
import '../common/placeholder.dart';

class BrownoutScreen extends ConsumerWidget {
  const BrownoutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brownout = ref.watch(brownoutProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Brownout Advisor')),
      body: PlaceholderPage(
        onRefresh: () => ref.refresh(brownoutProvider.future),
        children: [
          const PlaceholderBanner('Brownout Advisor'),
          AsyncView(value: brownout, onRetry: () => ref.invalidate(brownoutProvider), data: (b) => JsonView(b)),
        ],
      ),
    );
  }
}
