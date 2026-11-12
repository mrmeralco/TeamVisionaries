// Ask Mira: POST /api/chat. Keeps the conversation for the app session.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/api_service.dart';
import 'server_providers.dart';

class ChatMessage {
  const ChatMessage.user(this.text)
      : fromUser = true,
        chips = const [],
        source = null,
        isError = false;
  const ChatMessage.solaris(this.text, {this.chips = const [], this.source})
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
    await _answer(message);
  }

  /// Asks the last question again after a failed answer (the error bubble's "Try again").
  Future<void> retry() async {
    if (state.waiting || state.messages.isEmpty || !state.messages.last.isError) return;
    final question = state.messages.lastWhere((m) => m.fromUser, orElse: () => const ChatMessage.user('')).text;
    if (question.isEmpty) return;
    state = ChatState(messages: state.messages.sublist(0, state.messages.length - 1), waiting: true);
    await _answer(question);
  }

  Future<void> _answer(String message) async {
    ChatMessage reply;
    try {
      final res = await ref.read(apiServiceProvider).chat(message);
      final chips = res['chips'];
      reply = ChatMessage.solaris(
        res['reply'] is String ? res['reply'] as String : '',
        chips: chips is List ? [for (final c in chips) if (c is Map) c.cast<String, dynamic>()] : const [],
        source: res['source'] is String ? res['source'] as String : null,
      );
    } catch (e) {
      reply = ChatMessage.error(
        e is ApiException
            ? 'May problema sa Solaris server (error ${e.statusCode}). Subukan ulit mamaya.'
            : 'Hindi ma-reach ang Solaris server. Tingnan ang connection, tapos subukan ulit.',
      );
    }
    if (!ref.mounted) return;
    state = ChatState(messages: [...state.messages, reply]);
  }

  /// "New conversation".
  void clear() => state = const ChatState();
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
