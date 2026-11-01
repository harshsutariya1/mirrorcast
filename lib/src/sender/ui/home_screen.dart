import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mirrorcast_engine/mirrorcast_engine.dart';

import '../../shared/format.dart';
import '../../shared/theme.dart';
import '../../shared/widgets.dart';
import '../data/discovery.dart';
import '../data/trusted_mac.dart';
import '../state/mirror_controller.dart';
import '../state/sender_providers.dart';
import 'connect_sheets.dart';
import 'pairing_screens.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  StreamSubscription<String>? _warnings;

  @override
  void initState() {
    super.initState();
    _warnings = ref.read(mirrorControllerProvider.notifier).warnings.listen(_showMessage);
  }

  @override
  void dispose() {
    unawaited(_warnings?.cancel());
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final trusted = ref.watch(trustedMacsProvider);
    final nearby = ref.watch(nearbyMacsProvider);
    final mirror = ref.watch(mirrorControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [AppLogo(size: 30), SizedBox(width: 10), Text('MirrorCast')]),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(discoveryProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            if (mirror.phase == SenderPhase.error && mirror.error != null) ...[
              _ErrorBanner(error: mirror.error!),
              const SizedBox(height: 20),
            ],
            if (mirror.requesting) ...[
              const _InfoBanner(icon: Icons.screen_share_outlined, text: 'Allow screen capture to start mirroring…'),
              const SizedBox(height: 20),
            ],
            Section(
              title: 'Your Macs',
              child: trusted.isEmpty
                  ? const _EmptyCard(
                      icon: Icons.laptop_mac_rounded,
                      text: 'No paired Macs yet. Open MirrorCast on your Mac, then pair below.',
                    )
                  : Card(
                      child: Column(
                        children: [
                          for (final (index, mac) in trusted.indexed) ...[
                            if (index > 0) const Divider(indent: 72),
                            _TrustedMacTile(mac: mac, discovered: nearby.paired[mac.fingerprint]),
                          ],
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 28),
            Section(
              title: 'Nearby',
              trailing: const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              child: nearby.unpaired.isEmpty
                  ? const _EmptyCard(
                      icon: Icons.wifi_find_rounded,
                      text: 'Looking for Macs running MirrorCast on this Wi-Fi…',
                    )
                  : Card(
                      child: Column(
                        children: [
                          for (final (index, mac) in nearby.unpaired.indexed) ...[
                            if (index > 0) const Divider(indent: 72),
                            _NearbyMacTile(mac: mac),
                          ],
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 28),
            Section(
              title: 'Other ways to connect',
              child: Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const _TileIcon(Icons.qr_code_scanner_rounded),
                      title: const Text('Scan pairing QR code'),
                      subtitle: const Text('Fastest way to pair a new Mac'),
                      onTap: () => openQrPairing(context),
                    ),
                    const Divider(indent: 72),
                    ListTile(
                      leading: const _TileIcon(Icons.usb_rounded),
                      title: const Text('USB cable'),
                      subtitle: const Text('Lowest latency, no Wi-Fi needed'),
                      onTap: () => showUsbSheet(context),
                    ),
                    const Divider(indent: 72),
                    ListTile(
                      leading: const _TileIcon(Icons.edit_location_alt_outlined),
                      title: const Text('Enter address'),
                      subtitle: const Text('When the Mac doesn\'t show up automatically'),
                      onTap: () => showManualConnectSheet(context),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            const _PrivacyFooter(),
          ],
        ),
      ),
    );
  }
}

class _TrustedMacTile extends ConsumerWidget {
  const _TrustedMacTile({required this.mac, required this.discovered});

  final TrustedMac mac;
  final DiscoveredMac? discovered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final online = discovered?.isResolved ?? false;
    final busy = ref.watch(mirrorControllerProvider.select((s) => s.requesting));

    void mirror() {
      final hosts = {...?discovered?.hosts, if (mac.lastHost.isNotEmpty) mac.lastHost}.toList();
      unawaited(
        ref
            .read(mirrorControllerProvider.notifier)
            .start(
              MirrorTarget(
                label: mac.name,
                hosts: hosts,
                port: online ? discovered!.port : mac.port,
                fingerprints: [mac.fingerprint],
              ),
            ),
      );
    }

    return ListTile(
      leading: const _TileIcon(Icons.laptop_mac_rounded),
      title: Text(mac.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          StatusDot(color: online ? scheme.success : scheme.outline, size: 7, pulse: online),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              online ? 'Available' : 'Not found nearby · ${Format.relative(mac.lastConnectedAt ?? mac.pairedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonal(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            onPressed: busy || (!online && mac.lastHost.isEmpty) ? null : mirror,
            child: const Text('Mirror'),
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (value) async {
              switch (value) {
                case 'forget':
                  final confirmed = await confirmForget(context, mac.name);
                  if (confirmed) ref.read(trustedMacsProvider.notifier).forget(mac.fingerprint);
              }
            },
            itemBuilder: (_) => const [PopupMenuItem(value: 'forget', child: Text('Forget this Mac'))],
          ),
        ],
      ),
      onTap: busy || (!online && mac.lastHost.isEmpty) ? null : mirror,
    );
  }
}

class _NearbyMacTile extends ConsumerWidget {
  const _NearbyMacTile({required this.mac});

  final DiscoveredMac mac;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const _TileIcon(Icons.laptop_mac_outlined),
      title: Text(mac.serviceName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(mac.isResolved ? 'Not paired · tap to pair' : 'Resolving…'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: mac.isResolved
          ? () => openPinPairing(context, receiverName: mac.serviceName, host: mac.hosts.first, port: mac.port)
          : null,
    );
  }
}

Future<bool> confirmForget(BuildContext context, String name) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Forget $name?'),
      content: const Text('You\'ll need to pair again to mirror to this Mac.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
      ],
    ),
  );
  return result ?? false;
}

class _TileIcon extends StatelessWidget {
  const _TileIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(12)),
      child: Icon(icon, color: scheme.onSecondaryContainer, size: 22),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: ListTile(
        leading: Icon(icon, color: scheme.onPrimaryContainer),
        title: Text(text, style: TextStyle(color: scheme.onPrimaryContainer)),
      ),
    );
  }
}

class _ErrorBanner extends ConsumerWidget {
  const _ErrorBanner({required this.error});

  final EngineException error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(error.message, style: TextStyle(color: scheme.onErrorContainer)),
            ),
            IconButton(
              tooltip: 'Dismiss',
              icon: Icon(Icons.close_rounded, color: scheme.onErrorContainer),
              onPressed: () => ref.read(mirrorControllerProvider.notifier).dismissError(),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyFooter extends ConsumerWidget {
  const _PrivacyFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final info = ref.watch(deviceInfoProvider).value;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              'End-to-end encrypted · stays on your network',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        if (info != null) ...[
          const SizedBox(height: 6),
          Text(
            '${info.deviceName} · ${Format.shortFingerprint(info.fingerprint)}',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ],
    );
  }
}
