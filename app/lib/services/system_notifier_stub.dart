import 'system_notifier.dart';

SystemNotifier create() => _Unsupported();

class _Unsupported implements SystemNotifier {
  @override
  bool get supported => false;
  @override
  String get permission => 'unsupported';
  @override
  Future<bool> requestPermission() async => false;
  @override
  bool get appHidden => false;
  @override
  void show(String title, String body, {String? tag}) {}
}
