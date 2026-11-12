// Settings: server address (the laptop's IP on the hotspot), mock toggle, "Test connection"
// (GET /api/health), and the server-side settings (rate, battery size, name, household setup) via PUT /api/settings.
// Household setup: solar (inverter) | meter_only (smart meter, no solar) | solar_and_meter. It decides where
// every number comes from, so saving a new one refreshes every tab.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/data_providers.dart';
import '../../providers/notification_providers.dart';
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
  String _setup = 'solar';

  static const setups = [
    ('solar', 'Solar + battery', 'Binabasa ang hybrid inverter: solar, battery, gamit at grid.'),
    ('meter_only', 'Smart meter only', 'Walang solar: binabasa ang smart meter o Meralco meter para sa gamit, bill at boltahe.'),
    ('solar_and_meter', 'Solar + smart meter', 'Pareho: ang inverter para sa solar at battery, ang meter para sa bill.'),
  ];
  String? _urlError;
  String? _nameError, _rateError, _battError;
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
    _setup = setups.any((x) => x.$1 == s['setup']) ? s['setup'] as String : 'solar';
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
      // Plain words instead of the raw exception text.
      final f = friendlyError(e);
      _testOk = false;
      _testResult = '✗ ${f.title} ${f.hint}';
    }
    if (mounted) setState(() => _testing = false);
  }

  Future<void> _saveHousehold() async {
    final s = _loaded ?? const {};
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    final rate = double.tryParse(_rate.text.trim());
    final batt = double.tryParse(_batt.text.trim());
    // Say what's wrong instead of quietly ignoring a bad value.
    setState(() {
      _nameError = name.isEmpty ? 'Ilagay ang pangalan.' : null;
      _rateError = rate == null || rate <= 0 || rate > 100 ? 'Numero mula 1 hanggang 100, hal. 13.5' : null;
      // No battery in a meter-only home: its (hidden) field isn't checked.
      _battError = _setup != 'meter_only' && (batt == null || batt <= 0 || batt > 200)
          ? 'Numero mula 1 hanggang 200, hal. 10'
          : null;
    });
    if (_nameError != null || _rateError != null || _battError != null) return;
    final changes = <String, dynamic>{
      if (name != s['user_name']) 'user_name': name,
      if (rate != s['rate_php_per_kwh']) 'rate_php_per_kwh': rate,
      if (_setup != 'meter_only' && batt != s['battery_kwh']) 'battery_kwh': batt,
      if (_setup != (s['setup'] ?? 'solar')) 'setup': _setup,
    };
    if (changes.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Walang binago: pareho pa rin ang settings.')));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(serverSettingsProvider.notifier).save(changes);
      messenger.showSnackBar(const SnackBar(content: Text('Na-save ang settings.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Hindi na-save. ${friendlyError(e).title}')));
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _field(
    String label,
    TextEditingController c, {
    String? hint,
    TextInputType? type,
    String? suffix,
    String? error,
    bool enabled = true,
    ValueChanged<String>? onSubmitted,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ts(12, w: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          enabled: enabled,
          keyboardType: type,
          style: ts(14),
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            hintText: hint,
            suffixText: suffix,
            errorText: error,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(serverConfigProvider);
    final household = ref.watch(serverSettingsProvider);
    if (household.value != null) _fill(household.value!);

    final notify = ref.watch(notifyAlertsProvider);
    final notifier = ref.watch(systemNotifierProvider);

    // Figma "screen 06 - settings" language: back + link dot row, 26 px title, subtitle, outlined white cards.
    return Scaffold(
      backgroundColor: C.cream,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          const BackHeader('Settings', 'Server connection, alerts and your household.'),
          Padding(
            padding: const EdgeInsets.fromLTRB(S.gutter, S.x4, S.gutter, S.x6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionTitle('Server'),
                const SizedBox(height: S.x3),
                SCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Material(
                        type: MaterialType.transparency,
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: cfg.useMock,
                          onChanged: (v) => ref.read(serverConfigProvider.notifier).setUseMock(v),
                          title: Text('Demo data (no server)', style: ts(13, w: FontWeight.w700)),
                          subtitle: Text('Answers from the contract example files', style: ts(11, color: C.muted)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _field(
                        'Server address (laptop IP)',
                        _url,
                        hint: '192.168.43.100:8000',
                        type: TextInputType.url,
                        error: _urlError,
                        enabled: !cfg.useMock,
                        onSubmitted: (_) => _saveUrl(),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(onPressed: cfg.useMock ? null : _saveUrl, child: const Text('Save address')),
                          OutlinedButton.icon(
                            onPressed: _testing ? null : _test,
                            icon: _testing
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.wifi_tethering_rounded, size: 16),
                            label: const Text('Test connection'),
                          ),
                        ],
                      ),
                      if (_testResult != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _testResult!,
                          style: ts(12, w: FontWeight.w600, color: _testOk ? C.green : C.red),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: S.x6),
                const SectionTitle('Alerts'),
                const SizedBox(height: S.x3),
                SCard(
                  child: Material(
                    type: MaterialType.transparency,
                    child: SwitchListTile(
                      key: const Key('notify-switch'),
                      contentPadding: EdgeInsets.zero,
                      value: notify && notifier.permission == 'granted',
                      onChanged: notifier.supported
                          ? (v) async {
                              final messenger = ScaffoldMessenger.of(context);
                              final ok = await ref.read(notifyAlertsProvider.notifier).setEnabled(v);
                              if (v && !ok) {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Hindi pinayagan ng browser ang notifications. Buksan sa site settings.',
                                    ),
                                  ),
                                );
                              }
                            }
                          : null,
                      title: Text('Notify me about alerts', style: ts(13, w: FontWeight.w700)),
                      subtitle: Text(
                        notifier.supported
                            ? 'Brownout, fault, low battery: kahit nasa ibang tab ka.'
                            : 'Sa phone: makikita mo ang mga na-miss na alert pagbalik mo sa app.',
                        style: ts(11, color: C.muted),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: S.x6),
                const SectionTitle('Household'),
                const SizedBox(height: S.x3),
                AsyncBody(
                  value: household,
                  onRetry: () => ref.invalidate(serverSettingsProvider),
                  data: (s) => SCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Your setup', style: ts(12, w: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final (key, label, _) in setups)
                            ChoiceChip(
                              key: Key('setup-$key'),
                              label: Text(label),
                              selected: _setup == key,
                              onSelected: (_) => setState(() => _setup = key),
                            ),
                        ]),
                        const SizedBox(height: 6),
                        Text(setups.firstWhere((x) => x.$1 == _setup).$3, style: ts(11, color: C.muted)),
                        const SizedBox(height: 14),
                        _field('Name', _name, error: _nameError),
                        _field(
                          'Meralco rate',
                          _rate,
                          type: const TextInputType.numberWithOptions(decimal: true),
                          suffix: '₱/kWh',
                          error: _rateError,
                        ),
                        if (_setup != 'meter_only')
                          _field(
                            'Battery size',
                            _batt,
                            type: const TextInputType.numberWithOptions(decimal: true),
                            suffix: 'kWh',
                            error: _battError,
                          ),
                        Text('Device: ${s['device_id'] ?? '—'}', style: ts(11, color: C.muted)),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _saving ? null : _saveHousehold,
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(kMinTap)),
                          child: Text(_saving ? 'Saving…' : 'Save household'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
