import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/router.dart';
import 'core/theme/app_theme.dart';
import 'providers/appearance_providers.dart';
import 'providers/server_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    child: const SolarisApp(),
  ));
}

class SolarisApp extends ConsumerStatefulWidget {
  const SolarisApp({super.key});

  @override
  ConsumerState<SolarisApp> createState() => _SolarisAppState();
}

class _SolarisAppState extends ConsumerState<SolarisApp> {
  late final GoRouter _router = buildRouter();

  @override
  void initState() {
    super.initState();
    C.night = ref.read(nightProvider);
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  /// Night flipped: the colour tokens changed, but const widgets don't rebuild on their own, so every
  /// element is marked dirty once (state, scroll positions and routes are kept).
  void _repaintAll() {
    void dirty(Element e) {
      e.markNeedsBuild();
      e.visitChildren(dirty);
    }

    (context as Element).visitChildren(dirty);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(nightProvider, (_, night) {
      if (night == C.night) return;
      setState(() => C.night = night);
      _repaintAll();
    });
    return MaterialApp.router(
      title: 'Solaris',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.current(), // light unless Settings > Appearance says Dark, or Auto at night
      themeAnimationDuration: Duration.zero, // tokens switch at once; a lerp would mix old and new
      routerConfig: _router,
      builder: (context, child) => _MaxWidth(child: child ?? const SizedBox.shrink()),
    );
  }
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
