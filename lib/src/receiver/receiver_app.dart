import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../shared/theme.dart';
import '../shared/widgets.dart';
import 'state/receiver_providers.dart';
import 'ui/pairing_dialog.dart';
import 'ui/ready_screen.dart';
import 'ui/viewer_screen.dart';

/// The macOS app: wait for a phone, then show its screen.
class ReceiverApp extends StatelessWidget {
  const ReceiverApp({super.key});

  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => MaterialApp(
        title: 'MirrorCast',
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(lightDynamic, desktop: true),
        darkTheme: AppTheme.dark(darkDynamic, desktop: true),
        home: const _MenuBar(child: _ReceiverShell()),
      ),
    );
  }
}

class _ReceiverShell extends ConsumerWidget {
  const _ReceiverShell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(receiverControllerProvider.select((s) => s.status));
    final streaming = ref.watch(receiverControllerProvider.select((s) => s.isStreaming));

    final Widget body = switch (status) {
      ReceiverStatus.starting => const Scaffold(body: Center(child: CircularProgressIndicator())),
      ReceiverStatus.failed => const _StartupError(),
      ReceiverStatus.ready when streaming => const ViewerScreen(key: ValueKey('viewer')),
      ReceiverStatus.ready => const ReadyScreen(key: ValueKey('ready')),
    };
    return AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: body);
  }
}

class _StartupError extends ConsumerWidget {
  const _StartupError();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(receiverControllerProvider.select((s) => s.error));
    return Scaffold(
      body: Center(
        child: HeroMessage(
          icon: Icons.error_outline_rounded,
          title: 'MirrorCast couldn\'t start',
          message: error ?? 'Unknown error.',
          action: FilledButton(
            onPressed: () => unawaited(ref.read(receiverControllerProvider.notifier).retry()),
            child: const Text('Try again'),
          ),
        ),
      ),
    );
  }
}

/// The native macOS menu bar, with keyboard shortcuts for every viewer action.
class _MenuBar extends ConsumerWidget {
  const _MenuBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(receiverControllerProvider);
    final controller = ref.read(receiverControllerProvider.notifier);
    final showStats = ref.watch(showStatsProvider);
    final streaming = state.isStreaming;

    return PlatformMenuBar(
      menus: [
        const PlatformMenu(
          label: 'MirrorCast',
          menus: [
            PlatformMenuItemGroup(members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)]),
            PlatformMenuItemGroup(
              members: [
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
              ],
            ),
            PlatformMenuItemGroup(members: [PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit)]),
          ],
        ),
        PlatformMenu(
          label: 'Phone',
          menus: [
            PlatformMenuItem(
              label: 'Pair New Phone…',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
              onSelected: streaming
                  ? null
                  : () => unawaited(showPairingDialog(ReceiverApp.navigatorKey.currentContext!)),
            ),
            PlatformMenuItem(
              label: 'Disconnect',
              shortcut: const SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true),
              onSelected: streaming ? () => unawaited(controller.disconnect()) : null,
            ),
          ],
        ),
        PlatformMenu(
          label: 'View',
          menus: [
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: showStats ? 'Hide Stats' : 'Show Stats',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyI, meta: true),
                  onSelected: () => ref.read(showStatsProvider.notifier).toggle(),
                ),
                PlatformMenuItem(
                  label: state.audio.muted ? 'Unmute Audio' : 'Mute Audio',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyM, meta: true, shift: true),
                  onSelected: streaming ? () => unawaited(controller.toggleMute()) : null,
                ),
              ],
            ),
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: state.window.alwaysOnTop ? 'Don\'t Keep on Top' : 'Keep on Top',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true, alt: true),
                  onSelected: () => unawaited(controller.toggleAlwaysOnTop()),
                ),
                PlatformMenuItem(
                  label: state.window.miniPlayer ? 'Exit Mini Player' : 'Mini Player',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyP, meta: true, alt: true),
                  onSelected: () => unawaited(controller.toggleMiniPlayer()),
                ),
                PlatformMenuItem(
                  label: state.window.fullScreen ? 'Exit Full Screen' : 'Enter Full Screen',
                  shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true, control: true),
                  onSelected: () => unawaited(controller.toggleFullScreen()),
                ),
              ],
            ),
          ],
        ),
        const PlatformMenu(
          label: 'Window',
          menus: [
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
            PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
          ],
        ),
      ],
      child: child,
    );
  }
}
