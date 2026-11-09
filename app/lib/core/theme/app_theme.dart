import 'package:flutter/material.dart';

/// Design tokens shared by every screen. Never hard-code a `Color(0x...)` or
/// a raw size outside this file.
///
/// The colour system follows the founder decision of 2026-10-22: match X's
/// colouring (dark and light), no indigo seed and no gradient. Sizes are dp
/// (X's CSS px; the research scale was verified at 1.25). The evidence is in
/// the X reference captures (`02_ui_design_tokens.md`, `10_light_dark_theme.md`).
abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;

  /// The 12dp step X uses for card top padding and several gaps.
  static const double smd = 12;
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
  /// Verified badge, small inline glyphs.
  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 40;

  /// The post action row glyph (the 48dp tap target around it is kept).
  static const double action = 16;
}

/// The opened post on its post page (x.com post detail, captured 2026-11-02):
/// text 17dp on a 24dp line (measured); action glyphs a step above the list
/// rows (estimated from the screenshot).
abstract final class AppFocalPost {
  static const double bodySize = 17;
  static const double bodyLineHeight = 24;
  static const double actionIcon = 20;
}

/// Opacity levels for tints over a surface.
abstract final class AppOpacity {
  /// Tint of a highlighted (for example unread) row: a hint, never the only
  /// signal.
  static const double rowTint = 0.08;

  /// Fill of the leading result bar of a poll (accent over the surface); the
  /// other bars use the border colour. Text over it keeps AA in both themes.
  static const double pollLeadingBar = 0.35;
}

/// Page-level layout widths (dp) of the desktop/web shell.
abstract final class AppLayout {
  /// Widest the main (feed) column grows; wider windows centre it between
  /// 1dp borders.
  static const double mainColumnMaxWidth = AppSize.contentMax;

  /// Fixed width of the right-hand column shown from [AppBreakpoints.tablet].
  static const double sideColumnWidth = AppSize.sideColumn;
}

abstract final class AppRadius {
  /// Legacy, migrate in sections.
  static const double sm = 8;

  /// Legacy, migrate in sections.
  static const double md = 12;

  /// Legacy, migrate in sections.
  static const double lg = 16;

  /// Legacy, migrate in sections.
  static const double pill = 999;

  // Redesign tokens (ADR-0033).
  static const double card = 24;
  static const double cardSmall = 20;
  static const double field = 16;
  static const double tile = 14;
  static const double bubble = 22;
  static const double bubbleTail = 6;
  static const double sheetTop = 32;
}

/// Responsive layout breakpoints.
abstract final class AppBreakpoints {
  static const double mobile = 600;
  static const double tablet = 1200;
}

/// Sizes of the shared chrome (dp), measured on x.com 2026-10-22 and divided
/// by the verified 1.25 display scale.
abstract final class AppSize {
  /// One row of a header: the top bar row, and the tab row below it.
  static const double headerRow = 53;

  /// Thickness of the active-tab bar (it is as wide as the label).
  static const double tabIndicator = 4;

  /// Horizontal padding on each side of a content-sized tab label: the label
  /// gap is 2x this (X: about 43dp on phones, 61dp on wide screens).
  static const double tabPaddingNarrow = 22;
  static const double tabPaddingWide = 30;

  /// Bottom navigation bar height (X: 54; ours keeps the 56dp M3 height).
  static const double bottomNav = 56;

  /// Pitch of the items of the left navigation rail.
  static const double navRailItem = 50;

  /// Rows of the avatar drawer and of the Settings list.
  static const double drawerRow = 56;
  static const double settingsRow = 48;

  /// Chat / Lists style rows (48dp avatar or thumbnail).
  static const double listRow = 72;

  /// The feed column never grows wider than this on wide screens.
  static const double contentMax = 600;

  /// The side column (cards: who to follow, trends) on wide screens.
  static const double sideColumn = 350;

  /// Width of the avatar drawer (capped at 85 % of the screen).
  static const double drawerWidth = 277;

  /// Avatars.
  static const double avatarSm = 32;
  static const double avatarMd = 40;
  static const double avatarProfileWide = 133;
  static const double avatarProfileNarrow = 88;

  /// Visual heights of compact pills (the 48dp tap target stays around them).
  static const double pillCompact = 36;
  static const double pillSmall = 32;

  /// The wide-layout "Post" pill in the navigation rail (X: 233 x 52).
  static const double railPostWidth = 233;
  static const double railPostHeight = 52;

  /// Mobile floating compose button.
  static const double fab = 56;

  // Redesign tokens (ADR-0033). `bottomNav` and `fab` switch in phase 3.
  static const double buttonHeight = 52;
  static const double buttonHeightLarge = 56;
  static const double floatingNavHeight = 66;
  static const double floatingNavInset = 20;
  static const double floatingNavBottom = 24;
  static const double fabRedesign = 58;
  static const double avatarRow = 44;
  static const double avatarPost = 42;
  static const double avatarLg = 56;
  static const double avatarXl = 120;
}

// --- Palette (X, dark) -----------------------------------------------------
const Color _darkBackground = Color(0xFF000000);
const Color _darkSurfaceLow = Color(0xFF080808);
const Color _darkSurface = Color(0xFF141414);
const Color _darkSurfaceHigh = Color(0xFF1D1D1D);
const Color _darkSurfaceHighest = Color(0xFF262626);
const Color _darkTextPrimary = Color(0xFFE7E9EA);
const Color _darkTextSecondary = Color(0xFF71767B);
const Color _darkBorder = Color(0xFF2F3336);
const Color _darkOutline = Color(0xFF333639);

// --- Palette (X, light) ----------------------------------------------------
const Color _lightBackground = Color(0xFFFFFFFF);
const Color _lightSurfaceLow = Color(0xFFFAFAFA);
const Color _lightSurface = Color(0xFFF7F9F9);
const Color _lightSurfaceHigh = Color(0xFFF2F2F2);
const Color _lightSurfaceHighest = Color(0xFFEBEBEB);
const Color _lightTextPrimary = Color(0xFF0F1419);
const Color _lightTextSecondary = Color(0xFF536471);
const Color _lightBorder = Color(0xFFEFF3F4);
const Color _lightOutline = Color(0xFFCFD9DE);

/// The one accent, identical in both themes (tab bar, links, badge, unread
/// dot, FAB).
const Color _accent = Color(0xFF1D9BF0);

/// Small accent *text* on white fails 4.5:1 with [_accent] (3.00:1); this
/// darker blue (4.72:1) is used for links and hashtags in the light theme
/// (decision D1 of the W0 plan). Icons, fills and the
/// tab bar keep [_accent].
const Color _lightAccentText = Color(0xFF1478BD);

/// Semantic colours shared by both themes (X: like heart, repost arrows, live).
const Color _like = Color(0xFFF91880);
const Color _repost = Color(0xFF00BA7C);
const Color _live = Color(0xFFF91880);
const Color _recommendation = Color(0xFF794BC4);

/// Semantic colours that the Material [ColorScheme] has no slot for.
///
/// Read them with `context.appColors`. Everything here is a *state* or
/// *role* colour, never a brand colour (there is no brand gradient).
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.like,
    required this.repost,
    required this.live,
    required this.recommendation,
    required this.positive,
    required this.accentText,
    required this.secondaryOnRaised,
    required this.strongPillFill,
    required this.strongPillLabel,
    required this.disabledPillFill,
    required this.disabledPillLabel,
    required this.selectedRow,
    required this.scrim,
  });

  /// Like heart and liked state.
  final Color like;

  /// Repost icon and reposted state.
  final Color repost;

  /// Live broadcast indicator.
  final Color live;

  /// Recommendation / assistant notification icon.
  final Color recommendation;

  /// A positive status (available handle): the repost green.
  final Color positive;

  /// Colour for small accent *text* (links, hashtags, "Show more"). Equal to
  /// the accent in dark; a darker blue in light so it passes 4.5:1.
  final Color accentText;

  /// Secondary text on a raised surface (cards with a fill). Dark
  /// `onSurfaceVariant` drops below 4.5:1 on those steps; this does not.
  final Color secondaryOnRaised;

  /// The strong (inverse) pill: light fill on dark, dark fill on light.
  final Color strongPillFill;
  final Color strongPillLabel;

  /// A disabled pill: flat, same shape.
  final Color disabledPillFill;
  final Color disabledPillLabel;

  /// Fill of the selected row of a list (Settings).
  final Color selectedRow;

  /// Barrier colour behind drawers, dialogs and sheets.
  final Color scrim;

  /// Photo viewers retain a dark canvas in both light and dark themes.
  static const photoBackground = Color(0xFF000000);
  static const onPhotoBackground = Color(0xFFFFFFFF);

  static const AppColors dark = AppColors(
    like: _like,
    repost: _repost,
    live: _live,
    recommendation: _recommendation,
    positive: _repost,
    accentText: _accent,
    secondaryOnRaised: Color(0xFF999999),
    strongPillFill: Color(0xFFEFF3F4),
    strongPillLabel: Color(0xFF0F1419),
    disabledPillFill: Color(0xFF3C3D3D),
    disabledPillLabel: Color(0xFF9A9D9F),
    selectedRow: Color(0xFF16181C),
    // X's scrim over black measured #242d34 = rgba(91, 112, 131, 0.4).
    scrim: Color(0x665B7083),
  );

  static const AppColors light = AppColors(
    like: _like,
    repost: _repost,
    live: _live,
    recommendation: _recommendation,
    positive: _repost,
    accentText: _lightAccentText,
    secondaryOnRaised: _lightTextSecondary,
    strongPillFill: Color(0xFF0F1419),
    strongPillLabel: Color(0xFFFFFFFF),
    // To confirm against X (the disabled light pill was not observed).
    disabledPillFill: Color(0x660F1419),
    disabledPillLabel: Color(0xFFFFFFFF),
    // To confirm against X (the selected light row was not observed).
    selectedRow: Color(0xFFF7F9F9),
    // Measured: a white page became #d9d9da = black at about 15 %.
    scrim: Color(0x26000000),
  );

  @override
  AppColors copyWith({
    Color? like,
    Color? repost,
    Color? live,
    Color? recommendation,
    Color? positive,
    Color? accentText,
    Color? secondaryOnRaised,
    Color? strongPillFill,
    Color? strongPillLabel,
    Color? disabledPillFill,
    Color? disabledPillLabel,
    Color? selectedRow,
    Color? scrim,
  }) {
    return AppColors(
      like: like ?? this.like,
      repost: repost ?? this.repost,
      live: live ?? this.live,
      recommendation: recommendation ?? this.recommendation,
      positive: positive ?? this.positive,
      accentText: accentText ?? this.accentText,
      secondaryOnRaised: secondaryOnRaised ?? this.secondaryOnRaised,
      strongPillFill: strongPillFill ?? this.strongPillFill,
      strongPillLabel: strongPillLabel ?? this.strongPillLabel,
      disabledPillFill: disabledPillFill ?? this.disabledPillFill,
      disabledPillLabel: disabledPillLabel ?? this.disabledPillLabel,
      selectedRow: selectedRow ?? this.selectedRow,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      like: mix(like, other.like),
      repost: mix(repost, other.repost),
      live: mix(live, other.live),
      recommendation: mix(recommendation, other.recommendation),
      positive: mix(positive, other.positive),
      accentText: mix(accentText, other.accentText),
      secondaryOnRaised: mix(secondaryOnRaised, other.secondaryOnRaised),
      strongPillFill: mix(strongPillFill, other.strongPillFill),
      strongPillLabel: mix(strongPillLabel, other.strongPillLabel),
      disabledPillFill: mix(disabledPillFill, other.disabledPillFill),
      disabledPillLabel: mix(disabledPillLabel, other.disabledPillLabel),
      selectedRow: mix(selectedRow, other.selectedRow),
      scrim: mix(scrim, other.scrim),
    );
  }
}

/// Shortcut for the semantic colours of the current theme.
extension AppColorsContext on BuildContext {
  /// The semantic colours of the current theme. A theme without the extension
  /// (a plain `MaterialApp` in a test, a third-party route) falls back to the
  /// palette of its brightness, never to null.
  AppColors get appColors {
    final theme = Theme.of(this);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light);
  }
}

ColorScheme _colorScheme(Brightness brightness) {
  if (brightness == Brightness.light) {
    return const ColorScheme(
      brightness: Brightness.light,
      primary: _accent,
      onPrimary: Color(0xFFFFFFFF),
      primaryContainer: _lightSurfaceHigh,
      onPrimaryContainer: _lightTextPrimary,
      secondary: _accent,
      onSecondary: Color(0xFFFFFFFF),
      secondaryContainer: _lightSurfaceHigh,
      onSecondaryContainer: _lightTextPrimary,
      // No separate tertiary: there is no gradient any more.
      tertiary: _accent,
      onTertiary: Color(0xFFFFFFFF),
      error: Color(0xFFBA1A1A),
      onError: Color(0xFFFFFFFF),
      surface: _lightBackground,
      onSurface: _lightTextPrimary,
      onSurfaceVariant: _lightTextSecondary,
      surfaceDim: _lightBackground,
      surfaceBright: _lightBackground,
      surfaceContainerLowest: _lightBackground,
      surfaceContainerLow: _lightSurfaceLow,
      surfaceContainer: _lightSurface,
      surfaceContainerHigh: _lightSurfaceHigh,
      surfaceContainerHighest: _lightSurfaceHighest,
      outline: _lightOutline,
      outlineVariant: _lightBorder,
      shadow: Color(0xFF000000),
      scrim: Color(0xFF000000),
      inverseSurface: _lightTextPrimary,
      onInverseSurface: _lightBackground,
      inversePrimary: _accent,
      surfaceTint: Colors.transparent,
    );
  }
  return const ColorScheme(
    brightness: Brightness.dark,
    primary: _accent,
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: _darkSurfaceHigh,
    onPrimaryContainer: _darkTextPrimary,
    secondary: _accent,
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: _darkSurfaceHigh,
    onSecondaryContainer: _darkTextPrimary,
    tertiary: _accent,
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    surface: _darkBackground,
    onSurface: _darkTextPrimary,
    onSurfaceVariant: _darkTextSecondary,
    surfaceDim: _darkBackground,
    surfaceBright: _darkSurfaceHighest,
    surfaceContainerLowest: _darkBackground,
    surfaceContainerLow: _darkSurfaceLow,
    surfaceContainer: _darkSurface,
    surfaceContainerHigh: _darkSurfaceHigh,
    surfaceContainerHighest: _darkSurfaceHighest,
    outline: _darkOutline,
    outlineVariant: _darkBorder,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: _darkTextPrimary,
    onInverseSurface: _darkBackground,
    inversePrimary: _accent,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildAppTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = _colorScheme(brightness);
  final appColors = isDark ? AppColors.dark : AppColors.light;
  final text = ThemeData(brightness: brightness).textTheme;
  final textTheme = text
      .copyWith(
        // Post body and composer text: X's 15dp on a 20dp line pitch.
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 15, height: 1.33),
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
        // Page titles, nav labels, drawer rows: bold 20dp (was w800).
        titleLarge: text.titleLarge?.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        // The profile name is capped at 22dp.
        headlineSmall: text.headlineSmall?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w700,
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
  // Dialogs, sheets and menus sit one step above the page in dark; in light
  // the page is already white.
  final modalColor = isDark
      ? colorScheme.surfaceContainer
      : colorScheme.surface;
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    brightness: brightness,
    textTheme: textTheme,
    scaffoldBackgroundColor: colorScheme.surface,
    canvasColor: colorScheme.surface,
    visualDensity: VisualDensity.adaptivePlatformDensity,
    extensions: [appColors],
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
    // The default FilledButton is X's strong (inverse) pill: light fill on
    // dark, dark fill on light. Accent-coloured buttons are explicit
    // (`FloatingActionButton`); there is no gradient.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
        shape: pillShape,
        textStyle: textTheme.labelLarge,
        backgroundColor: appColors.strongPillFill,
        foregroundColor: appColors.strongPillLabel,
        disabledBackgroundColor: appColors.disabledPillFill,
        disabledForegroundColor: appColors.disabledPillLabel,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
        shape: pillShape,
        side: BorderSide(color: colorScheme.outline),
        textStyle: textTheme.labelLarge,
        foregroundColor: colorScheme.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(
          AppSpacing.minTapTarget,
          AppSpacing.minTapTarget,
        ),
        shape: pillShape,
        foregroundColor: appColors.accentText,
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
    navigationBarTheme: NavigationBarThemeData(
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: AppSize.bottomNav,
      indicatorColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      backgroundColor: colorScheme.surface,
      // X's bar: every glyph is the primary text colour; only the filled
      // variant marks the selected one.
      iconTheme: WidgetStatePropertyAll(
        IconThemeData(color: colorScheme.onSurface, size: AppIconSize.lg),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: Colors.transparent,
      selectedIconTheme: IconThemeData(
        color: colorScheme.onSurface,
        size: AppIconSize.lg,
      ),
      unselectedIconTheme: IconThemeData(
        color: colorScheme.onSurface,
        size: AppIconSize.lg,
      ),
      selectedLabelTextStyle: textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      unselectedLabelTextStyle: textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w400,
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      scrimColor: appColors.scrim,
      elevation: 0,
      width: AppSize.drawerWidth,
      shape: const RoundedRectangleBorder(),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: modalColor,
      surfaceTintColor: Colors.transparent,
      barrierColor: appColors.scrim,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: modalColor,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: border,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: modalColor,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: appColors.scrim,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
    ),
    // Dark: a raised dark toast. Light: an inverse (dark) toast, because the
    // accent text cannot reach 4.5:1 on a light-grey surface.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark
          ? colorScheme.surfaceContainerHighest
          : colorScheme.inverseSurface,
      // M3 defaults assume an inverse-surface snackbar; on the dark surface
      // they fail WCAG AA (F4 M1), so the colours are set explicitly.
      actionTextColor: isDark ? appColors.accentText : _accent,
      closeIconColor: isDark
          ? colorScheme.onSurfaceVariant
          : colorScheme.onInverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: isDark ? colorScheme.onSurface : colorScheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    // Count badges are accent blue with a white count (X's unread dot is the
    // accent), not the Material error colour.
    badgeTheme: BadgeThemeData(
      backgroundColor: colorScheme.primary,
      textColor: colorScheme.onPrimary,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colorScheme.primary,
    ),
  );
}

ThemeData get appLightTheme => buildAppTheme(brightness: Brightness.light);
ThemeData get appDarkTheme => buildAppTheme(brightness: Brightness.dark);

/// Authentication's navy/pearl surfaces, scoped to the existing auth routes.
/// The app-level ThemeMode and typography remain the source of truth.
abstract final class AppAuthStyle {
  static const navy = Color(0xFF0B1120);
  static const mint = Color(0xFFA9E8D1);
  static const onNavy = Color(0xFFF8FAFC);
  static const panelSurface = Color(0xFF202C40);
  static const panelBorder = Color(0xFF536174);
  static const maxPageWidth = 1440.0;
  static const formWidth = 440.0;
  static const heroHeadlineSize = 56.0;
  static const splashMarkSize = 96.0;

  static ThemeData theme(ThemeData base) {
    final dark = base.brightness == Brightness.dark;
    final scheme = base.colorScheme.copyWith(
      primary: dark ? mint : navy,
      onPrimary: dark ? navy : Colors.white,
      surface: dark ? navy : const Color(0xFFF7F8FA),
      surfaceContainer: dark ? const Color(0xFF141E30) : Colors.white,
      onSurface: dark ? onNavy : const Color(0xFF111827),
      onSurfaceVariant: dark
          ? const Color(0xFFB2BDCE)
          : const Color(0xFF536174),
      outline: dark ? const Color(0xFF334155) : const Color(0xFFD4DAE3),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
    );
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      borderSide: BorderSide(color: scheme.outline),
    );
    final colors =
        (base.extension<AppColors>() ??
                (dark ? AppColors.dark : AppColors.light))
            .copyWith(
              strongPillFill: scheme.primary,
              strongPillLabel: scheme.onPrimary,
              accentText: scheme.primary,
            );
    return base.copyWith(
      colorScheme: scheme,
      extensions: [
        ...base.extensions.values.where((e) => e is! AppColors),
        colors,
      ],
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.smd,
          ),
          backgroundColor: scheme.surfaceContainer,
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outline),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(
            AppSpacing.minTapTarget,
            AppSpacing.minTapTarget,
          ),
          foregroundColor: scheme.primary,
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outline),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: scheme.surfaceContainer,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        contentPadding: const EdgeInsets.all(AppSpacing.md),
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
    );
  }
}

/// Approved authentication palette; scoped widgets retain the app-wide color policy.
abstract final class AppAuthPalette {
  static const navy = Color(0xFF101829);
  static const mint = Color(0xFFC6EFD6);
  static const paper = Color(0xFFFAFBF8);
  static const ink = Color(0xFF17202F);
  static const darkMuted = Color(0xFFA9B3A4);
  static const muted = Color(0xFF71796A);
  static const link = Color(0xFF5D6C52);
  static const darkInk = Color(0xFFF5F7F2);
  static const darkBorder = Color(0xFF344052);
  static const providerBorder = Color(0xFFDCE0D8);
  static const darkField = Color(0xFF182235);
  static const focus = Color(0xFF73977B);
  static const storyEyebrow = Color(0xFFBEC8C7);
  static const storyCopy = Color(0xFFA4ACBA);
  static const inactiveCaption = Color(0x4DFFFFFF);
  static const storyNote = Color(0xFFA9B4BD);
  static const markBorder = Color(0x33FFFFFF);
  static const markShadow = Color(0x80030814);
  static const storyBorder = Color(0x12FFFFFF);
  static const tag = Color(0xFFA2AFAC);
  static const planSurface = Color(0xFF263042);
  static const planShadow = Color(0x30060B17);
  static const coffeeSurface = Color(0xFFFAF7EA);
  static const badmintonSurface = Color(0xFFDDF0DA);
  static const planDetail = Color(0xFFAEB8C7);
  static const avatarRose = Color(0xFFC8AFA2);
  static const avatarSage = Color(0xFFC6D0B1);
  static const avatarSlate = Color(0xFF465267);
  static const orbit = Color(0x09FFFFFF);
  static const darkTabTrack = Color(0xFF151F30);
  static const tabTrack = Color(0xFFEFF1EB);
  static const darkWelcome = Color(0xFF243A33);
  static const welcome = Color(0xFFE8F0E3);
  static const darkSelectedTab = Color(0xFF2A3548);
  static const googleBlue = Color(0xFF4285F4);
  static const googleGreen = Color(0xFF34A853);
  static const googleYellow = Color(0xFFFBBC05);
  static const googleRed = Color(0xFFEA4335);
  static const white = Color(0xFFFFFFFF);
}

/// Raw redesign colour tokens (ADR-0033). Not wired into the active theme yet.
abstract final class AppPalette {
  static const Color navy = Color(0xFF0D1528);
  static const Color navy2 = Color(0xFF1B2A44);
  static const Color navyDeep = Color(0xFF08101F);
  static const Color pearl = Color(0xFFF6F4EF);
  static const Color white = Color(0xFFFFFFFF);
  static const Color teal = Color(0xFF12B8A6);

  /// Large display text only (3.77 on pearl); never body text.
  static const Color tealDark = Color(0xFF0B8C7F);
  static const Color tealElectric = Color(0xFF19D3BE);
  static const Color text2 = Color(0xFF2A3446);

  // Accessibility set.
  static const Color tealText = Color(0xFF087066);
  static const Color uiBorderOnLight = Color(0xFF7A8392);
  static const Color uiBorderOnDark = Color(0xFF7B879B);
  static const Color mutedOnLight = Color(0xFF5B6475);
  static const Color mutedOnDark = Color(0xFF9AA3B2);

  /// Danger fill (white label 6.57) and danger text on light (5.98).
  static const Color danger = Color(0xFFB42318);

  /// Danger text and icons on dark (D2): 6.53 on navy.
  static const Color dangerOnDark = Color(0xFFF97066);

  /// Decorative only; never for input, chip or button borders.
  static const Color hairlineLight = Color(0x140D1528);
  static const Color hairlineDark = Color(0x1AF6F4EF);
  static const Color scrim = Color(0x7A08101F);

  // Dark container ladder (D4).
  static const Color darkContainerLowest = navyDeep;
  static const Color darkSurface = navy;
  static const Color darkContainerLow = Color(0xFF121C33);
  static const Color darkContainer = Color(0xFF16223B);
  static const Color darkContainerHigh = navy2;
  static const Color darkContainerHighest = Color(0xFF22324F);
}

/// Redesign gradients. Declared only here.
abstract final class AppGradients {
  static const LinearGradient primaryButton = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppPalette.tealElectric, AppPalette.teal],
  );
  static const LinearGradient mineBubble = primaryButton;
  static const LinearGradient card = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppPalette.white, Color(0xFFEEF1F4)],
  );
  static const LinearGradient lightBubble = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppPalette.white, Color(0xFFE6EAEE)],
  );
  static const LinearGradient darkCard = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppPalette.navy2, AppPalette.navy],
  );

  /// dz.css `.hero`: radial-gradient(120% 120% at 85% 0%, ...).
  static const RadialGradient hero = RadialGradient(
    center: Alignment(0.7, -1),
    radius: 1.2,
    colors: [AppPalette.navy2, AppPalette.navy, AppPalette.navyDeep],
    stops: [0, 0.55, 1],
  );
}

/// Redesign shadows (outer parts only; Flutter has no inset shadow).
abstract final class AppShadows {
  static const List<BoxShadow> card = [
    BoxShadow(color: Color(0x2E0D1528), offset: Offset(0, 11), blurRadius: 25),
  ];
  static const List<BoxShadow> brand = [
    BoxShadow(color: Color(0x380D1528), offset: Offset(0, 11), blurRadius: 25),
  ];
  static const List<BoxShadow> primaryGlow = [
    BoxShadow(color: Color(0x5919D3BE), offset: Offset(0, 10), blurRadius: 26),
  ];
  static const List<BoxShadow> navBar = [
    BoxShadow(color: Color(0x590D1528), offset: Offset(0, 14), blurRadius: 30),
  ];
}

/// Redesign motion tokens.
class AppMotion {
  const AppMotion._({required this.movement});

  static const Curve expoOut = Cubic(0.16, 1, 0.3, 1);
  static const Curve backOut = Cubic(0.34, 1.56, 0.64, 1);
  static const Duration expoOutShort = Duration(milliseconds: 300);
  static const Duration expoOutLong = Duration(milliseconds: 450);
  static const Duration backOutDuration = Duration(milliseconds: 350);
  static const Duration headlineStaggerMin = Duration(milliseconds: 80);
  static const Duration headlineStaggerMax = Duration(milliseconds: 200);

  static const AppMotion full = AppMotion._(movement: true);
  static const AppMotion reduced = AppMotion._(movement: false);

  /// Whether slides and scales may run. When false, use a plain fade.
  final bool movement;

  /// Zero-movement fades under reduced motion.
  static AppMotion of(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ? reduced : full;

  /// Distance an element may travel while entering (0 when reduced).
  double offset(double distance) => movement ? distance : 0;
}

/// Redesign typography tokens (values only; the theme does not use them yet).
abstract final class AppTypeTokens {
  static const List<double> displaySizes = [28, 32, 36, 40, 48, 52];
  static const double displayTracking = -0.035;
  static const double displayLineHeight = 1.02;
  static const double eyebrowSize = 12;
  static const FontWeight eyebrowWeight = FontWeight.w700;
  static const double eyebrowTracking = 0.24;
  static const double wordmarkSize = 15;
  static const FontWeight wordmarkWeight = FontWeight.w700;
  static const double wordmarkTracking = 0.13;
  static const double bodySize = 15;
  static const double bodyLineHeight = 1.42;
  static const double focalPostSize = 17;
  static const double focalPostLineHeight = 24;
  static const FontWeight weightDisplay = FontWeight.w800;
  static const FontWeight weightUi = FontWeight.w700;
  static const FontWeight weightLabel = FontWeight.w600;
  static const FontWeight weightBody = FontWeight.w500;
}
