import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/format.dart';
import '../../shared/theme.dart';
import '../../shared/widgets.dart';
import '../state/mirror_controller.dart';
import '../state/sender_providers.dart';

/// The live session: status, quality numbers, audio routing and Stop.
class StreamingScreen extends ConsumerWidget {
  const StreamingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = ref.watch(mirrorControllerProvider);
    final stats = state.stats;
    final live = state.phase == SenderPhase.streaming;

    final (statusText, statusColor) = switch (state.phase) {
      SenderPhase.streaming => ('Live', scheme.success),
      SenderPhase.reconnecting => ('Reconnecting…', scheme.warning),
      _ => ('Connecting…', scheme.primary),
    };

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Row(
              children: [
                StatusDot(color: statusColor, pulse: true),
                const SizedBox(width: 4),
                Text(
                  statusText,
                  style: theme.textTheme.labelLarge?.copyWith(color: statusColor, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (stats != null)
                  Text(
                    Format.duration(stats.uptime),
                    style: theme.textTheme.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              state.receiverName == null ? 'Mirroring' : 'Mirroring to\n${state.receiverName}',
              style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
            ),
            const SizedBox(height: 28),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: StatTile(
                            label: 'Latency',
                            value: stats?.latencyMs == null ? '—' : '${stats!.latencyMs!.round()} ms',
                            highlight: latencyColor(scheme, stats?.latencyMs),
                          ),
                        ),
                        Expanded(
                          child: StatTile(
                            label: 'Frames / s',
                            value: (stats?.receiverFps ?? stats?.sentFps)?.round().toString() ?? '—',
                          ),
                        ),
                        Expanded(
                          child: StatTile(
                            label: 'Bitrate',
                            value: stats == null ? '—' : Format.kbps(stats.bitrateKbps),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: StatTile(
                            label: 'Resolution',
                            value: state.width == 0 ? '—' : '${state.width}×${state.height}',
                          ),
                        ),
                        Expanded(
                          child: StatTile(label: 'Codec', value: Format.codec(state.codec)),
                        ),
                        Expanded(
                          child: StatTile(
                            label: 'Round trip',
                            value: stats?.rttMs == null ? '—' : '${stats!.rttMs!.round()} ms',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Section(
              title: 'Sound plays on',
              child: SegmentedButton<AudioRoute>(
                segments: const [
                  ButtonSegment(value: AudioRoute.mac, icon: Icon(Icons.laptop_mac_rounded), label: Text('Mac')),
                  ButtonSegment(value: AudioRoute.phone, icon: Icon(Icons.headphones_rounded), label: Text('Phone')),
                ],
                selected: {state.audioRoute},
                onSelectionChanged: live
                    ? (selection) =>
                          unawaited(ref.read(mirrorControllerProvider.notifier).setAudioRoute(selection.first))
                    : null,
              ),
            ),
            if (state.audioRoute == AudioRoute.mac) ...[const SizedBox(height: 8), const _MuteSwitch()],
            const SizedBox(height: 28),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.errorContainer,
                foregroundColor: scheme.onErrorContainer,
              ),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop mirroring'),
              onPressed: () => unawaited(ref.read(mirrorControllerProvider.notifier).stop()),
            ),
            const SizedBox(height: 16),
            Text(
              'You can leave MirrorCast; mirroring keeps running. Stop it any time from the notification.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _MuteSwitch extends ConsumerWidget {
  const _MuteSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mute = ref.watch(senderSettingsProvider.select((s) => s.mutePhoneSpeaker));
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: const Text('Mute phone speaker'),
      subtitle: const Text('Sound only on the Mac'),
      value: mute,
      onChanged: (value) {
        ref.read(senderSettingsProvider.notifier).change((s) => s.copyWith(mutePhoneSpeaker: value));
        unawaited(ref.read(mirrorControllerProvider.notifier).setAudioRoute(AudioRoute.mac));
      },
    );
  }
}
