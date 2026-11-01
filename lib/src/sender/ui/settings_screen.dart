import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/format.dart';
import '../../shared/widgets.dart';
import '../data/sender_settings.dart';
import '../state/sender_providers.dart';
import 'home_screen.dart' show confirmForget;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(senderSettingsProvider);
    final notifier = ref.read(senderSettingsProvider.notifier);
    final info = ref.watch(deviceInfoProvider).value;
    final trusted = ref.watch(trustedMacsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          Section(
            title: 'Quality',
            child: Card(
              child: Column(
                children: [
                  for (final (index, preset) in QualityPreset.values.indexed) ...[
                    if (index > 0) const Divider(indent: 56),
                    _PresetTile(
                      preset: preset,
                      selected: settings.preset == preset,
                      onTap: () => notifier.change((s) => s.copyWith(preset: preset)),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (settings.preset == QualityPreset.custom) ...[
            const SizedBox(height: 16),
            _CustomProfileCard(settings: settings),
          ],
          const SizedBox(height: 28),
          Section(
            title: 'Video codec',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<CodecPreference>(
                  segments: const [
                    ButtonSegment(value: CodecPreference.auto, label: Text('Automatic')),
                    ButtonSegment(value: CodecPreference.avc, label: Text('H.264 only')),
                  ],
                  selected: {settings.codec},
                  onSelectionChanged: (s) => notifier.change((c) => c.copyWith(codec: s.first)),
                ),
                const SizedBox(height: 8),
                Text(
                  info == null
                      ? ''
                      : info.hevcEncoder
                      ? 'Automatic uses H.265 (sharper at the same bitrate) when your Mac supports it.'
                      : 'This phone has no hardware H.265 encoder, so H.264 is used.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Section(
            title: 'Audio',
            child: Card(
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Play sound on'),
                    trailing: SegmentedButton<AudioRoute>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: AudioRoute.mac, label: Text('Mac')),
                        ButtonSegment(value: AudioRoute.phone, label: Text('Phone')),
                      ],
                      selected: {settings.defaultAudioRoute},
                      onSelectionChanged: (s) => notifier.change((c) => c.copyWith(defaultAudioRoute: s.first)),
                    ),
                  ),
                  const Divider(indent: 16),
                  SwitchListTile(
                    title: const Text('Mute phone speaker'),
                    subtitle: const Text('While sound plays on the Mac'),
                    value: settings.mutePhoneSpeaker,
                    onChanged: (v) => notifier.change((c) => c.copyWith(mutePhoneSpeaker: v)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),
          Section(
            title: 'Paired Macs',
            child: Card(
              child: trusted.isEmpty
                  ? const ListTile(title: Text('No paired Macs'))
                  : Column(
                      children: [
                        for (final (index, mac) in trusted.indexed) ...[
                          if (index > 0) const Divider(indent: 16),
                          ListTile(
                            title: Text(mac.name),
                            subtitle: FingerprintText(mac.fingerprint),
                            trailing: TextButton(
                              onPressed: () async {
                                if (await confirmForget(context, mac.name)) {
                                  ref.read(trustedMacsProvider.notifier).forget(mac.fingerprint);
                                }
                              },
                              child: const Text('Forget'),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 28),
          Section(
            title: 'This phone',
            child: Card(
              child: Column(
                children: [
                  ListTile(title: const Text('Name'), trailing: Text(info?.deviceName ?? '…')),
                  const Divider(indent: 16),
                  ListTile(
                    title: const Text('Security fingerprint'),
                    subtitle: info == null ? null : FingerprintText(info.fingerprint, full: true),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'MirrorCast has no accounts and no cloud. Your screen goes straight to your Mac, '
            'encrypted with TLS 1.3, and nothing is stored.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({required this.preset, required this.selected, required this.onTap});

  final QualityPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: selected ? scheme.primary : scheme.outline,
      ),
      title: Text(preset.label),
      subtitle: Text(preset.description),
      selected: selected,
      onTap: onTap,
    );
  }
}

class _CustomProfileCard extends ConsumerWidget {
  const _CustomProfileCard({required this.settings});

  final SenderSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(senderSettingsProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: settings.customMaxSize,
              decoration: const InputDecoration(labelText: 'Resolution'),
              items: [
                for (final size in SenderSettings.maxSizeChoices)
                  DropdownMenuItem(value: size, child: Text(Format.resolution(size))),
              ],
              onChanged: (v) => notifier.change((s) => s.copyWith(customMaxSize: v)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: settings.customFps,
              decoration: const InputDecoration(labelText: 'Frame rate'),
              items: [
                for (final fps in SenderSettings.fpsChoices) DropdownMenuItem(value: fps, child: Text('$fps fps')),
              ],
              onChanged: (v) => notifier.change((s) => s.copyWith(customFps: v)),
            ),
            const SizedBox(height: 16),
            Text('Bitrate: ${settings.customBitrateMbps} Mbps'),
            Slider(
              value: settings.customBitrateMbps.toDouble(),
              min: SenderSettings.minBitrateMbps.toDouble(),
              max: SenderSettings.maxBitrateMbps.toDouble(),
              divisions: SenderSettings.maxBitrateMbps - SenderSettings.minBitrateMbps,
              label: '${settings.customBitrateMbps} Mbps',
              onChanged: (v) => notifier.change((s) => s.copyWith(customBitrateMbps: v.round())),
            ),
            Text(
              'Higher is sharper but needs a stronger Wi-Fi link. If the phone can\'t encode a '
              'setting, MirrorCast picks the closest one it supports.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
