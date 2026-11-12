// Home: live status from /ws/live + yesterday's AI recap. Placeholder until the Figma design.
// States to design (TESTING.md): solar | battery | grid | brownout | fault | offline, and empty (telemetry null).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/utils/format.dart';
import '../../providers/data_providers.dart';
import '../../providers/live_providers.dart';
import '../common/placeholder.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveProvider);
    final summary = ref.watch(dailySummaryProvider);
    final text = Theme.of(context).textTheme;
    final data = live.live;

    return PlaceholderPage(
      onRefresh: () => ref.refresh(dailySummaryProvider.future),
      children: [
        const PlaceholderBanner('Home'),
        if (data == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else ...[
          Text('State: ${live.state}', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(data['status_line'] as String? ?? '', style: text.bodyLarge),
          const SizedBox(height: 8),
          Text('Saved today: ${formatPhp(data['saved_today_php'] as num? ?? 0)}'),
          if (live.telemetry == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Wala pang reading mula sa device. Hintayin lang.'),
            ),
          if (live.updatedAt != null) Text('Updated ${TimeOfDay.fromDateTime(live.updatedAt!).format(context)}'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => context.push(Routes.brownout),
            icon: const Icon(Icons.flash_off),
            label: const Text('Brownout Advisor'),
          ),
          const SizedBox(height: 8),
          JsonView(data),
        ],
        const SizedBox(height: 16),
        Text('Kahapon (daily summary)', style: text.titleMedium),
        AsyncView(
          value: summary,
          onRetry: () => ref.invalidate(dailySummaryProvider),
          data: (s) => JsonView(s),
        ),
      ],
    );
  }
}
