import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'providers/server_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: const SolarisApp(),
  ));
}

class SolarisApp extends StatefulWidget {
  const SolarisApp({super.key});

  @override
  State<SolarisApp> createState() => _SolarisAppState();
}

class _SolarisAppState extends State<SolarisApp> {
  late final GoRouter _router = buildRouter();

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
        title: 'Solaris',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(), // Figma design is light-only
        routerConfig: _router,
        builder: (context, child) => _MaxWidth(child: child ?? const SizedBox.shrink()),
      );
}

/// On tablets and laptops (the app also builds for web) lay the phone design out at most
/// [kMaxAppWidth] wide, centred, instead of stretching every card edge to edge. MediaQuery's size is
/// narrowed too, so screens that size things from it (header art, chat bubbles) follow.
class _MaxWidth extends StatelessWidget {
  const _MaxWidth({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (mq.size.width <= kMaxAppWidth + 40) return child;
    return ColoredBox(
      color: C.backdrop,
      child: Center(
        child: SizedBox(
          width: kMaxAppWidth,
          child: MediaQuery(
            data: mq.copyWith(size: Size(kMaxAppWidth, mq.size.height)),
            child: ClipRect(child: child),
          ),
        ),
      ),
    );
  }
}
