// Settings: server address (the laptop's IP on the hotspot), mock toggle, "Test connection"
// (GET /api/health), and the server-side settings (rate, battery size, name).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/data_providers.dart';
import '../../providers/server_providers.dart';
import '../common/placeholder.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final _url = TextEditingController(text: ref.read(serverConfigProvider).baseUrl);
  String? _urlError;
  bool _testing = false;
  String? _testResult;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
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
    String result;
    try {
      final h = await ref.read(apiServiceProvider).health();
      result = h['ok'] == true
          ? 'Connected. LLM: ${h['llm'] ?? 'none'} (${h['llm_reachable'] == true ? 'reachable' : 'not reachable'})'
              '${h['mock'] == true ? ', server in mock mode' : ''}'
          : 'Server answered but not ok: $h';
    } catch (e) {
      result = 'Hindi ma-reach: $e';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(serverConfigProvider);
    final serverSettings = ref.watch(serverSettingsProvider);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: PlaceholderPage(children: [
        const PlaceholderBanner('Settings'),
        Text('Server', style: text.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          enabled: !cfg.useMock,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: 'Server address (laptop IP)',
            hintText: '192.168.43.100:8000',
            errorText: _urlError,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (_) => _saveUrl(),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(onPressed: cfg.useMock ? null : _saveUrl, child: const Text('Save')),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _testing ? null : _test,
            child: _testing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Test connection'),
          ),
        ]),
        if (_testResult != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_testResult!)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use mock data (no server)'),
          subtitle: const Text('Answers from the contract example files'),
          value: cfg.useMock,
          onChanged: (v) => ref.read(serverConfigProvider.notifier).setUseMock(v),
        ),
        const Divider(height: 32),
        Text('Household (from the server)', style: text.titleMedium),
        AsyncView(
          value: serverSettings,
          onRetry: () => ref.invalidate(serverSettingsProvider),
          data: (s) => JsonView(s),
        ),
      ]),
    );
  }
}
