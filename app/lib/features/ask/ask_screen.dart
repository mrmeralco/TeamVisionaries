// Ask Sinag: Taglish Q&A over POST /api/chat. Answer + chips; spinner while the local LLM thinks.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_providers.dart';
import '../common/placeholder.dart';

class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    ref.read(chatProvider.notifier).send(_input.text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    return Column(children: [
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PlaceholderBanner('Ask Sinag'),
            for (final m in chat.messages) _Bubble(m),
            if (chat.waiting)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator())),
          ],
        ),
      ),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                decoration: const InputDecoration(hintText: 'Bakit mataas ang bill ko?'),
                onSubmitted: (_) => _send(),
              ),
            ),
            IconButton(onPressed: chat.waiting ? null : _send, icon: const Icon(Icons.send)),
          ]),
        ),
      ),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m);
  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Align(
      alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: m.isError ? c.errorContainer : (m.fromUser ? c.primaryContainer : c.surfaceContainerHighest),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.text),
          if (m.chips.isNotEmpty)
            Wrap(spacing: 6, children: [
              for (final chip in m.chips) Chip(label: Text('${chip['label']}: ${chip['value']}')),
            ]),
          if (m.source == 'fallback')
            Text('(rule-based answer)', style: Theme.of(context).textTheme.labelSmall),
        ]),
      ),
    );
  }
}
