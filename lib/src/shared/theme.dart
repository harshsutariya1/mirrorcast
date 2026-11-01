import 'package:dynamic_color/dynamic_color.dart';
import 'package:material_ui/material_ui.dart';

/// MirrorCast's visual language: native-feeling and minimal.
///
/// * Colours come from the OS (Material You on Android, the accent colour on
///   macOS) with an indigo fallback.
/// * Flat, outlined surfaces instead of shadows.
/// * Light and dark follow the system.
abstract final class AppTheme {
  static const fallbackSeed = Color(0xFF4F46E5); // indigo

  static ThemeData light(ColorScheme? dynamicScheme, {required bool desktop}) =>
      _build(dynamicScheme?.harmonized() ?? ColorScheme.fromSeed(seedColor: fallbackSeed), desktop: desktop);

  static ThemeData dark(ColorScheme? dynamicScheme, {required bool desktop}) => _build(
    dynamicScheme?.harmonized() ?? ColorScheme.fromSeed(seedColor: fallbackSeed, brightness: Brightness.dark),
    desktop: desktop,
  );

  static ThemeData _build(ColorScheme scheme, {required bool desktop}) {
    final radius = BorderRadius.circular(desktop ? 12 : 18);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        clipBehavior: Clip.antiAlias,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: radius),
        contentPadding: EdgeInsets.symmetric(horizontal: desktop ? 12 : 16),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: Size(64, desktop ? 36 : 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktop ? 8 : 16)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: Size(64, desktop ? 36 : 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktop ? 8 : 16)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(desktop ? 8 : 14), borderSide: BorderSide.none),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktop ? 8 : 14)),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(desktop ? 14 : 28)),
      ),
      bottomSheetTheme: BottomSheetThemeData(backgroundColor: scheme.surfaceContainerLow, showDragHandle: true),
    );
  }
}

/// Semantic colours for connection states, readable in light and dark.
extension StatusColors on ColorScheme {
  Color get success => brightness == Brightness.dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
  Color get warning => brightness == Brightness.dark ? const Color(0xFFFBBF24) : const Color(0xFFB45309);
}
