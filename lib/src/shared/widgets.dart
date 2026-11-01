import 'package:material_ui/material_ui.dart';

import 'format.dart';
import 'theme.dart';

/// A small coloured dot with an optional soft pulse, used for live status.
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.color, this.pulse = false, this.size = 10});

  final Color color;
  final bool pulse;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _controller.repeat();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulse && !_controller.isAnimating) _controller.repeat();
    if (!widget.pulse && _controller.isAnimating) _controller.stop();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return SizedBox.square(
      dimension: size * 2.2,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = widget.pulse ? _controller.value : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.pulse)
                Container(
                  width: size * (1 + t * 1.2),
                  height: size * (1 + t * 1.2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.35 * (1 - t)),
                  ),
                ),
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A titled group of content, like a section in iOS/macOS settings.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        child,
      ],
    );
  }
}

/// Monospace, grouped fingerprint, selectable so it can be compared or copied.
class FingerprintText extends StatelessWidget {
  const FingerprintText(this.fingerprint, {super.key, this.full = false});

  final String fingerprint;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = full
        ? RegExp('.{1,4}').allMatches(fingerprint.toUpperCase()).map((m) => m[0]).join(' ')
        : Format.shortFingerprint(fingerprint);
    return SelectableText(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: const ['Menlo', 'Roboto Mono', 'Courier'],
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.5,
      ),
    );
  }
}

/// Label + value pair for compact stats.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.highlight});

  final String label;
  final String value;
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: highlight ?? theme.colorScheme.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// Colour for a latency value: green when it feels instant, amber when it's
/// noticeable, red when it's laggy.
Color latencyColor(ColorScheme scheme, double? ms) {
  if (ms == null) return scheme.onSurfaceVariant;
  if (ms <= 50) return scheme.success;
  if (ms <= 100) return scheme.warning;
  return scheme.error;
}

/// A friendly empty/hero state with an icon, title and message.
class HeroMessage extends StatelessWidget {
  const HeroMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.showLogo = false,
  });

  final IconData icon;

  /// Shows the MirrorCast logo instead of [icon].
  final bool showLogo;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLogo)
          const AppLogo(size: 96)
        else
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(icon, size: 36, color: theme.colorScheme.onPrimaryContainer),
          ),
        const SizedBox(height: 20),
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
        if (action != null) ...[const SizedBox(height: 20), action!],
      ],
    );
  }
}

/// The MirrorCast logo (same artwork as the app icon; source in tool/brand/).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 32});

  static const asset = 'assets/brand/logo.png';

  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: 'MirrorCast logo',
    );
  }
}
