import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../shared/format.dart';
import '../../shared/theme.dart';
import '../state/receiver_providers.dart';

/// Opens the pairing window on the engine and shows the PIN + QR code.
Future<void> showPairingDialog(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  unawaited(container.read(pairingControllerProvider.notifier).open());
  await showDialog<void>(context: context, builder: (_) => const _PairingDialog());
  await container.read(pairingControllerProvider.notifier).close();
}

class _PairingDialog extends ConsumerWidget {
  const _PairingDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(pairingControllerProvider);
    final addresses = ref.watch(receiverControllerProvider.select((s) => s.addresses));

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: switch (view.phase) {
              PairingPhase.paired => _Paired(deviceName: view.deviceName),
              PairingPhase.closed => _Closed(message: view.message),
              _ when view.credential == null => const SizedBox(
                height: 240,
                child: Center(child: CircularProgressIndicator()),
              ),
              _ => _Open(credential: view.credential!, message: view.message, addresses: addresses),
            },
          ),
        ),
      ),
    );
  }
}

class _Open extends StatelessWidget {
  const _Open({required this.credential, required this.message, required this.addresses});

  final PairingCredential credential;
  final String? message;
  final List<String> addresses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = PairingLink(
      receiverName: credential.receiverName,
      fingerprint: credential.fingerprint,
      secret: _decodeSecret(credential.secret),
      port: credential.port,
      addresses: addresses.isEmpty ? const ['127.0.0.1'] : addresses,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Pair a new phone', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          'In MirrorCast on your phone, tap this Mac and enter the code, or scan the QR code.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                children: [
                  Text(
                    'CODE',
                    style: theme.textTheme.labelMedium?.copyWith(
                      letterSpacing: 1.2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    Format.pin(credential.pin),
                    style: theme.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      letterSpacing: 4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 8),
                  _Countdown(expiresAt: credential.expiresAt),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
              child: QrImageView(
                data: link.toUri(),
                size: 196,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                semanticsLabel: 'Pairing QR code',
              ),
            ),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: 20),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Icon(Icons.verified_user_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Single-use code. It changes after any failed attempt.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ],
        ),
      ],
    );
  }

  static Uint8List _decodeSecret(String base64UrlSecret) => base64Url.decode(base64Url.normalize(base64UrlSecret));
}

class _Countdown extends StatefulWidget {
  const _Countdown({required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final Timer _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = widget.expiresAt.difference(DateTime.now());
    final seconds = remaining.inSeconds.clamp(0, 999);
    final theme = Theme.of(context);
    return Text(
      seconds > 0 ? 'Expires in ${Format.duration(Duration(seconds: seconds))}' : 'Expired',
      style: theme.textTheme.labelMedium?.copyWith(
        color: seconds < 20 ? theme.colorScheme.warning : theme.colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _Paired extends StatelessWidget {
  const _Paired({required this.deviceName});

  final String? deviceName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_rounded, size: 64, color: theme.colorScheme.success),
        const SizedBox(height: 16),
        Text(
          'Paired with ${deviceName ?? 'your phone'}',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Tap Mirror on the phone to start.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

class _Closed extends ConsumerWidget {
  const _Closed({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_off_outlined, size: 56, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(message ?? 'Pairing closed.', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => unawaited(ref.read(pairingControllerProvider.notifier).open()),
              child: const Text('New code'),
            ),
          ],
        ),
      ],
    );
  }
}
