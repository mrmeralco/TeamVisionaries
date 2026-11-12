// Settings: server address (the laptop's IP on the hotspot), mock toggle, "Test connection"
// (GET /api/health), appearance (auto / light / dark), the automatic Meralco rate (read-only, from the server),
// and the household settings (name, battery size, household setup) via PUT /api/settings.
// Household setup: solar (inverter) | meter_only (smart meter, no solar) | solar_and_meter. It decides where
// every number comes from, so saving a new one refreshes every tab.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/appearance_providers.dart';
import '../../core/utils/format.dart';
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
  final _batt = TextEditingController();
  Map<String, dynamic>? _loaded; // server settings the household fields were filled from
  String _setup = 'solar';

  static const setups = [
    ('solar', 'Solar + battery', 'Binabasa ang hybrid inverter: solar, battery, gamit at grid.'),
    ('meter_only', 'Smart meter only', 'Walang solar: binabasa ang smart meter o Meralco meter para sa gamit, bill at boltahe.'),
    ('solar_and_meter', 'Solar + smart meter', 'Pareho: ang inverter para sa solar at battery, ang meter para sa bill.'),
  ];
  String? _urlError;
  String? _nameError, _battError;
  bool _refreshingRate = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Home also uses household settings; fetch current rate provenance when this page opens.
    Future.microtask(() { if (mounted) ref.invalidate(serverSettingsProvider); });
  }

  @override
  void dispose() {
    for (final c in [_url, _name, _batt]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic> s) {
    if (identical(s, _loaded)) return;
    if (_loaded == null || _name.text == '${_loaded!['user_name'] ?? ''}') {
      _name.text = '${s['user_name'] ?? ''}';
    }
    if (_loaded == null || _batt.text == '${_loaded!['battery_kwh'] ?? ''}') {
      _batt.text = '${s['battery_kwh'] ?? ''}';
    }
    _loaded = s;
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
    final batt = double.tryParse(_batt.text.trim());
    // Say what's wrong instead of quietly ignoring a bad value.
    setState(() {
      _nameError = name.isEmpty ? 'Ilagay ang pangalan.' : null;
      // No battery in a meter-only home: its (hidden) field isn't checked.
      _battError = _setup != 'meter_only' && (batt == null || batt <= 0 || batt > 200)
          ? 'Numero mula 1 hanggang 200, hal. 10'
          : null;
    });
    if (_nameError != null || _battError != null) return;
    final changes = <String, dynamic>{
      if (name != s['user_name']) 'user_name': name,
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
      final f = friendlyError(e);
      messenger.showSnackBar(SnackBar(content: Text('Hindi na-save. ${f.title}${e is SettingsNotKept ? ' ${f.hint}' : ''}')));
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _refreshRate() async {
    setState(() => _refreshingRate = true);
    try {
      await ref.read(serverSettingsProvider.notifier).refreshRate();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Hindi ma-refresh ang rate. Nananatili ang huling naka-save na halaga.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _refreshingRate = false);
    }
  }

  Widget _meralcoRate(Map<String, dynamic> settings) {
    final info = mapOf(settings['meralco_rate']);
    final status = str(info['status'], 'unavailable');
    final available = status != 'unavailable';
    final rate = settings['rate_php_per_kwh'];
    final month = str(info['billing_month']);
    final source = str(info['source_url'], 'https://www.meralco.com.ph/');
    final fetched = intOrNull(info['fetched_at']);
    final period = RegExp(r'^20\d{2}-(0[1-9]|1[0-2])$').hasMatch(month)
        ? '${monthNameOf(month)} ${month.substring(0, 4)} billing' : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Meralco rate', style: ts(12, w: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(available && rate is num && rate.isFinite ? '₱${rate.toStringAsFixed(4)} / kWh' : 'Rate unavailable',
            style: ts(18, w: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(status == 'sample' ? 'Sample rate · mock data'
            : (available ? 'Latest published overall residential rate' : 'Automatic Meralco rate'),
            style: ts(11, color: C.label)),
        if (period != null) Text(period, style: ts(12, w: FontWeight.w600)),
        Text('200 kWh reference household. Actual bills depend on consumption and other charges.',
            style: ts(11, color: C.muted)),
        if (fetched != null) Text('Verified ${formatWhen(fetched)}', style: ts(11, color: C.muted)),
        if (status == 'cached')
          Text('Hindi ma-update ngayon. Ginagamit ang huling verified na rate.',
              style: ts(12, color: C.orangeText)),
        if (status == 'unavailable')
          Text('Wala pang verified na rate. Pansamantalang estimate ang ginagamit sa bill.',
              style: ts(12, color: C.orangeText)),
        Text('Source: Meralco', style: ts(11, color: C.label)),
        if (status != 'sample') Text('Checked automatically every 6 hours.', style: ts(11, color: C.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _refreshingRate || _saving ? null : _refreshRate,
            icon: _refreshingRate
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 16),
            label: Text(_refreshingRate ? 'Checking…' : 'Refresh rate'),
          ),
          TextButton(onPressed: () async {
            await Clipboard.setData(ClipboardData(text: source));
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Source link copied.')));
          }, child: const Text('Copy source link')),
        ]),
      ]),
    );
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
    final appearance = ref.watch(appearanceProvider);
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
                const SectionTitle('Appearance'),
                const SizedBox(height: S.x3),
                SCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final (a, label) in const [
                        (Appearance.auto, 'Auto'),
                        (Appearance.light, 'Light'),
                        (Appearance.dark, 'Dark'),
                      ])
                        ChoiceChip(
                          key: Key('appearance-${a.name}'),
                          label: Text(label),
                          selected: appearance == a,
                          onSelected: (_) => ref.read(appearanceProvider.notifier).set(a),
                        ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      switch (appearance) {
                        Appearance.auto => 'Madilim mula 6PM hanggang 6AM, kasabay ng bahay sa gabi.',
                        Appearance.light => 'Laging maliwanag.',
                        Appearance.dark => 'Laging madilim.',
                      },
                      style: ts(11, color: C.muted),
                    ),
                  ]),
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
                        _meralcoRate(s),
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
