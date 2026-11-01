import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../shared/theme.dart';
import 'state/mirror_controller.dart';
import 'ui/home_screen.dart';
import 'ui/streaming_screen.dart';

/// The Android app: pick a Mac, mirror to it.
class SenderApp extends StatelessWidget {
  const SenderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        title: 'MirrorCast',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(lightDynamic, desktop: false),
        darkTheme: AppTheme.dark(darkDynamic, desktop: false),
        home: const _SenderShell(),
      ),
    );
  }
}

/// Shows the live session while mirroring, the home screen otherwise.
class _SenderShell extends ConsumerWidget {
  const _SenderShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(mirrorControllerProvider.select((s) => s.isActive));
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: active ? const StreamingScreen(key: ValueKey('streaming')) : const HomeScreen(key: ValueKey('home')),
    );
  }
}
