// Ask Mira (Figma "Ask Mira"): POST /api/chat. Answer + chips; spinner while the local LLM thinks (~10 s).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/chat_providers.dart';
import '../common/ui.dart';

class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});
  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  static const _suggestions = [
    'Bakit mataas ang bill ko?',
    'Magkano ang natipid ko dahil sa solar?',
    'Ilang porsyento na ang battery ko?',
    'Kailan ko dapat gamitin ang washing machine?',
  ];
  static const _welcome = ChatMessage.solaris(
      'Hi! Ako si Mira. Tanungin mo ako tungkol sa solar, battery, o bill mo, sa Taglish o English.');

  final _input = TextEditingController();
  final _scroll = ScrollController();

  void _send([String? preset]) {
    final q = (preset ?? _input.text).trim();
    if (q.isEmpty || ref.read(chatProvider).waiting) return;
    _input.clear();
    ref.read(chatProvider.notifier).send(q);
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    ref.listen(chatProvider, (_, _) => _toBottom());
    final messages = [_welcome, ...chat.messages];

    return Column(children: [
      const SafeArea(bottom: false, child: PageHeader('Ask Mira', 'Get answers about your solar energy.')),
      const SizedBox(height: 16),
      Expanded(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          children: [
            for (final m in messages) _Bubble(m),
            if (chat.waiting) const _Typing(),
            if (chat.messages.isEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in _suggestions)
                  ActionChip(
                    label: Text(s, style: ts(10, w: FontWeight.w600, color: C.orangeDeep)),
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: C.tileBorder),
                    onPressed: () => _send(s),
                  ),
              ]),
            ],
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(19, 0, 19, 12),
        child: Container(
          height: 44,
          padding: const EdgeInsets.only(left: 16, right: 5),
          decoration: BoxDecoration(
            color: const Color(0x6BFFC857),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0x85F47721), width: 0.7),
          ),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: ts(12),
                decoration: InputDecoration(
                  hintText: 'Type your question in TagLish or English...',
                  hintStyle: ts(11, color: C.ink.withValues(alpha: 0.34)),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            Semantics(
              button: true,
              label: 'Send',
              child: Material(
                color: chat.waiting ? C.muted : C.orange,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: chat.waiting ? null : _send,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      svg('send', width: 12, height: 10),
                      const SizedBox(width: 5),
                      Text('SEND', style: ts(9, w: FontWeight.w800, color: Colors.white)),
                    ]),
                  ),
                ),
              ),
            ),
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
    final mine = m.fromUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(mine ? 'You' : 'Mira', style: ts(9, color: const Color(0xFFADADAD), spacing: -0.18)),
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: mine ? C.orange : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: mine ? null : Border.all(color: m.isError ? C.red : C.tileBorder, width: 0.5),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.text, style: ts(12, height: 1.4, color: mine ? Colors.white : C.ink)),
                if (m.chips.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final c in m.chips)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: C.cream, borderRadius: BorderRadius.circular(6)),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: '${c['label']}  ', style: ts(9, w: FontWeight.w600, color: C.label55)),
                          TextSpan(text: '${c['value']}', style: ts(10, w: FontWeight.w700, color: C.orange)),
                        ])),
                      ),
                  ]),
                ],
              ]),
            ),
          ),
          if (m.source == 'fallback')
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('Mabilisang sagot (hindi AI) · galing sa data mo', style: ts(8, color: C.muted)),
            ),
        ],
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text('Nag-iisip si Mira… (hanggang ~10 s)', style: ts(10, color: C.muted)),
        ]),
      );
}
