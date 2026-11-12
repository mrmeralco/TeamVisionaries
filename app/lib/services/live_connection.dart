// Keeps /ws/live open for the whole app session: reconnects with backoff when the server restarts
// or the hotspot drops (TESTING.md: "Server restarts mid-demo → app reconnects on its own").
import 'dart:async';
import 'dart:math';

import 'api_service.dart';

enum LinkStatus {
  /// Opening the socket (first attempt or after a backoff wait).
  connecting,

  /// At least one message received on the current socket.
  connected,

  /// Socket dropped or failed; waiting [LiveEvent.retryIn] before the next attempt.
  waiting,
}

/// Either a server message ({"type", "data"}) or a change in the link status.
class LiveEvent {
  const LiveEvent.message(Map<String, dynamic> this.message)
      : status = null,
        retryIn = null,
        error = null;
  const LiveEvent.status(LinkStatus this.status, {this.retryIn, this.error}) : message = null;

  final Map<String, dynamic>? message;
  final LinkStatus? status;
  final Duration? retryIn;
  final Object? error;
}

/// Backoff: 1, 2, 4, 8, 16, then every [maxDelay] seconds.
Duration backoffFor(int attempt, {Duration maxDelay = const Duration(seconds: 15)}) {
  final secs = pow(2, min(attempt, 10)).toInt();
  final d = Duration(seconds: secs);
  return d > maxDelay ? maxDelay : d;
}

/// Endless stream of [LiveEvent]s. Cancel the subscription to stop reconnecting.
Stream<LiveEvent> reconnectingLive(
  ApiService api, {
  Duration Function(int attempt) backoff = backoffFor,
}) async* {
  var attempt = 0;
  while (true) {
    yield const LiveEvent.status(LinkStatus.connecting);
    Object? error;
    var sawMessage = false;
    try {
      await for (final msg in api.liveMessages()) {
        if (!sawMessage) {
          sawMessage = true;
          attempt = 0;
          yield const LiveEvent.status(LinkStatus.connected);
        }
        yield LiveEvent.message(msg);
      }
    } catch (e) {
      error = e;
    }
    final wait = backoff(attempt++);
    yield LiveEvent.status(LinkStatus.waiting, retryIn: wait, error: error);
    await Future<void>.delayed(wait);
  }
}
