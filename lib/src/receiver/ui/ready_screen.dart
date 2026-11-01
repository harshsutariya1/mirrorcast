import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/format.dart';
import '../../shared/protocol.dart';
import '../../shared/theme.dart';
import '../../shared/widgets.dart';
import '../state/receiver_providers.dart';
import 'pairing_dialog.dart';

/// Shown while no phone is mirroring: how to connect, and who's trusted.
class ReadyScreen extends ConsumerStatefulWidget {
  const ReadyScreen({super.key});

  @override
  ConsumerState<ReadyScreen> createState() => _ReadyScreenState();
}

class _ReadyScreenState extends ConsumerState<ReadyScreen> {
  StreamSubscription<String>? _notices;

  @override
  void initState() {
    super.initState();
    _notices = ref.read(receiverControllerProvider.notifier).notices.listen((message) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void dispose() {
    unawaited(_notices?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(receiverControllerProvider);
    final info = state.info!;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth > 860;
            final cards = [
              _PairCard(onPair: () => unawaited(showPairingDialog(context))),
              _UsbCard(port: info.port),
              _DetailsCard(info: info, addresses: state.addresses),
            ];
            return ListView(
              padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
              children: [
                Center(
                  child: HeroMessage(
                    showLogo: true,
                    icon: Icons.cast_connected_rounded,
                    title: 'Ready to mirror',
                    message: 'Open MirrorCast on your Android phone and tap "${info.receiverName}".',
                  ),
                ),
                const SizedBox(height: 14),
                Center(child: _ListeningPill(port: info.port)),
                const SizedBox(height: 36),
                if (wide)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, card) in cards.indexed) ...[
                          if (index > 0) const SizedBox(width: 16),
                          Expanded(child: card),
                        ],
                      ],
                    ),
                  )
                else
                  for (final card in cards) ...[card, const SizedBox(height: 16)],
                const SizedBox(height: 32),
                Section(title: 'Trusted phones', child: const _TrustedPhonesCard()),
                const SizedBox(height: 20),
                Text(
                  'No accounts, no cloud: the stream goes directly from your phone to this Mac, encrypted with TLS 1.3.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ListeningPill extends StatelessWidget {
  const _ListeningPill({required this.port});

  final int port;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(100)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 14, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(color: scheme.success, pulse: true, size: 8),
            Text('Waiting for a phone', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 10),
            Icon(Icons.lock_rounded, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              'Secure · port $port',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.title, required this.children});

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _PairCard extends StatelessWidget {
  const _PairCard({required this.onPair});

  final VoidCallback onPair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _InfoCard(
      icon: Icons.add_link_rounded,
      title: 'New phone',
      children: [
        Text(
          'Pair once with a code or QR. After that, the phone connects with one tap.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: onPair,
          icon: const Icon(Icons.qr_code_2_rounded, size: 18),
          label: const Text('Pair new phone'),
        ),
        const SizedBox(height: 6),
        Text('⌘N', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }
}

class _UsbCard extends StatelessWidget {
  const _UsbCard({required this.port});

  final int port;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final command = MirrorProtocol.adbReverseCommand(port);
    return _InfoCard(
      icon: Icons.usb_rounded,
      title: 'USB (lowest latency)',
      children: [
        Text(
          'Enable USB debugging on the phone, plug it in, then run once in Terminal:',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        _CopyableCode(text: command),
        const SizedBox(height: 6),
        Text(
          'Then choose "USB cable" in the phone app.',
          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
        ),
      ],
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.info, required this.addresses});

  final ReceiverInfo info;
  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return _InfoCard(
      icon: Icons.lan_outlined,
      title: 'Connection details',
      children: [
        Text('Address (for manual connect or hotspot)', style: muted),
        const SizedBox(height: 4),
        if (addresses.isEmpty)
          Text('Not connected to a network', style: theme.textTheme.bodyMedium)
        else
          for (final address in addresses.take(3))
            SelectableText(
              '$address : ${info.port}',
              style: theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
        const SizedBox(height: 10),
        Text('This Mac\'s fingerprint', style: muted),
        const SizedBox(height: 2),
        FingerprintText(info.fingerprint),
        const SizedBox(height: 6),
        Text('Video: ${info.decoders.map(Format.codec).join(' · ')} hardware decoding', style: muted),
      ],
    );
  }
}

class _CopyableCode extends StatelessWidget {
  const _CopyableCode({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          unawaited(Clipboard.setData(ClipboardData(text: text)));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(text, style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
              ),
              Icon(Icons.copy_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrustedPhonesCard extends ConsumerWidget {
  const _TrustedPhonesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phones = ref.watch(trustedPhonesProvider);
    final theme = Theme.of(context);
    return Card(
      child: phones.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => ListTile(title: Text('Couldn\'t load trusted phones: $error')),
        data: (list) => list.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  'No phones yet. Pair one to get started.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            : Column(
                children: [
                  for (final (index, phone) in list.indexed) ...[
                    if (index > 0) const Divider(indent: 56),
                    _TrustedPhoneTile(phone: phone),
                  ],
                ],
              ),
      ),
    );
  }
}

class _TrustedPhoneTile extends ConsumerWidget {
  const _TrustedPhoneTile({required this.phone});

  final TrustedPhone phone;

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${phone.name}?'),
        content: const Text('It will be disconnected and must pair again before it can mirror.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await ref.read(trustedPhonesProvider.notifier).revoke(phone.fingerprint);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(Icons.smartphone_rounded, color: theme.colorScheme.onSurfaceVariant),
      title: Text(phone.name),
      subtitle: Row(
        children: [
          if (phone.model.isNotEmpty) ...[Text(phone.model), const Text('  ·  ')],
          Text('Last seen ${Format.relative(phone.lastSeenAt)}'),
          const Text('  ·  '),
          Flexible(child: FingerprintText(phone.fingerprint)),
        ],
      ),
      trailing: TextButton(
        style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
        onPressed: () => unawaited(_revoke(context, ref)),
        child: const Text('Remove'),
      ),
    );
  }
}
