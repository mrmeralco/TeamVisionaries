// Ask Sinag: POST /api/chat. Keeps the conversation for the app session.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_providers.dart';

class ChatMessage {
  const ChatMessage.user(this.text)
      : fromUser = true,
        chips = const [],
        source = null,
        isError = false;
  const ChatMessage.sinag(this.text, {this.chips = const [], this.source})
      : fromUser = false,
        isError = false;
  const ChatMessage.error(this.text)
      : fromUser = false,
        chips = const [],
        source = null,
        isError = true;

  final bool fromUser;
  final String text;

  /// [{label, value}] from the facts the AI cited, e.g. {"label": "Bill this month", "value": "₱536"}.
  final List<Map<String, dynamic>> chips;

  /// llm | fallback
  final String? source;
  final bool isError;
}

class ChatState {
  const ChatState({this.messages = const [], this.waiting = false});
  final List<ChatMessage> messages;

  /// True while the local LLM is thinking (up to ~10 s): show the spinner.
  final bool waiting;
}

class ChatNotifier extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  Future<void> send(String text) async {
    final message = text.trim();
    if (message.isEmpty || state.waiting) return;
    state = ChatState(messages: [...state.messages, ChatMessage.user(message)], waiting: true);
    ChatMessage reply;
    try {
      final res = await ref.read(apiServiceProvider).chat(message);
      reply = ChatMessage.sinag(
        res['reply'] as String? ?? '',
        chips: ((res['chips'] as List?) ?? const []).cast<Map<String, dynamic>>(),
        source: res['source'] as String?,
      );
    } catch (_) {
      reply = const ChatMessage.error('Hindi ma-reach ang Sinag server. Subukan ulit.');
    }
    if (!ref.mounted) return;
    state = ChatState(messages: [...state.messages, reply]);
  }

  void clear() => state = const ChatState();
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
