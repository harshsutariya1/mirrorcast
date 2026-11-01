import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../shared/format.dart';
import '../../shared/theme.dart';
import '../../shared/widgets.dart';
import '../state/receiver_providers.dart';

/// Full-window view of the phone's screen.
///
/// The picture is a Flutter `Texture` backed directly by VideoToolbox's
/// GPU buffers. Controls fade in when the mouse moves and hide after a moment.
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key});

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(receiverControllerProvider);
    final controller = ref.read(receiverControllerProvider.notifier);
    final showStats = ref.watch(showStatsProvider);
    final video = state.video;
    final textureId = state.info?.textureId ?? -1;
    final aspect = (video != null && video.width > 0 && video.height > 0) ? video.width / video.height : 9 / 19.5;
    final hasPicture = (state.stats?.fps ?? 0) > 0;
    final mini = state.window.miniPlayer;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (state.window.fullScreen) unawaited(controller.toggleFullScreen());
          if (state.window.miniPlayer) unawaited(controller.toggleMiniPlayer());
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: MouseRegion(
            onHover: (_) => _showControls(),
            onExit: (_) => setState(() => _controlsVisible = false),
            cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
            child: GestureDetector(
              onDoubleTap: () => unawaited(controller.toggleFullScreen()),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: textureId >= 0
                          ? Texture(textureId: textureId, filterQuality: FilterQuality.medium)
                          : const SizedBox.shrink(),
                    ),
                  ),
                  if (!hasPicture) const _WaitingForVideo(),
                  if (showStats && !mini)
                    Positioned(left: 16, top: 16 + (state.window.fullScreen ? 0 : 28), child: const _StatsOverlay()),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: IgnorePointer(
                      ignoring: !_controlsVisible,
                      child: AnimatedOpacity(
                        opacity: _controlsVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: _Toolbar(compact: mini),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaitingForVideo extends StatelessWidget {
  const _WaitingForVideo();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white70)),
          SizedBox(height: 14),
          Text('Waiting for video…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }
}

/// Translucent top bar with the viewer controls.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(receiverControllerProvider);
    final controller = ref.read(receiverControllerProvider.notifier);
    final showStats = ref.watch(showStatsProvider);
    final stream = state.stream;
    final window = state.window;

    Widget button(IconData icon, String tooltip, VoidCallback onPressed, {bool active = false}) => IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      color: active ? Theme.of(context).colorScheme.inversePrimary : Colors.white,
      style: IconButton.styleFrom(backgroundColor: active ? Colors.white.withValues(alpha: 0.18) : Colors.transparent),
    );

    return Container(
      // Leave room for the traffic-light buttons when not in full screen.
      padding: EdgeInsets.fromLTRB(window.fullScreen ? 16 : 80, 6, 10, 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          if (!compact && stream != null) ...[
            StatusDot(color: Theme.of(context).colorScheme.success, pulse: true, size: 8),
            Flexible(
              child: Text(
                stream.deviceName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const Spacer(),
          if (!compact) ...[
            button(
              Icons.insights_rounded,
              'Stats (⌘I)',
              () => ref.read(showStatsProvider.notifier).toggle(),
              active: showStats,
            ),
            if (state.audio.enabled)
              button(
                state.audio.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                state.audio.muted ? 'Unmute (⇧⌘M)' : 'Mute (⇧⌘M)',
                () => unawaited(controller.toggleMute()),
              ),
            button(
              Icons.push_pin_outlined,
              'Keep on top (⌥⌘T)',
              () => unawaited(controller.toggleAlwaysOnTop()),
              active: window.alwaysOnTop,
            ),
          ],
          button(
            window.miniPlayer ? Icons.open_in_full_rounded : Icons.picture_in_picture_alt_rounded,
            window.miniPlayer ? 'Exit mini player (⌥⌘P)' : 'Mini player (⌥⌘P)',
            () => unawaited(controller.toggleMiniPlayer()),
          ),
          if (!compact)
            button(
              window.fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              'Full screen (⌃⌘F)',
              () => unawaited(controller.toggleFullScreen()),
            ),
          button(Icons.close_rounded, 'Disconnect (⇧⌘D)', () => unawaited(controller.disconnect())),
        ],
      ),
    );
  }
}

/// Live numbers: what you'd check if something feels slow.
class _StatsOverlay extends ConsumerWidget {
  const _StatsOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(receiverControllerProvider);
    final stats = state.stats;
    final video = state.video;
    String ms(double? value) => value == null ? '—' : '${value.toStringAsFixed(0)} ms';
    final rows = <(String, String, Color?)>[
      (
        'Latency',
        ms(stats?.latencyMs),
        stats?.latencyMs == null ? null : latencyColor(_overlayScheme, stats!.latencyMs),
      ),
      ('FPS', stats == null ? '—' : stats.fps.toStringAsFixed(0), null),
      ('Bitrate', stats == null ? '—' : Format.kbps(stats.bitrateKbps), null),
      ('Round trip', ms(stats?.rttMs), null),
      ('Video', video == null ? '—' : '${video.width}×${video.height} ${Format.codec(video.codec)}', null),
      if (state.audio.enabled) ('Audio buffer', '${stats?.audioBufferMs ?? 0} ms', null),
      if ((stats?.decodeErrors ?? 0) > 0) ('Recovered errors', '${stats!.decodeErrors}', null),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(color: const Color(0xB3000000), borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: DefaultTextStyle(
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'Menlo',
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, value, color) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 112,
                        child: Text(label, style: const TextStyle(color: Colors.white60)),
                      ),
                      Text(value, style: TextStyle(color: color ?? Colors.white)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The overlay is always dark, so always use the dark-mode status colours.
  static final _overlayScheme = ColorScheme.fromSeed(seedColor: AppTheme.fallbackSeed, brightness: Brightness.dark);
}
