import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../shared/protocol.dart';
import '../state/mirror_controller.dart';
import '../state/sender_providers.dart';
import 'pairing_screens.dart';

/// USB mode: `adb reverse` maps the phone's `127.0.0.1:port` to the Mac.
Future<void> showUsbSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const _UsbSheet());

/// Manual mode: type the Mac's IP address (shown in the Mac app).
Future<void> showManualConnectSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const _ManualSheet());

class _UsbSheet extends ConsumerWidget {
  const _UsbSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trusted = ref.watch(trustedMacsProvider);
    const port = MirrorProtocol.defaultPort;
    final command = MirrorProtocol.adbReverseCommand(port);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Mirror over USB', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            const _Step(number: 1, text: 'Turn on USB debugging (Settings → Developer options).'),
            const _Step(number: 2, text: 'Connect the cable and run this once in the Mac\'s Terminal:'),
            Padding(
              padding: const EdgeInsets.only(left: 40, bottom: 12),
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    unawaited(Clipboard.setData(ClipboardData(text: command)));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Command copied')));
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(command, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                        ),
                        Icon(Icons.copy_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const _Step(number: 3, text: 'Tap Mirror (or Pair the first time).'),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.cast_rounded),
              label: const Text('Mirror over USB'),
              onPressed: trusted.isEmpty
                  ? null
                  : () {
                      final controller = ref.read(mirrorControllerProvider.notifier);
                      Navigator.pop(context);
                      unawaited(
                        controller.start(
                          MirrorTarget.usb(port: port, fingerprints: [for (final mac in trusted) mac.fingerprint]),
                        ),
                      );
                    },
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.pin_outlined),
              label: const Text('Pair over USB'),
              onPressed: () {
                final navigator = Navigator.of(context)..pop();
                unawaited(
                  openPinPairing(
                    navigator.context,
                    receiverName: 'Mac (USB)',
                    host: MirrorProtocol.usbHost,
                    port: port,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              '$number',
              style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(padding: const EdgeInsets.only(top: 4), child: Text(text)),
          ),
        ],
      ),
    );
  }
}

class _ManualSheet extends ConsumerStatefulWidget {
  const _ManualSheet();

  @override
  ConsumerState<_ManualSheet> createState() => _ManualSheetState();
}

class _ManualSheetState extends ConsumerState<_ManualSheet> {
  final _form = GlobalKey<FormState>();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '${MirrorProtocol.defaultPort}');

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  String? _validateHost(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Enter the Mac\'s IP address';
    if (InternetAddress.tryParse(text.split('%').first) == null) return 'Use an IP address like 192.168.1.20';
    return null;
  }

  String? _validatePort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    if (port == null || port < 1 || port > 65535) return 'Port must be between 1 and 65535';
    return null;
  }

  void _mirror() {
    if (!_form.currentState!.validate()) return;
    final trusted = ref.read(trustedMacsProvider);
    final controller = ref.read(mirrorControllerProvider.notifier);
    Navigator.pop(context);
    unawaited(
      controller.start(
        MirrorTarget(
          label: _host.text.trim(),
          hosts: [_host.text.trim()],
          port: int.parse(_port.text.trim()),
          fingerprints: [for (final mac in trusted) mac.fingerprint],
        ),
      ),
    );
  }

  void _pair() {
    if (!_form.currentState!.validate()) return;
    final host = _host.text.trim();
    final port = int.parse(_port.text.trim());
    final navigator = Navigator.of(context)..pop();
    unawaited(openPinPairing(navigator.context, receiverName: host, host: host, port: port));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasTrusted = ref.watch(trustedMacsProvider).isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Connect by address', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                  'The Mac app shows its address under "Connection details". This also works on a phone hotspot.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _host,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.20'),
                  validator: _validateHost,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Port'),
                  validator: _validatePort,
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: hasTrusted ? _mirror : null, child: const Text('Mirror')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _pair, child: const Text('Pair with this Mac')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
