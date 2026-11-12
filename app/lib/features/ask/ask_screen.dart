// Ask Mira (Figma "Ask Mira"): POST /api/chat. Answer + chips; spinner while the local LLM thinks (~10 s).
// Suggestions after every answer, "Try again" on a failed answer, selectable text, new conversation.
// Opens on top of the tabs from the floating Mira button (and "Ask Mira about …" links); back returns.
// Under each answer: the data it came from (AnswerSources), each linking to its screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/chat_providers.dart';
import '../common/ui.dart';
import 'answer_sources.dart';

/// Is this answer bad news for the household (a brownout, a fault, a low battery, a higher bill, the
/// device offline, a cloudy day ahead)? Then Mira tells it with her sad face instead of talking
/// cheerfully. A rough read of her own words, since /api/chat sends no mood; "walang problema"-style
/// reassurances don't count.
bool isBadNews(String reply) {
  final s = reply.toLowerCase();
  const reassuring = ['walang problema', 'walang fault', 'no fault', 'no issues', 'walang brownout', 'hindi mataas'];
  const bad = [
    'may brownout', 'nawalan ng kuryente', 'walang kuryente', 'brownout ngayon',
    'fault', 'error code', 'may problema', 'nasira', 'sira ang', 'overheat', 'sobrang init', 'mainit ang inverter',
    'mababa na ang battery', 'low battery', 'ubos na', 'hindi kakayanin', 'hindi aabot', 'hindi mapupuno',
    'mas mataas', 'mataas ang bill', 'tumaas ang bill', 'tumaas ang singil', 'mas malaki ang bill', 'higher than', 'more than last month',
    'offline', 'hindi nakakonekta', 'disconnected', 'maulap',
  ];
  var t = s;
  for (final r in reassuring) {
    t = t.replaceAll(r, '');
  }
  return bad.any(t.contains);
}

/// Mira's face beside a message. The newest one moves (she greets, says the answer, or breaks the bad
/// news, then rests); older ones stand still so a long chat isn't full of moving faces.
MiraAvatar _miraFor(ChatMessage m, {required bool first, required bool newest}) {
  const size = 40.0;
  if (m.isError || isBadNews(m.text)) {
    return MiraAvatar(mood: MiraMood.error, size: size, animate: newest, cycles: 3);
  }
  if (first) return MiraAvatar(mood: MiraMood.happy, size: size, animate: newest, cycles: 2);
  if (!newest) return const MiraAvatar(size: size, animate: false);
  // Talks for about as long as the answer takes to read at a glance (1.8–7.2 s), then rests.
  final beats = (m.text.length / 40).round().clamp(3, 12);
  return MiraAvatar(mood: MiraMood.talking, size: size, cycles: beats, settleTo: MiraMood.idle);
}

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

    return Scaffold(
      backgroundColor: C.cream,
      body: Column(children: [
        BackHeader(
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
        const SizedBox(height: S.x2),
        Expanded(
          child: SelectionArea(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(S.gutter, S.x2, S.gutter, S.x3),
              children: [
                for (var i = 0; i < messages.length; i++)
                  _Bubble(
                    messages[i],
                    mira: messages[i].fromUser
                        ? null
                        : _miraFor(messages[i], first: i == 0, newest: i == messages.length - 1 && !chat.waiting),
                    onRetry: i == messages.length - 1 && messages[i].isError && !chat.waiting
                        ? () => ref.read(chatProvider.notifier).retry()
                        : null,
                  ),
                if (chat.waiting) const _Typing(),
                if (followUps.isNotEmpty) ...[
                  const SizedBox(height: S.x1),
                  Wrap(spacing: S.x2, runSpacing: S.x2, children: [
                    for (final s in followUps)
                      ActionChip(
                        label: Text(s, style: ts(12, w: FontWeight.w600, color: C.orangeText)),
                        onPressed: () => _send(s),
                      ),
                  ]),
                ],
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(S.gutter, 0, S.gutter, S.x3),
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.fromLTRB(S.x4, S.x1, S.x1, S.x1),
              decoration: BoxDecoration(
                color: C.inputBg,
                borderRadius: R.tile,
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
                    borderRadius: R.control,
                    child: InkWell(
                      borderRadius: R.control,
                      onTap: chat.waiting ? null : _send,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: kMinTap, minWidth: kMinTap),
                        padding: const EdgeInsets.symmetric(horizontal: S.x3),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          svg('send', width: 12, height: 10),
                          const SizedBox(width: 6),
                          Text('Send', style: ts(13, w: FontWeight.w700, color: Colors.white)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// "Mira" / "You" above each bubble, same style for the typing indicator.
Widget _sender(bool mine) =>
    Text(mine ? 'You' : 'Mira', style: ts(11, w: FontWeight.w700, color: mine ? C.muted : C.orangeText));

/// Mira's messages carry her face at the left; yours stand alone at the right.
Widget _withMira(Widget mira, Widget child) => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: S.x2), child: mira),
        const SizedBox(width: S.x2),
        Flexible(child: child),
      ],
    );

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {this.mira, this.onRetry});
  final ChatMessage m;
  final Widget? mira; // null on your own messages
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final mine = m.fromUser;
    final body = Column(
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
              // The corner nearest the sender stays tight, so each bubble points at who said it.
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(mine ? R.md : R.sm / 2),
                topRight: Radius.circular(mine ? R.sm / 2 : R.md),
                bottomLeft: const Radius.circular(R.md),
                bottomRight: const Radius.circular(R.md),
              ),
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
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(R.pill)),
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
        if (m.sources.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.86),
            child: AnswerSources(m.sources),
          ),
        if (m.source == 'fallback')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Mabilisang sagot (hindi AI) · galing sa data mo', style: ts(10, color: C.muted)),
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: mira == null ? body : _withMira(mira!, body),
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
          // Thinking for as long as the answer takes.
          child: _withMira(
            const MiraAvatar(mood: MiraMood.thinking, size: 40),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _sender(false),
              const SizedBox(height: 5),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: BoxDecoration(
                  color: C.miraBubble,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(R.sm / 2),
                    topRight: Radius.circular(R.md),
                    bottomLeft: Radius.circular(R.md),
                    bottomRight: Radius.circular(R.md),
                  ),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Flexible(child: Text('Nag-iisip si Mira… (hanggang ~10 s)', style: ts(12, color: C.label))),
                ]),
              ),
            ]),
          ),
        ),
      );
}
