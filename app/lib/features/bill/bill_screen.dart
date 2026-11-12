// Bill: month-to-date, forecast + range, vs last month, weekly costs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/data_providers.dart';
import '../common/placeholder.dart';

class BillScreen extends ConsumerWidget {
  const BillScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = ref.watch(billProvider);
    return PlaceholderPage(
      onRefresh: () => ref.refresh(billProvider.future),
      children: [
        const PlaceholderBanner('Bill'),
        AsyncView(value: bill, onRetry: () => ref.invalidate(billProvider), data: (b) => JsonView(b)),
      ],
    );
  }
}
