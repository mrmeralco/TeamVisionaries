// System notifications for alerts that arrive while the app isn't on screen.
//
// Web: the browser's Notification API (no plugin, works with the page in a background tab).
// Android/other: no-op for now. A native plugin (flutter_local_notifications) needs Gradle setup that
// couldn't be built/verified here; instead the app catches up on missed alerts when it comes back to the
// foreground (see AppShell).
import 'system_notifier_stub.dart' if (dart.library.js_interop) 'system_notifier_web.dart' as impl;

abstract class SystemNotifier {
  /// True when this platform can show system notifications at all.
  bool get supported;

  /// 'granted' | 'denied' | 'default' (not asked yet) | 'unsupported'
  String get permission;

  /// Asks the user (browser prompt). Returns true if notifications are now allowed.
  Future<bool> requestPermission();

  /// True when the app is not visible (background tab / minimised window).
  bool get appHidden;

  void show(String title, String body, {String? tag});
}

SystemNotifier createSystemNotifier() => impl.create();
