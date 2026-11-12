// Temporary building blocks for the pre-Figma screens. They show the raw contract data so the team can
// check the server connection; delete them as each screen gets its real design.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Figma UI goes here" banner at the top of each placeholder screen.
class PlaceholderBanner extends StatelessWidget {
  const PlaceholderBanner(this.screen, {super.key});
  final String screen;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: c.tertiaryContainer, borderRadius: BorderRadius.circular(8)),
      child: Text('$screen: placeholder, Figma design pending. Showing raw data from the server.',
          style: TextStyle(color: c.onTertiaryContainer)),
    );
  }
}

/// Loading / error-with-retry / data for one AsyncValue.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => switch (value) {
        AsyncData(:final value) => data(value),
        AsyncError(:final error) => Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.cloud_off, size: 40),
              const SizedBox(height: 8),
              Text('Hindi ma-reach ang server.\n$error', textAlign: TextAlign.center),
              if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Subukan ulit')),
            ]),
          ),
        _ => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      };
}

/// Pretty-printed JSON, selectable.
class JsonView extends StatelessWidget {
  const JsonView(this.json, {super.key});
  final Object? json;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(json),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      );
}

/// Scrollable page with pull-to-refresh.
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({super.key, required this.children, this.onRefresh});
  final List<Widget> children;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = ListView(padding: const EdgeInsets.all(16), children: children);
    return onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list);
  }
}
