// Ask Mira (Figma "Ask Mira"): POST /api/chat. Answer + chips; spinner while the local LLM thinks (~10 s).
// Suggestions after every answer, "Try again" on a failed answer, selectable text, new conversation.
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
  /// First three are the Figma chips; the rest rotate in as follow-ups once those are asked.
  static const _suggestions = [
    'Bakit mataas ang bill ko?',
    'Kakayanin ba ng battery mamaya?',
    'Magkano ang natipid ko dahil sa solar?',
    'Ilang porsyento na ang battery ko?',
    'Kailan ko dapat gamitin ang washing machine?',
    'Kumusta ang solar ko ngayong linggo?',
    'Paano ko pa mapapababa ang bill ko?',
    'Ano ang gagawin ko kapag may brownout?',
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

  /// Three suggestions the user hasn't asked yet.
  List<String> _next(ChatState chat) {
    final asked = {for (final m in chat.messages) if (m.fromUser) m.text};
    return _suggestions.where((s) => !asked.contains(s)).take(3).toList();
  }

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
    final lastFailed = chat.messages.isNotEmpty && chat.messages.last.isError;
    final followUps = chat.waiting || lastFailed ? const <String>[] : _next(chat);

    return Column(children: [
      SafeArea(
        bottom: false,
        child: PageHeader(
          'Ask Mira',
          'Get answers about your solar energy.',
          trailing: chat.messages.isEmpty
              ? null
              : IconButton(
                  tooltip: 'New conversation',
                  onPressed: chat.waiting ? null : () => ref.read(chatProvider.notifier).clear(),
                  icon: const Icon(Icons.add_comment_outlined, color: C.ink),
                ),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: SelectionArea(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            children: [
              for (var i = 0; i < messages.length; i++)
                _Bubble(
                  messages[i],
                  onRetry: i == messages.length - 1 && messages[i].isError && !chat.waiting
                      ? () => ref.read(chatProvider.notifier).retry()
                      : null,
                ),
              if (chat.waiting) const _Typing(),
              if (followUps.isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in followUps)
                    ActionChip(
                      label: Text(s, style: ts(12, w: FontWeight.w600, color: C.orangeText)),
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: C.orangeLine, width: 0.7),
                      onPressed: () => _send(s),
                    ),
                ]),
              ],
            ],
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(19, 0, 19, 12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.fromLTRB(16, 4, 5, 4),
          decoration: BoxDecoration(
            color: C.inputBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.inputBorder, width: 0.7),
          ),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                style: ts(13),
                decoration: InputDecoration(
                  hintText: 'Type your question in TagLish or English...',
                  hintStyle: ts(12, color: C.muted),
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
              excludeSemantics: true,
              child: Material(
                color: chat.waiting ? C.muted : C.brandDark,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: chat.waiting ? null : _send,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: kMinTap, minWidth: kMinTap),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      svg('send', width: 12, height: 10),
                      const SizedBox(width: 6),
                      Text('SEND', style: ts(11, w: FontWeight.w800, color: Colors.white)),
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

/// "Mira" / "You" above each bubble, same style for the typing indicator.
Widget _sender(bool mine) =>
    Text(mine ? 'You' : 'Mira', style: ts(11, w: FontWeight.w700, color: mine ? C.muted : C.orangeText));

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {this.onRetry});
  final ChatMessage m;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final mine = m.fromUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          _sender(mine),
          const SizedBox(height: 5),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: mine ? C.brandDark : (m.isError ? Colors.white : C.miraBubble),
                borderRadius: BorderRadius.circular(8),
                border: m.isError ? Border.all(color: C.red, width: 0.8) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.text, style: ts(13, height: 1.45, color: mine ? Colors.white : C.ink)),
                if (m.chips.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final c in m.chips)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(99)),
                        child: Text.rich(TextSpan(children: [
                          TextSpan(text: '${c['label']}  ', style: ts(11, w: FontWeight.w600, color: C.label)),
                          TextSpan(text: '${c['value']}', style: ts(11, w: FontWeight.w800, color: C.orangeText)),
                        ])),
                      ),
                  ]),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(kMinTap, kMinTap),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text('Try again', style: ts(12, w: FontWeight.w700, color: C.brandDark)),
                  ),
                ],
              ]),
            ),
          ),
          if (m.source == 'fallback')
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Mabilisang sagot (hindi AI) · galing sa data mo', style: ts(10, color: C.muted)),
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
        child: Semantics(
          liveRegion: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sender(false),
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(color: C.miraBubble, borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Flexible(child: Text('Nag-iisip si Mira… (hanggang ~10 s)', style: ts(12, color: C.label))),
              ]),
            ),
          ]),
        ),
      );
}
