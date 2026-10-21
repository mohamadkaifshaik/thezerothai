import 'package:flutter/material.dart';

/// Design tokens shared by every screen. Never hard-code a `Color(0x...)` or
/// a raw size outside this file — see the `reuse-first` skill.
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Minimum interactive target size for accessibility (48dp rule).
  static const double minTapTarget = 48;

  /// Minimum width of a short filled action button (an app-bar "Save").
  static const double minButtonWidth = 72;
}

/// Icon sizes (dp). Visuals sit inside a 48dp tap target.
abstract final class AppIconSize {
  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 40;
}

/// Opacity levels for tints over a surface.
abstract final class AppOpacity {
  /// Tint of a highlighted (for example unread) row: a hint, never the only
  /// signal.
  static const double rowTint = 0.08;

  /// Tint of the selected navigation destination (the rail's indicator): a
  /// soft indigo wash behind the icon; the label and icon carry the signal.
  static const double navSelected = 0.14;
}

/// Page-level layout widths (dp) of the desktop/web shell.
abstract final class AppLayout {
  /// Widest the main (feed) column grows; wider windows centre it between
  /// 1dp borders.
  static const double mainColumnMaxWidth = 640;

  /// Fixed width of the right-hand column shown from [AppBreakpoints.tablet].
  static const double sideColumnWidth = 320;

  /// Width of the extended navigation rail (labels visible).
  static const double railExtendedWidth = 256;

  /// Vertical padding around each rail destination. Flutter's destination is
  /// 44dp tall (32dp indicator plus 12dp spacing); 2 + 44 + 2 reaches the
  /// 48dp tap target.
  static const double railItemVerticalPadding = 2;
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;
}

/// Responsive layout breakpoints (matches the `flutter-feature` skill).
abstract final class AppBreakpoints {
  static const double mobile = 600;
  static const double tablet = 1200;
}

/// Brand seed color (indigo; founder decision 2026-10-21). Light mode derives
/// everything from it via Material 3's `ColorScheme.fromSeed`; dark mode
/// overlays the fixed palette below. The fidelity variant keeps the primary
/// close to the seed (the default tonal-spot variant would grey it to about
/// 0xFF4F5B92).
const Color _seedColor = Color(0xFF4263E8);

/// Light tertiary: a violet, so the primary-to-tertiary gradient of
/// `AppGradientButton` reads indigo to violet (the fidelity variant would
/// derive a brown). White text on it is >= 4.5:1.
const Color _lightTertiary = Color(0xFF6D4FD6);
const Color _lightOnTertiary = Color(0xFFFFFFFF);

/// Dark palette. The page is [_darkBackground]; surfaces layer lighter on top
/// of it (never pure black), text is soft off-white, secondary text muted,
/// borders barely lighter than the surface they sit on. Text colors are
/// >= 4.5:1 on the background.
const Color _darkBackground = Color(0xFF070A11);
const Color _darkSurfaceLow = Color(0xFF0C101A);
const Color _darkSurface = Color(0xFF101623);
const Color _darkSurfaceHigh = Color(0xFF151C2C);
const Color _darkSurfaceHighest = Color(0xFF1B2436);
const Color _darkTextPrimary = Color(0xFFEDF3FF);
const Color _darkTextSecondary = Color(0xFF8B98A5);
const Color _darkBorder = Color(0xFF212A3A);
const Color _darkAccent = Color(0xFF6A91FF);

/// Violet end of the primary-to-tertiary CTA gradient (dark).
const Color _darkTertiary = Color(0xFF9A7BFF);

ColorScheme _colorScheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: _seedColor,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  if (brightness == Brightness.light) {
    return base.copyWith(
      tertiary: _lightTertiary,
      onTertiary: _lightOnTertiary,
    );
  }
  return base.copyWith(
    surface: _darkBackground,
    surfaceDim: _darkBackground,
    surfaceBright: _darkSurfaceHighest,
    surfaceContainerLowest: _darkBackground,
    surfaceContainerLow: _darkSurfaceLow,
    surfaceContainer: _darkSurface,
    surfaceContainerHigh: _darkSurfaceHigh,
    surfaceContainerHighest: _darkSurfaceHighest,
    onSurface: _darkTextPrimary,
    onSurfaceVariant: _darkTextSecondary,
    outline: _darkTextSecondary,
    outlineVariant: _darkBorder,
    primary: _darkAccent,
    onPrimary: _darkBackground,
    tertiary: _darkTertiary,
    onTertiary: _darkBackground,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildAppTheme({required Brightness brightness}) {
  final colorScheme = _colorScheme(brightness);
  final text = ThemeData(brightness: brightness).textTheme;
  final textTheme = text
      .copyWith(
        // Post body and composer text: comfortable reading rhythm.
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.35),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.35),
        // Display names, section titles.
        titleSmall: text.titleSmall?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      )
      .apply(
        bodyColor: colorScheme.onSurface,
        displayColor: colorScheme.onSurface,
      );
  final pillShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.pill),
  );
  final border = BorderSide(color: colorScheme.outlineVariant);
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    brightness: brightness,
    textTheme: textTheme,
    scaffoldBackgroundColor: colorScheme.surface,
    canvasColor: colorScheme.surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    dividerTheme: DividerThemeData(
      color: colorScheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colorScheme.surface,
      foregroundColor: colorScheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge,
      shape: Border(bottom: border),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
        shape: pillShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
        shape: pillShape,
        side: BorderSide(color: colorScheme.outline),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(
          AppSpacing.minTapTarget,
          AppSpacing.minTapTarget,
        ),
        shape: pillShape,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      shape: const CircleBorder(),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: border,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: border,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 56,
      indicatorColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
    ).copyWith(backgroundColor: colorScheme.surface),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colorScheme.surface,
      // Indigo wash behind the selected item. The icon turns primary (3:1 is
      // enough for an icon); the label stays onSurface so its contrast does
      // not depend on the wash (AA in light and dark).
      useIndicator: true,
      indicatorColor: colorScheme.primary.withValues(
        alpha: AppOpacity.navSelected,
      ),
      indicatorShape: const StadiumBorder(),
      minExtendedWidth: AppLayout.railExtendedWidth,
      selectedIconTheme: IconThemeData(color: colorScheme.primary),
      unselectedIconTheme: IconThemeData(color: colorScheme.onSurfaceVariant),
      selectedLabelTextStyle: textTheme.titleSmall?.copyWith(
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w800,
      ),
      unselectedLabelTextStyle: textTheme.titleSmall?.copyWith(
        color: colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: border,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colorScheme.surfaceContainerHighest,
      // M3 defaults assume an inverse-surface snackbar; on this surface they fail WCAG AA (F4 M1).
      actionTextColor: colorScheme.primary,
      closeIconColor: colorScheme.onSurfaceVariant,
      contentTextStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colorScheme.primary,
    ),
  );
}

ThemeData get appLightTheme => buildAppTheme(brightness: Brightness.light);
ThemeData get appDarkTheme => buildAppTheme(brightness: Brightness.dark);
