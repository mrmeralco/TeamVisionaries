// Settings: server address (the laptop's IP on the hotspot), mock toggle, "Test connection"
// (GET /api/health), and the server-side settings (rate, battery size, name) via PUT /api/settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/data_providers.dart';
import '../../providers/server_providers.dart';
import '../common/ui.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final _url = TextEditingController(text: ref.read(serverConfigProvider).baseUrl);
  final _name = TextEditingController();
  final _rate = TextEditingController();
  final _batt = TextEditingController();
  Map<String, dynamic>? _loaded; // server settings the household fields were filled from
  String? _urlError;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_url, _name, _rate, _batt]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic> s) {
    if (identical(s, _loaded)) return;
    _loaded = s;
    _name.text = '${s['user_name'] ?? ''}';
    _rate.text = '${s['rate_php_per_kwh'] ?? ''}';
    _batt.text = '${s['battery_kwh'] ?? ''}';
  }

  Future<void> _saveUrl() async {
    final ok = await ref.read(serverConfigProvider.notifier).setBaseUrl(_url.text);
    if (!mounted) return;
    setState(() {
      _urlError = ok ? null : 'Hindi valid na address. Halimbawa: 192.168.43.100:8000';
      if (ok) _url.text = ref.read(serverConfigProvider).baseUrl;
    });
    if (ok) await _test();
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final h = await ref.read(apiServiceProvider).health();
      _testOk = h['ok'] == true;
      _testResult = _testOk
          ? '✓ Connected${h['mock'] == true ? ' (mock data)' : ''} · AI: '
              '${h['llm_reachable'] == true ? '${h['llm']} ✓' : 'hindi maabot (rule-based answers)'}'
          : 'Server answered but not ok: $h';
    } catch (e) {
      _testOk = false;
      _testResult = '✗ Hindi ma-reach: $e';
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _saveHousehold() async {
    final s = _loaded ?? const {};
    final changes = <String, dynamic>{};
    final name = _name.text.trim();
    final rate = double.tryParse(_rate.text.trim());
    final batt = double.tryParse(_batt.text.trim());
    if (name.isNotEmpty && name != s['user_name']) changes['user_name'] = name;
    if (rate != null && rate > 0 && rate != s['rate_php_per_kwh']) changes['rate_php_per_kwh'] = rate;
    if (batt != null && batt > 0 && batt != s['battery_kwh']) changes['battery_kwh'] = batt;
    if (changes.isEmpty) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(serverSettingsProvider.notifier).save(changes);
      messenger.showSnackBar(const SnackBar(content: Text('Na-save ang settings.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Hindi na-save: hindi maabot ang server.')));
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _field(String label, TextEditingController c,
          {String? hint, TextInputType? type, String? suffix, String? error, bool enabled = true, ValueChanged<String>? onSubmitted}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: ts(11, w: FontWeight.w700)),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            enabled: enabled,
            keyboardType: type,
            style: ts(13),
            onSubmitted: onSubmitted,
            decoration: InputDecoration(hintText: hint, suffixText: suffix, errorText: error),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(serverConfigProvider);
    final household = ref.watch(serverSettingsProvider);
    if (household.value != null) _fill(household.value!);

    return Scaffold(
      backgroundColor: C.cream,
      appBar: AppBar(
        backgroundColor: C.cream,
        surfaceTintColor: Colors.transparent,
        title: Text('Settings', style: ts(18, w: FontWeight.w700)),
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: LinkIndicator())],
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('SERVER', style: ts(10, w: FontWeight.w700, color: C.muted, spacing: 0.5)),
        const SizedBox(height: 8),
        SCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: cfg.useMock,
                onChanged: (v) => ref.read(serverConfigProvider.notifier).setUseMock(v),
                title: Text('Demo data (walang server)', style: ts(12, w: FontWeight.w700)),
                subtitle: Text('Answers from the contract example files', style: ts(10, color: C.muted)),
              ),
            ),
            const SizedBox(height: 6),
            _field('Server address (laptop IP)', _url,
                hint: '192.168.43.100:8000',
                type: TextInputType.url,
                error: _urlError,
                enabled: !cfg.useMock,
                onSubmitted: (_) => _saveUrl()),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(onPressed: cfg.useMock ? null : _saveUrl, child: const Text('Save')),
              OutlinedButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering_rounded, size: 16),
                label: const Text('Test connection'),
              ),
            ]),
            if (_testResult != null) ...[
              const SizedBox(height: 8),
              Text(_testResult!, style: ts(11, w: FontWeight.w600, color: _testOk ? C.green : C.red)),
            ],
          ]),
        ),
        const SizedBox(height: 20),
        Text('HOUSEHOLD', style: ts(10, w: FontWeight.w700, color: C.muted, spacing: 0.5)),
        const SizedBox(height: 8),
        AsyncBody(
          value: household,
          onRetry: () => ref.invalidate(serverSettingsProvider),
          data: (s) => SCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _field('Pangalan', _name),
              _field('Meralco rate', _rate, type: const TextInputType.numberWithOptions(decimal: true), suffix: '₱/kWh'),
              _field('Battery size', _batt, type: const TextInputType.numberWithOptions(decimal: true), suffix: 'kWh'),
              Text('Device: ${s['device_id']}', style: ts(10, color: C.muted)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _saving ? null : _saveHousehold,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                child: Text(_saving ? 'Saving…' : 'Save household'),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
