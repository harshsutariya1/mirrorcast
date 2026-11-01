import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../shared/theme.dart';
import '../state/sender_providers.dart';

/// Opens the PIN pairing screen and, on success, remembers the Mac.
///
/// Everything needed afterwards is captured before the first `await`, so this
/// is safe to call from a bottom sheet that closes itself.
Future<void> openPinPairing(
  BuildContext context, {
  required String receiverName,
  required String host,
  required int port,
}) async {
  final finish = _PairingFinisher.of(context);
  final paired = await finish.navigator.push<PairedReceiver>(
    MaterialPageRoute(
      builder: (_) => PinPairingScreen(receiverName: receiverName, host: host, port: port),
    ),
  );
  finish(paired);
}

/// Opens the QR scanner and, on success, remembers the Mac.
Future<void> openQrPairing(BuildContext context) async {
  final finish = _PairingFinisher.of(context);
  final paired = await finish.navigator.push<PairedReceiver>(
    MaterialPageRoute(builder: (_) => const QrPairingScreen()),
  );
  finish(paired);
}

class _PairingFinisher {
  _PairingFinisher.of(BuildContext context)
    : navigator = Navigator.of(context),
      messenger = ScaffoldMessenger.of(context),
      container = ProviderScope.containerOf(context, listen: false);

  final NavigatorState navigator;
  final ScaffoldMessengerState messenger;
  final ProviderContainer container;

  void call(PairedReceiver? paired) {
    if (paired == null) return;
    container.read(trustedMacsProvider.notifier).addPaired(paired);
    messenger.showSnackBar(SnackBar(content: Text('Paired with ${paired.receiverName}. Tap Mirror to start.')));
  }
}

// ------------------------------------------------------------------ PIN

class PinPairingScreen extends ConsumerStatefulWidget {
  const PinPairingScreen({super.key, required this.receiverName, required this.host, required this.port});

  final String receiverName;
  final String host;
  final int port;

  @override
  ConsumerState<PinPairingScreen> createState() => _PinPairingScreenState();
}

class _PinPairingScreenState extends ConsumerState<PinPairingScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _controller.text;
    if (pin.length != 6 || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final device = await ref.read(deviceInfoProvider.future);
      final paired = await ref
          .read(senderEngineProvider)
          .pairWithPin(host: widget.host, port: widget.port, pin: pin, deviceName: device.deviceName);
      unawaited(HapticFeedback.mediumImpact());
      if (mounted) Navigator.of(context).pop(paired);
    } on EngineException catch (error) {
      unawaited(HapticFeedback.heavyImpact());
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
        _controller.clear();
      });
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Pair with code')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            Text(widget.receiverName, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'On your Mac, click "Pair new phone". Enter the 6-digit code it shows.',
              style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
            PinField(controller: _controller, focusNode: _focus, enabled: !_busy, onCompleted: (_) => _submit()),
            const SizedBox(height: 20),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: _busy
                  ? Row(
                      key: const ValueKey('busy'),
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Text('Verifying securely…', style: theme.textTheme.bodyMedium),
                      ],
                    )
                  : _error != null
                  ? Text(
                      _error!,
                      key: const ValueKey('error'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                    )
                  : const SizedBox(key: ValueKey('none'), height: 20),
            ),
            const SizedBox(height: 32),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.verified_user_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'The code is never sent over the network. Both devices prove they know it, '
                        'so nobody else on your Wi-Fi can pair or listen in.',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Six digit boxes backed by one invisible text field (works with paste,
/// autofill and screen readers).
class PinField extends StatefulWidget {
  const PinField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onCompleted,
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onCompleted;
  final bool enabled;

  @override
  State<PinField> createState() => _PinFieldState();
}

class _PinFieldState extends State<PinField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.focusNode.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    setState(() {});
    if (widget.controller.text.length == 6) widget.onCompleted(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = widget.controller.text;
    return GestureDetector(
      onTap: () => widget.focusNode.requestFocus(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: 0,
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              enabled: widget.enabled,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              showCursor: false,
              enableInteractiveSelection: false,
            ),
          ),
          Semantics(
            label: 'Pairing code, ${text.length} of 6 digits entered',
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i == 3) const SizedBox(width: 16),
                  _DigitBox(
                    digit: i < text.length ? text[i] : '',
                    active: widget.focusNode.hasFocus && i == text.length,
                    scheme: scheme,
                  ),
                  if (i != 2 && i != 5) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DigitBox extends StatelessWidget {
  const _DigitBox({required this.digit, required this.active, required this.scheme});

  final String digit;
  final bool active;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 46,
      height: 58,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: active ? scheme.primary : Colors.transparent, width: 2),
      ),
      child: Text(
        digit,
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

// ------------------------------------------------------------------- QR

class QrPairingScreen extends ConsumerStatefulWidget {
  const QrPairingScreen({super.key});

  @override
  ConsumerState<QrPairingScreen> createState() => _QrPairingScreenState();
}

class _QrPairingScreenState extends ConsumerState<QrPairingScreen> {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _busy = false;
  String? _message;
  String? _lastRejected;

  @override
  void dispose() {
    unawaited(_scanner.dispose());
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw == _lastRejected) continue;
      final link = PairingLink.tryParse(raw);
      if (link == null) {
        _lastRejected = raw;
        setState(() => _message = 'That isn\'t a MirrorCast pairing code.');
        continue;
      }
      await _pair(link);
      return;
    }
  }

  Future<void> _pair(PairingLink link) async {
    setState(() {
      _busy = true;
      _message = 'Pairing with ${link.receiverName}…';
    });
    unawaited(_scanner.stop());
    try {
      final device = await ref.read(deviceInfoProvider.future);
      final paired = await ref.read(senderEngineProvider).pairWithQr(link, deviceName: device.deviceName);
      unawaited(HapticFeedback.mediumImpact());
      if (mounted) Navigator.of(context).pop(paired);
    } on EngineException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = error.message;
      });
      unawaited(_scanner.start());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan pairing code'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _scanner, onDetect: _onDetect),
          const _ScannerFrame(),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Card(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (_busy)
                      const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      Icon(Icons.qr_code_2_rounded, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _message ?? 'On your Mac, click "Pair new phone" and point the camera at the QR code.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerFrame extends StatelessWidget {
  const _ScannerFrame();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.success;
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 250,
          height: 250,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: accent, width: 3),
            boxShadow: const [BoxShadow(color: Color(0x88000000), spreadRadius: 2000)],
          ),
        ),
      ),
    );
  }
}
