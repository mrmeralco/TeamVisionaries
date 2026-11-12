// Live data from WS /ws/live: the latest /api/live object, the socket's link status, and new alerts.
// Home reads [liveProvider]; the Alerts badge reads [alertsProvider] (data_providers.dart), which
// listens here for {"type": "alert"} messages.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/live_connection.dart';
import 'server_providers.dart';

class LiveState {
  const LiveState({
    this.link = LinkStatus.connecting,
    this.retryIn,
    this.error,
    this.live,
    this.updatedAt,
    this.lastAlert,
  });

  final LinkStatus link;
  final Duration? retryIn;
  final Object? error;

  /// Latest `/api/live`-shaped object (null until the first telemetry message).
  final Map<String, dynamic>? live;
  final DateTime? updatedAt;

  /// Most recent alert pushed over the socket (same shape as an item of `/api/alerts`).
  final Map<String, dynamic>? lastAlert;

  /// solar | battery | grid | brownout | fault | offline
  String? get state => live?['state'] as String?;
  Map<String, dynamic>? get device => live?['device'] as Map<String, dynamic>?;

  /// Null on a brand-new DB: show the friendly empty state, not an error.
  Map<String, dynamic>? get telemetry => live?['telemetry'] as Map<String, dynamic>?;

  bool get isConnected => link == LinkStatus.connected;

  LiveState copyWith({
    LinkStatus? link,
    Duration? retryIn,
    Object? error,
    Map<String, dynamic>? live,
    DateTime? updatedAt,
    Map<String, dynamic>? lastAlert,
  }) =>
      LiveState(
        link: link ?? this.link,
        retryIn: retryIn,
        error: error,
        live: live ?? this.live,
        updatedAt: updatedAt ?? this.updatedAt,
        lastAlert: lastAlert ?? this.lastAlert,
      );
}

class LiveNotifier extends Notifier<LiveState> {
  @override
  LiveState build() {
    final api = ref.watch(apiServiceProvider);
    final sub = reconnectingLive(api).listen(_onEvent);
    ref.onDispose(sub.cancel);
    return const LiveState();
  }

  void _onEvent(LiveEvent e) {
    if (e.status != null) {
      state = state.copyWith(link: e.status, retryIn: e.retryIn, error: e.error);
      return;
    }
    final msg = e.message!;
    final data = msg['data'];
    if (data is! Map<String, dynamic>) return;
    switch (msg['type']) {
      case 'telemetry':
        state = state.copyWith(link: state.link, live: data, updatedAt: DateTime.now());
      case 'status':
        final live = state.live;
        if (live != null) {
          state = state.copyWith(link: state.link, live: {
            ...live,
            'device': data,
            if (data['online'] == false) ...{
              'state': 'offline',
              'status_line': 'Offline ang Solaris device. Huling reading ang ipinapakita.',
            },
          }, updatedAt: DateTime.now());
        }
      case 'alert':
        state = state.copyWith(link: state.link, lastAlert: data);
      default: // 'meter' and future types: ignored by the app for now
        break;
    }
  }
}

final liveProvider = NotifierProvider<LiveNotifier, LiveState>(LiveNotifier.new);
