// Browser Notification API through dart:js_interop (no extra package).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'system_notifier.dart';

SystemNotifier create() => _WebNotifier();

@JS('Notification')
extension type _Notification._(JSObject _) implements JSObject {
  external factory _Notification(String title, _Options options);
  external static String get permission;
  external static JSPromise<JSString> requestPermission();
}

extension type _Options._(JSObject _) implements JSObject {
  external factory _Options({String body, String tag, String icon});
}

@JS('document.visibilityState')
external String get _visibilityState;

class _WebNotifier implements SystemNotifier {
  @override
  bool get supported => globalContext.has('Notification');

  @override
  String get permission => supported ? _Notification.permission : 'unsupported';

  @override
  Future<bool> requestPermission() async {
    if (!supported) return false;
    if (permission == 'granted') return true;
    final result = await _Notification.requestPermission().toDart;
    return result.toDart == 'granted';
  }

  @override
  bool get appHidden => _visibilityState == 'hidden';

  @override
  void show(String title, String body, {String? tag}) {
    if (!supported || permission != 'granted') return;
    // `tag` makes the browser replace an older notification for the same alert instead of stacking.
    _Notification(title, _Options(body: body, tag: tag ?? title, icon: 'icons/Icon-192.png'));
  }
}
