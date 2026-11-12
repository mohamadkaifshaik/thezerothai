import 'package:flutter/material.dart';

/// Design tokens shared by every screen. Never hard-code a `Color(0x...)` or
/// a raw size outside this file.
///
/// The colour system is the redesign of ADR-0033 (with amendment 1): pearl
/// and navy surfaces, teal actions, and gradients only where the design
/// defines them ([AppGradients]). The ADR's accessibility corrections
/// override the design tokens where they conflict (teal text on light is
/// [AppPalette.tealText]; borders reach 3:1; danger text on dark is
/// [AppPalette.dangerOnDark]). Sizes are dp; the legacy chrome sizes below
/// were measured on x.com and migrate section by section.
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

  /// Vertical content padding of a text field (dz.css `.field`: 16 x 13).
  static const double fieldVertical = 13;
}

/// Icon sizes (dp). Visuals sit inside a 48dp tap target.
abstract final class AppIconSize {
  /// Verified badge, small inline glyphs.
  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 40;

  /// The post action row glyph (dz.css `.acts`, 18 px; the 48dp tap target
  /// around it is kept).
  static const double action = 18;
}

/// The opened post on its post page: text 17dp on a 24dp line on phones (the
/// mobile PostDetail design), 21dp at 1.4 from the tablet width up (the
/// tablet and desktop PostDetail designs); action glyphs a step above the
/// list rows.
abstract final class AppFocalPost {
  static const double bodySize = 17;
  static const double bodyLineHeight = 24;
  static const double bodySizeWide = 21;
  static const double bodyLineHeightWide = 29.4;
  static const double actionIcon = 20;

  /// Below 600dp the actions keep the list glyph size and the avatar is 46dp
  /// (the mobile PostDetail design).
  static const double actionIconPhone = 18;
  static const double phoneAvatar = 46;
}

/// Opacity levels for tints over a surface.
abstract final class AppOpacity {
  /// Tint of a highlighted (for example unread) row: a hint, never the only
  /// signal.
  static const double rowTint = 0.08;

  /// Fill of the leading result bar of a poll (accent over the surface); the
  /// other bars use the border colour. Text over it keeps AA in both themes.
  static const double pollLeadingBar = 0.35;

  /// The thread rail between connected posts: the accent at this alpha.
  static const double threadRail = 0.35;
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

  /// Menus, popup menus and snackbars.
  static const double menu = 16;
}

/// Responsive layout breakpoints (window width, dp).
abstract final class AppBreakpoints {
  /// Phones end here: the tablet layouts start at this width.
  static const double mobile = 600;

  /// The Material 3 *expanded* boundary inside the tablet range: 600-839 is
  /// band A (one fluid column), 840-1199 band B (two panes). Tablet plan
  /// section 1.
  static const double expanded = 840;

  /// Desktop from: the extended rail and the 600 + 350 column cluster start
  /// at this width. (The name predates the tablet bands; it does not mean
  /// "tablet".)
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

  /// Boundary width of outline buttons and chips (component themes).
  static const double componentBorder = 1.5;

  // The tablet layout, 600-1199 dp (tablet plan section 1).

  /// Width of the pinned `AppNavRail` (plus the leading safe-area inset).
  static const double railCompact = 80;

  /// Width of the extended `NavigationRail` of the desktop layout (>= 1200
  /// dp): Material's `minExtendedWidth`, which the app's theme keeps.
  static const double railExtended = 256;

  /// Widest a reading column (posts, forms, settings rows) grows inside a
  /// tablet pane; the pane and its header span the full width.
  static const double readableMax = 680;

  /// Band B context pane: `clamp(C - 1 - readableMax, min, max)`.
  static const double contextPaneMin = 320;
  static const double contextPaneMax = 440;

  /// Band B list pane of a list-detail screen: `clamp(0.4 * C, min, max)`.
  static const double listPaneMin = 320;
  static const double listPaneMax = 400;

  /// Max width of a dialog, and of the composer dialogs.
  static const double dialogMax = 560;
  static const double composerDialogMax = 600;

  /// Tallest the composer dialogs grow: `min(85 % of H, this)` (tablet plan
  /// section 4.1, Composer row).
  static const double composerDialogMaxHeight = 720;

  /// The desktop reply dialog (desktop ReplyComposer mock, dz.css `.scrim`
  /// and `.modal`): hung 64 dp under the top of the window, at most this
  /// tall (the mock's card: the bar, the post, four lines and the footer).
  static const double desktopModalTop = 64;
  static const double replyDialogDesktopHeight = 440;

  /// The character ring of the reply composer (ReplyComposer mocks): 26 dp
  /// on a phone, 24 dp in the dialog.
  static const double counterRingPhone = 26;
  static const double counterRing = 24;

  /// Width range of a confirm or alert dialog on the tablet layout ("D
  /// 280-400", tablet plan section 4.2).
  static const double alertDialogMin = 280;
  static const double alertDialogMax = 400;

  /// Width of the scheduled post editor on tablet and desktop (the Schedule
  /// dialog is 440; the editor carries a text field too).
  static const double editScheduledDialog = 480;

  /// Width of a side sheet (the chat info sheet).
  static const double sideSheet = 360;
}

/// Semantic colours that the Material [ColorScheme] has no slot for.
///
/// Read them with `context.appColors`. State and role colours come from the
/// [AppPalette] token family; the one brand gradient is [primaryFillGradient]
/// (ADR-0033 §6: gradients only where the design defines them).
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
    required this.primaryFillGradient,
    required this.primaryFillLabel,
    required this.dangerFill,
    required this.onDangerFill,
    required this.uiBorder,
    required this.hairline,
    required this.text2,
    required this.selectedIndicator,
    required this.navBarSurface,
    required this.navBarSelected,
    required this.navBarUnselected,
  });

  /// Like heart and liked state: the danger red of the theme (text-safe on
  /// every surface step, because it also tints the count).
  final Color like;

  /// Repost icon and reposted state (teal; the label also changes).
  final Color repost;

  /// Live broadcast indicator (danger family).
  final Color live;

  /// Recommendation / assistant notification icon (teal family).
  final Color recommendation;

  /// A positive status (available handle).
  final Color positive;

  /// Colour for small accent *text* (links, hashtags, "Show more"):
  /// tealText on light, tealElectric on dark.
  final Color accentText;

  /// Secondary text on a raised surface (cards with a fill).
  final Color secondaryOnRaised;

  /// The strong (inverse) pill: navy on light, pearl on dark.
  final Color strongPillFill;
  final Color strongPillLabel;

  /// A disabled pill: flat, same shape.
  final Color disabledPillFill;
  final Color disabledPillLabel;

  /// Fill of the selected row of a list (Settings).
  final Color selectedRow;

  /// Barrier colour behind drawers, dialogs and sheets.
  final Color scrim;

  /// The primary button / own-bubble gradient and its label (navy on both
  /// ends: 9.61 and 7.30).
  final LinearGradient primaryFillGradient;
  final Color primaryFillLabel;

  /// Destructive fills (both themes) and their label.
  final Color dangerFill;
  final Color onDangerFill;

  /// Boundary of fields, chips and outline buttons (>= 3:1).
  final Color uiBorder;

  /// Decorative divider only (translucent; never a component boundary).
  final Color hairline;

  /// Secondary-strong text (field labels, rail rows).
  final Color text2;

  /// Selected tab / chip indicator.
  final Color selectedIndicator;

  /// The floating navigation bar: navy in both themes (design F16).
  final Color navBarSurface;
  final Color navBarSelected;
  final Color navBarUnselected;

  /// Photo viewers retain a dark canvas in both light and dark themes.
  static const photoBackground = Color(0xFF000000);
  static const onPhotoBackground = Color(0xFFFFFFFF);

  static const AppColors dark = AppColors(
    like: AppPalette.dangerOnDark,
    repost: AppPalette.tealElectric,
    live: AppPalette.dangerOnDark,
    recommendation: AppPalette.tealElectric,
    positive: AppPalette.tealElectric,
    accentText: AppPalette.tealElectric,
    secondaryOnRaised: AppPalette.mutedOnDark,
    strongPillFill: AppPalette.pearl,
    strongPillLabel: AppPalette.navy,
    disabledPillFill: AppPalette.darkContainerHighest,
    disabledPillLabel: AppPalette.mutedOnDark,
    selectedRow: AppPalette.darkContainerHigh,
    scrim: AppPalette.scrimDark,
    primaryFillGradient: AppGradients.primaryButton,
    primaryFillLabel: AppPalette.navy,
    dangerFill: AppPalette.danger,
    onDangerFill: AppPalette.white,
    uiBorder: AppPalette.uiBorderOnDark,
    hairline: AppPalette.hairlineDark,
    text2: AppPalette.text2OnDark,
    selectedIndicator: AppPalette.tealElectric,
    navBarSurface: AppPalette.navy,
    navBarSelected: AppPalette.tealElectric,
    navBarUnselected: AppPalette.mutedOnDark,
  );

  static const AppColors light = AppColors(
    like: AppPalette.danger,
    repost: AppPalette.tealText,
    live: AppPalette.danger,
    recommendation: AppPalette.tealText,
    positive: AppPalette.tealText,
    accentText: AppPalette.tealText,
    secondaryOnRaised: AppPalette.mutedOnLight,
    strongPillFill: AppPalette.navy,
    strongPillLabel: AppPalette.pearl,
    disabledPillFill: AppPalette.lightContainerHighest,
    disabledPillLabel: AppPalette.mutedOnLight,
    selectedRow: AppPalette.lightContainerHigh,
    scrim: AppPalette.scrim,
    primaryFillGradient: AppGradients.primaryButton,
    primaryFillLabel: AppPalette.navy,
    dangerFill: AppPalette.danger,
    onDangerFill: AppPalette.white,
    uiBorder: AppPalette.uiBorderOnLight,
    hairline: AppPalette.hairlineLight,
    text2: AppPalette.text2,
    selectedIndicator: AppPalette.tealText,
    navBarSurface: AppPalette.navy,
    navBarSelected: AppPalette.tealElectric,
    navBarUnselected: AppPalette.mutedOnDark,
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
    LinearGradient? primaryFillGradient,
    Color? primaryFillLabel,
    Color? dangerFill,
    Color? onDangerFill,
    Color? uiBorder,
    Color? hairline,
    Color? text2,
    Color? selectedIndicator,
    Color? navBarSurface,
    Color? navBarSelected,
    Color? navBarUnselected,
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
      primaryFillGradient: primaryFillGradient ?? this.primaryFillGradient,
      primaryFillLabel: primaryFillLabel ?? this.primaryFillLabel,
      dangerFill: dangerFill ?? this.dangerFill,
      onDangerFill: onDangerFill ?? this.onDangerFill,
      uiBorder: uiBorder ?? this.uiBorder,
      hairline: hairline ?? this.hairline,
      text2: text2 ?? this.text2,
      selectedIndicator: selectedIndicator ?? this.selectedIndicator,
      navBarSurface: navBarSurface ?? this.navBarSurface,
      navBarSelected: navBarSelected ?? this.navBarSelected,
      navBarUnselected: navBarUnselected ?? this.navBarUnselected,
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
      primaryFillGradient: LinearGradient.lerp(
        primaryFillGradient,
        other.primaryFillGradient,
        t,
      )!,
      primaryFillLabel: mix(primaryFillLabel, other.primaryFillLabel),
      dangerFill: mix(dangerFill, other.dangerFill),
      onDangerFill: mix(onDangerFill, other.onDangerFill),
      uiBorder: mix(uiBorder, other.uiBorder),
      hairline: mix(hairline, other.hairline),
      text2: mix(text2, other.text2),
      selectedIndicator: mix(selectedIndicator, other.selectedIndicator),
      navBarSurface: mix(navBarSurface, other.navBarSurface),
      navBarSelected: mix(navBarSelected, other.navBarSelected),
      navBarUnselected: mix(navBarUnselected, other.navBarUnselected),
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
      // tealText, not the bright teal: Material defaults (focus ring, switch,
      // progress, text-button foreground) stay AA on pearl (5.43).
      primary: AppPalette.tealText,
      onPrimary: AppPalette.white,
      primaryContainer: AppPalette.lightContainerHigh,
      onPrimaryContainer: AppPalette.navy,
      // The `.btn.navy`.
      secondary: AppPalette.navy,
      onSecondary: AppPalette.pearl,
      secondaryContainer: AppPalette.lightContainerHigh,
      onSecondaryContainer: AppPalette.navy,
      // Tertiary has no role and stays banned in lib/ (it mirrors primary).
      tertiary: AppPalette.tealText,
      onTertiary: AppPalette.white,
      error: AppPalette.danger,
      onError: AppPalette.white,
      surface: AppPalette.pearl,
      onSurface: AppPalette.navy,
      onSurfaceVariant: AppPalette.mutedOnLight,
      surfaceDim: AppPalette.lightContainerHighest,
      surfaceBright: AppPalette.white,
      surfaceContainerLowest: AppPalette.white,
      surfaceContainerLow: AppPalette.lightContainerLow,
      // Cards and fields.
      surfaceContainer: AppPalette.white,
      surfaceContainerHigh: AppPalette.lightContainerHigh,
      surfaceContainerHighest: AppPalette.lightContainerHighest,
      outline: AppPalette.uiBorderOnLight,
      outlineVariant: AppPalette.hairlineLight,
      shadow: AppPalette.navyDeep,
      scrim: AppPalette.navyDeep,
      inverseSurface: AppPalette.navy,
      onInverseSurface: AppPalette.pearl,
      inversePrimary: AppPalette.tealElectric,
      surfaceTint: Colors.transparent,
    );
  }
  return const ColorScheme(
    brightness: Brightness.dark,
    primary: AppPalette.tealElectric,
    onPrimary: AppPalette.navy,
    primaryContainer: AppPalette.darkContainerHigh,
    onPrimaryContainer: AppPalette.pearl,
    secondary: AppPalette.pearl,
    onSecondary: AppPalette.navy,
    secondaryContainer: AppPalette.darkContainerHigh,
    onSecondaryContainer: AppPalette.pearl,
    tertiary: AppPalette.tealElectric,
    onTertiary: AppPalette.navy,
    // Amendment 1: danger text and icons on dark; fills use dangerFill.
    error: AppPalette.dangerOnDark,
    onError: AppPalette.navy,
    surface: AppPalette.darkSurface,
    onSurface: AppPalette.pearl,
    onSurfaceVariant: AppPalette.mutedOnDark,
    surfaceDim: AppPalette.darkContainerLowest,
    surfaceBright: AppPalette.darkContainerHighest,
    surfaceContainerLowest: AppPalette.darkContainerLowest,
    surfaceContainerLow: AppPalette.darkContainerLow,
    surfaceContainer: AppPalette.darkContainer,
    surfaceContainerHigh: AppPalette.darkContainerHigh,
    surfaceContainerHighest: AppPalette.darkContainerHighest,
    outline: AppPalette.uiBorderOnDark,
    outlineVariant: AppPalette.hairlineDark,
    shadow: AppPalette.navyDeep,
    scrim: AppPalette.navyDeep,
    inverseSurface: AppPalette.pearl,
    onInverseSurface: AppPalette.navy,
    inversePrimary: AppPalette.tealText,
    surfaceTint: Colors.transparent,
  );
}

ThemeData buildAppTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final colorScheme = _colorScheme(brightness);
  final appColors = isDark ? AppColors.dark : AppColors.light;
  final textTheme = buildAppTextTheme().apply(
    bodyColor: colorScheme.onSurface,
    displayColor: colorScheme.onSurface,
  );
  final pillShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.pill),
  );
  final hairline = BorderSide(color: appColors.hairline);
  // Component boundaries (outline buttons, chips) are >= 3:1 (ADR-0033 §4).
  final boundary = BorderSide(
    color: colorScheme.outline,
    width: AppSize.componentBorder,
  );
  // Sheets and menus sit one step above the page in dark; in light they
  // share the pearl page. Dialogs use the page surface (pearl / navy).
  final modalColor = isDark
      ? colorScheme.surfaceContainer
      : colorScheme.surface;
  const tapTarget = Size(AppSpacing.minTapTarget, AppSpacing.minTapTarget);
  // Filled and outlined buttons stretch to their parent's width by default
  // (existing call sites rely on it) and are 48 dp tall.
  const stretchTarget = Size.fromHeight(AppSpacing.minTapTarget);
  final menuShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.menu),
    side: BorderSide(color: colorScheme.outline),
  );
  OutlineInputBorder fieldBorder(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide(color: color, width: width),
      );
  bool selected(Set<WidgetState> states) =>
      states.contains(WidgetState.selected);
  bool disabled(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled);
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    brightness: brightness,
    // Text outside the text theme defaults to the body family. The text
    // theme's own families win: ThemeData merges it over the defaults.
    fontFamily: AppFonts.body,
    textTheme: textTheme,
    scaffoldBackgroundColor: colorScheme.surface,
    canvasColor: colorScheme.surface,
    // 48 dp targets on every platform (D6): Material's adaptive density and
    // shrink-wrapped targets would make desktop and web controls smaller.
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    extensions: [appColors],
    // Elevation stays 0 everywhere; depth comes only from AppShadows, which
    // the phase 2 primitives paint.
    dividerTheme: DividerThemeData(
      color: appColors.hairline,
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
      shape: Border(bottom: hairline),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    // The default FilledButton is the strong (inverse) pill, the `.btn.navy`:
    // navy on light, pearl on dark. `ButtonStyle` cannot paint a gradient, so
    // the teal gradient primary (`AppColors.primaryFillGradient`) is a
    // primitive (PR 2.1).
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: stretchTarget,
        shape: pillShape,
        textStyle: textTheme.labelLarge,
        backgroundColor: appColors.strongPillFill,
        foregroundColor: appColors.strongPillLabel,
        disabledBackgroundColor: appColors.disabledPillFill,
        disabledForegroundColor: appColors.disabledPillLabel,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: stretchTarget,
        shape: pillShape,
        side: boundary,
        textStyle: textTheme.labelLarge,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: tapTarget,
        shape: pillShape,
        textStyle: textTheme.labelLarge,
        foregroundColor: appColors.accentText,
        elevation: 0,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: tapTarget,
        shape: pillShape,
        textStyle: textTheme.labelLarge,
      ).copyWith(elevation: const WidgetStatePropertyAll(0)),
    ),
    // The design draws navy at 6 %; onSurface is navy on light and keeps the
    // hover visible on the navy page (pearl at 6 %).
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: tapTarget,
        hoverColor: colorScheme.onSurface.withValues(alpha: 0.06),
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
    // dz.css `.field`: labels above the field, a >= 3:1 boundary, the
    // selected-indicator colour at 2 dp on focus.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark
          ? AppPalette.fieldFillDark
          : colorScheme.surfaceContainer,
      isDense: false,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.fieldVertical,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      border: fieldBorder(colorScheme.outline),
      enabledBorder: fieldBorder(colorScheme.outline),
      focusedBorder: fieldBorder(appColors.selectedIndicator, width: 2),
      errorBorder: fieldBorder(colorScheme.error),
      focusedErrorBorder: fieldBorder(colorScheme.error, width: 2),
      hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
      errorStyle: textTheme.bodySmall?.copyWith(color: colorScheme.error),
      helperStyle: textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurfaceVariant,
      ),
    ),
    // Pills with a >= 3:1 boundary; the selected one takes the indicator
    // colour and keeps its check mark (never colour alone). The visual is
    // 32 dp inside a 48 dp target (materialTapTargetSize above).
    chipTheme: ChipThemeData(
      shape: pillShape,
      side: WidgetStateBorderSide.resolveWith(
        (states) => boundary.copyWith(
          color: selected(states) && !disabled(states)
              ? appColors.selectedIndicator
              : colorScheme.outline,
        ),
      ),
      labelStyle: textTheme.labelSmall?.copyWith(
        fontWeight: AppTypeTokens.weightUi,
      ),
      elevation: 0,
      pressElevation: 0,
    ),
    // The selected glyph is onPrimary on the indicator (selectedIndicator is
    // the primary); the filled icon variant also marks it. Phase 3 restyles.
    navigationBarTheme: NavigationBarThemeData(
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: AppSize.bottomNav,
      indicatorColor: appColors.selectedIndicator,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
      backgroundColor: colorScheme.surface,
      labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: selected(states)
              ? colorScheme.onPrimary
              : colorScheme.onSurface,
          size: AppIconSize.lg,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colorScheme.surface,
      indicatorColor: appColors.selectedIndicator,
      selectedIconTheme: IconThemeData(
        color: colorScheme.onPrimary,
        size: AppIconSize.lg,
      ),
      unselectedIconTheme: IconThemeData(
        color: colorScheme.onSurface,
        size: AppIconSize.lg,
      ),
      // Weight marks the selected label too, not colour alone.
      selectedLabelTextStyle: textTheme.labelMedium?.copyWith(
        fontWeight: AppTypeTokens.weightUi,
      ),
      unselectedLabelTextStyle: textTheme.labelMedium,
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      scrimColor: appColors.scrim,
      elevation: 0,
      width: AppSize.drawerWidth,
      shape: const RoundedRectangleBorder(),
    ),
    // ThemeData cannot carry a BoxShadow list: the dialog primitive (PR 2.6)
    // paints AppShadows.brand.
    dialogTheme: DialogThemeData(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      barrierColor: appColors.scrim,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    // PopupMenuItem is 48 dp tall by default (kMinInteractiveDimension).
    popupMenuTheme: PopupMenuThemeData(
      color: modalColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: menuShape,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(modalColor),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(menuShape),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: MenuItemButton.styleFrom(minimumSize: tapTarget),
    ),
    // The drag handle is a 48 dp target.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: modalColor,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: appColors.scrim,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheetTop),
        ),
      ),
    ),
    // A navy toast on light, navy2 on the navy page; the action is
    // tealElectric (9.61 on navy, 7.60 on navy2).
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: isDark
          ? colorScheme.surfaceContainerHigh
          : colorScheme.inverseSurface,
      // M3 defaults assume an inverse-surface snackbar; on the dark surface
      // they fail WCAG AA (F4 M1), so the colours are set explicitly.
      actionTextColor: isDark
          ? appColors.accentText
          : colorScheme.inversePrimary,
      closeIconColor: isDark
          ? colorScheme.onSurfaceVariant
          : colorScheme.onInverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: isDark ? colorScheme.onSurface : colorScheme.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.menu),
      ),
    ),
    // AppTabBar is restyled in phase 2; this covers Material's TabBar.
    tabBarTheme: TabBarThemeData(
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(
          color: appColors.selectedIndicator,
          width: AppSize.tabIndicator,
        ),
      ),
      labelColor: colorScheme.onSurface,
      unselectedLabelColor: colorScheme.onSurfaceVariant,
      dividerColor: appColors.hairline,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (disabled(states)) return null;
        return selected(states) ? colorScheme.onPrimary : colorScheme.outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (disabled(states)) return null;
        return selected(states)
            ? appColors.selectedIndicator
            : colorScheme.surfaceContainerHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (disabled(states)) return null;
        return selected(states) ? Colors.transparent : colorScheme.outline;
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (disabled(states)) return null;
        return selected(states)
            ? appColors.selectedIndicator
            : Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(colorScheme.onPrimary),
      side: WidgetStateBorderSide.resolveWith((states) {
        if (disabled(states)) return null;
        return selected(states)
            ? const BorderSide(width: 0, color: Colors.transparent)
            : BorderSide(color: colorScheme.outline, width: 2);
      }),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (disabled(states)) return null;
        return selected(states)
            ? appColors.selectedIndicator
            : colorScheme.outline;
      }),
    ),
    // dz.css `.count`: navy on light, pearl on dark.
    badgeTheme: BadgeThemeData(
      backgroundColor: appColors.strongPillFill,
      textColor: appColors.strongPillLabel,
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
  static const muted = Color(0xFF646C5D);
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

/// Raw redesign colour tokens (ADR-0033). The [ColorScheme]s and [AppColors]
/// read them; widgets read the theme, not these.
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

  /// The dark theme's modal scrim: black at 64 %. The light scrim (navy-deep
  /// at 48 %) barely darkens the navy page, so a dialog or sheet on dark
  /// read as part of the page.
  static const Color scrimDark = Color(0xA3000000);

  // Dark container ladder (D4).
  static const Color darkContainerLowest = navyDeep;
  static const Color darkSurface = navy;
  static const Color darkContainerLow = Color(0xFF121C33);
  static const Color darkContainer = Color(0xFF16223B);
  static const Color darkContainerHigh = navy2;
  static const Color darkContainerHighest = Color(0xFF22324F);

  // Light container ladder (PR 1.3). surface is pearl; Lowest and Container
  // are white.
  static const Color lightContainerLow = Color(0xFFFAF9F6);
  static const Color lightContainerHigh = Color(0xFFEEF1F4);
  static const Color lightContainerHighest = Color(0xFFE6EAEE);

  /// text2 on dark: pearl at 80 % over navy (dz.css `.dark .field label`).
  static const Color text2OnDark = Color(0xFFC7C7C7);

  /// Fallback avatar backgrounds (initials). The first three take
  /// [avatarInkOnTint] (navy), the last, [avatarTintNavy], takes
  /// [avatarInkOnNavy] (pearl); every pair is at least 4.5:1.
  static const Color avatarTintSlate = Color(0xFFC9D3DC);
  static const Color avatarTintMint = Color(0xFFBFE9E2);
  static const Color avatarTintSand = Color(0xFFE3DCCB);
  static const Color avatarTintNavy = navy;
  static const List<Color> avatarTints = [
    avatarTintSlate,
    avatarTintMint,
    avatarTintSand,
    avatarTintNavy,
  ];
  static const Color avatarInkOnTint = navy;
  static const Color avatarInkOnNavy = pearl;

  /// Text field fill on dark: dz.css `rgba(246,244,239,.06)` (pearl at 6 %).
  static const Color fieldFillDark = Color(0x0FF6F4EF);
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
    colors: [AppPalette.white, AppPalette.lightContainerHigh],
  );
  static const LinearGradient lightBubble = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppPalette.white, AppPalette.lightContainerHighest],
  );
  static const LinearGradient darkCard = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppPalette.navy2, AppPalette.navy],
  );

  /// The community cover band (Community.dc.html `.cover`): a diagonal
  /// navy wash under the teal rings.
  static const LinearGradient communityCover = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppPalette.navy2, AppPalette.navy],
  );

  /// dz.css `.hero`: radial-gradient(120% 120% at 85% 0%, ...).
  static const RadialGradient hero = RadialGradient(
    center: Alignment(0.7, -1),
    radius: 1.2,
    colors: [AppPalette.navy2, AppPalette.navy, AppPalette.navyDeep],
    stops: [0, 0.55, 1],
  );

  /// The dark splash wash (dzeroth-mobile Splash.html): radial-gradient(90%
  /// 60% at 50% 45%, navy2, navy 55%, navyDeep).
  static const RadialGradient splash = RadialGradient(
    center: Alignment(0, -.1),
    radius: .9,
    colors: [AppPalette.navy2, AppPalette.navy, AppPalette.navyDeep],
    stops: [0, .55, 1],
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

  /// The raised search pill of the phone results header (dzeroth-mobile
  /// SearchResults: 0 6px 16px rgba(13,21,40,.06)).
  static const List<BoxShadow> searchRaised = [
    BoxShadow(color: Color(0x0F0D1528), offset: Offset(0, 6), blurRadius: 16),
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

/// Redesign typography tokens (ADR-0033 §2). [buildAppTextTheme] and
/// [AppTextStyles] are built from them.
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

  /// The reply composer's text (ReplyComposer mocks): 19 sp full screen on a
  /// phone, 20 sp in the tablet and desktop dialog, at 1.35 / 1.4.
  static const double replyFieldSizePhone = 19;
  static const double replyFieldLineHeightPhone = 1.35;
  static const double replyFieldSizeDialog = 20;
  static const double replyFieldLineHeightDialog = 1.4;
  static const FontWeight weightDisplay = FontWeight.w800;
  static const FontWeight weightUi = FontWeight.w700;
  static const FontWeight weightLabel = FontWeight.w600;
  static const FontWeight weightBody = FontWeight.w500;
}

/// The two bundled families (`pubspec.yaml`; each is one variable TTF). The
/// engine maps `fontWeight` onto their `wght` axis (outcome A of the redesign
/// plan §1.2, `test/core/theme/typography_test.dart`), so styles set
/// `fontWeight` only, never `fontVariations`.
abstract final class AppFonts {
  /// Display, headings, screen titles, wordmark and eyebrow.
  static const String display = 'Manrope';

  /// Body, UI labels, buttons, inputs and post text.
  static const String body = 'DM Sans';
}

TextStyle _type(
  String family,
  double size,
  FontWeight weight, {
  required double height,
  double tracking = 0,
}) => TextStyle(
  fontFamily: family,
  fontSize: size,
  fontWeight: weight,
  height: height,
  // Tracking is relative to size (em), never an absolute value.
  letterSpacing: tracking * size,
  textBaseline: TextBaseline.alphabetic,
  leadingDistribution: TextLeadingDistribution.even,
);

TextStyle _display(double size) => _type(
  AppFonts.display,
  size,
  AppTypeTokens.weightDisplay,
  height: AppTypeTokens.displayLineHeight,
  tracking: AppTypeTokens.displayTracking,
);

/// The redesign type scale (ADR-0033 §2), built from scratch so no Material
/// default (tracking, line height, weight) leaks in. Colourless: the theme
/// applies `onSurface`.
///
/// Headings and labels have no design tracking or line height; they use 0
/// tracking and the line heights below on purpose (not Material's values).
TextTheme buildAppTextTheme() {
  const w800 = AppTypeTokens.weightDisplay;
  const w700 = AppTypeTokens.weightUi;
  const w600 = AppTypeTokens.weightLabel;
  const w500 = AppTypeTokens.weightBody;
  const display = AppFonts.display;
  const body = AppFonts.body;
  return TextTheme(
    displayLarge: _display(52),
    displayMedium: _display(40),
    displaySmall: _display(28),
    headlineLarge: _type(display, 24, w800, height: 1.25),
    headlineMedium: _type(display, 22, w800, height: 1.25),
    headlineSmall: _type(display, 20, w800, height: 1.25),
    // Top bar and screen titles.
    titleLarge: _type(display, 20, w800, height: 1.25),
    titleMedium: _type(body, 17, w700, height: 1.3),
    // Display names, section titles: 15 sp on a 20 dp line.
    titleSmall: _type(body, 15, w700, height: 1.33),
    // Post body and composer text.
    bodyLarge: _type(
      body,
      AppTypeTokens.bodySize,
      w500,
      height: AppTypeTokens.bodyLineHeight,
    ),
    bodyMedium: _type(body, 14, w500, height: 1.4),
    bodySmall: _type(body, 13, w500, height: 1.35),
    // Buttons.
    labelLarge: _type(body, 15, w700, height: 1.33),
    labelMedium: _type(body, 14, w600, height: 1.33),
    labelSmall: _type(body, 12, w600, height: 1.33),
  );
}

/// Redesign text styles outside the Material text theme. Each takes the
/// active theme so it carries the scheme's colours.
abstract final class AppTextStyles {
  /// Small uppercase kicker above a heading: Manrope 12 sp w700, +0.24 em.
  /// Uppercase the string at the call site (`toUpperCase()`); it is never the
  /// only carrier of information (ADR-0033 §4).
  static TextStyle eyebrow(ThemeData theme) => _type(
    AppFonts.display,
    AppTypeTokens.eyebrowSize,
    AppTypeTokens.eyebrowWeight,
    height: 1.33,
    tracking: AppTypeTokens.eyebrowTracking,
  ).copyWith(color: theme.colorScheme.onSurfaceVariant);

  /// The "DZEROTH" wordmark: Manrope 15 sp w700, +0.13 em.
  static TextStyle wordmark(ThemeData theme) => _type(
    AppFonts.display,
    AppTypeTokens.wordmarkSize,
    AppTypeTokens.wordmarkWeight,
    height: 1.2,
    tracking: AppTypeTokens.wordmarkTracking,
  ).copyWith(color: theme.colorScheme.onSurface);

  /// The opened post's text: DM Sans 17 sp on a 24 dp line.
  static TextStyle focalPost(ThemeData theme) => _type(
    AppFonts.body,
    AppTypeTokens.focalPostSize,
    AppTypeTokens.weightBody,
    height: AppTypeTokens.focalPostLineHeight / AppTypeTokens.focalPostSize,
  ).copyWith(color: theme.colorScheme.onSurface);

  /// The accented part of a display headline, in the accent text colour
  /// (tealText on light, tealElectric on dark; AA at any size). [size] is one
  /// of [AppTypeTokens.displaySizes].
  static TextStyle displayAccent(ThemeData theme, {double size = 28}) {
    assert(AppTypeTokens.displaySizes.contains(size), 'not a display size');
    final colors =
        theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light);
    return _display(size).copyWith(color: colors.accentText);
  }
}

/// New-message picker geometry (dzeroth-mobile RecipientPicker; the tablet
/// and desktop mocks' dz.css `.search`, `.sect`, `.row`). Colours come from
/// the theme, shadows from [AppShadows].
abstract final class AppPickerLayout {
  // Phone: the raised pill and the 20 dp page gutter.
  static const double phoneGutter = 20;
  static const double phoneSearchTop = 12;
  static const double phoneSearchBottom = 4;
  static const double phoneSectionTop = 14;
  static const double phoneSectionBottom = 2;
  static const double phoneHandleSize = 13;

  // Tablet / desktop: the flat pill and the 16 dp `.row` gutter.
  static const double dialogGutter = 16;
  static const double dialogSectionTop = 20;
  static const double dialogSectionBottom = 8;
  static const double dialogHandleSize = 14;

  // Both.
  static const double searchHeight = 48;
  static const double rowPaddingV = 12;
  static const double rowGap = 12;
}

/// Plans geometry (dzeroth-mobile, tablet and desktop Home, PlanDetail,
/// PlanPeople, PlanCreate, PlanEdit and MyPlans). Colours come from the
/// theme, shadows from [AppShadows].
abstract final class AppPlansLayout {
  // The plan page's hero: full width, rounded under, with the back and menu
  // circles in it.
  static const double heroRadius = 34;
  static const double heroButton = 44;
  static const double heroGutter = 24;

  // The list cards: the phone's 20 dp page gutter, the wide layouts' 16 dp.
  static const double phoneGutter = 20;
  static const double wideGutter = 16;

  // The compact rows of My plans (the tile, then eyebrow, title and time).
  static const double tileSize = 52;

  // A form lays Cost beside Open spots from this content width.
  static const double formPairMin = 480;
}

/// Settings geometry per screen size (dp): the phone mock's raised cards
/// (dzeroth-mobile Settings) and the tablet / desktop mocks' flat boxes and
/// category list (dz.css `.box`, `.row`, `.sect`, `.search`). Colours come
/// from the theme, gradients from [AppGradients], shadows from [AppShadows].
abstract final class AppSettingsLayout {
  // Phone page.
  static const double pagePaddingH = 20;
  static const double pagePaddingV = 16;
  static const double groupGap = 18;
  static const double labelGap = 8;
  static const double labelInset = 4;
  static const double raisedPadding = 4;
  static const double raisedRowMinHeight = 64;
  static const double raisedRowPaddingH = 14;
  static const double raisedRowPaddingV = 6;
  static const double raisedRowGap = 14;

  // Tablet / desktop.
  static const double flatRowPaddingH = 16;
  static const double flatRowPaddingV = 12;
  static const double flatRowGap = 12;
  static const double flatLabelTop = 20;
  static const double flatLabelBottom = 8;
  static const double searchHeight = 46;
  static const double searchPaddingH = 18;
  static const double searchGap = 10;
  static const double searchBottom = 10;
  static const double categoryPaddingV = 14;
  static const double selectedBarWidth = 3;

  /// Row titles in both looks: 15 sp, the UI weight.
  static const double titleSize = 15;
}

/// Splash, sign-in and sign-up geometry per screen size (dp), from the
/// dzeroth-mobile, tablet and desktop Splash / SignIn / SignUp mocks. Colours
/// come from the theme, gradients from [AppGradients].
abstract final class AppAuthLayout {
  // Teal rings: (diameter, alpha) from the inside out.
  static const List<(double, double)> phoneRings = [
    (112, .4),
    (208, .24),
    (320, .12),
  ];
  static const List<(double, double)> wideRings = [
    (180, .4),
    (300, .24),
    (420, .12),
    (600, .08),
    (820, .05),
  ];
  static const List<(double, double)> splashPhoneRings = [
    (140, .4),
    (260, .24),
    (400, .12),
    (560, .06),
  ];
  static const List<(double, double)> splashWideRings = [
    (220, .4),
    (380, .24),
    (560, .12),
    (760, .08),
    (980, .05),
  ];

  /// Phone ring centre, from the top-right corner.
  static const Offset phoneRingsFromTopEnd = Offset(60, 120);

  /// Tablet ring centre, from the top-right corner.
  static const Offset tabletRingsFromTopEnd = Offset(210, 260);

  // Phone page.
  static const double phonePaddingH = 24;
  static const double phonePaddingTop = 12;
  static const double phonePaddingBottom = 24;
  static const double phoneDisplaySize = 40;
  static const double phoneFieldGap = 12;
  static const double phoneHeaderTop = 12;
  static const double phoneFieldsTop = 16;

  // Tablet page (one centred column).
  static const double tabletPaddingH = 64;
  static const double tabletPaddingV = 48;
  static const double tabletFormWidth = 540;

  // Desktop split: hero 1.6 : form 1.
  static const int desktopHeroFlex = 16;
  static const int desktopFormFlex = 10;
  static const double desktopHeroPaddingH = 72;
  static const double desktopHeroPaddingV = 56;
  static const double desktopFormPaddingH = 64;
  static const double desktopFormWidth = 470;
  static const double heroDisplayMax = 88;
  static const double heroDisplayMin = 56;
  static const double heroBodySize = 22;
  static const double heroBodyWidth = 520;

  /// Form headline on tablet and desktop.
  static const double wideDisplaySize = 52;

  // Shared form rhythm.
  static const double eyebrowGap = 14;
  static const double fieldsTop = 32;
  static const double fieldGap = 16;
  static const double fieldLabelGap = 6;
  static const double actionsGap = 14;
  static const double dividerGap = 22;
  static const double socialGap = 10;
  static const double socialHeight = 52;
  static const double socialMarkSize = 18;

  // Splash.
  static const double splashLogoPhone = 104;
  static const double splashLogoWide = 150;
  static const double splashLogoRadiusPhone = 28;
  static const double splashLogoRadiusWide = 40;
  static const double splashLogoHalo = 10;
  static const double splashWordmarkPhone = 18;
  static const double splashWordmarkWide = 22;
  static const double splashGap = 26;
  static const double splashTaglineTop = 40;
  static const double splashLoaderBottom = 64;
  static const Size splashPill = Size(22, 8);
  static const double splashPillGap = 10;
}

/// Scheduled posts geometry per screen size (dp): the dzeroth-mobile,
/// tablet and desktop Scheduled mocks' cards. The card itself is
/// `AppCard` (the `card` gradient, radius and shadow).
abstract final class AppScheduledLayout {
  // Phone list: 16 x 20 padding, 14 between cards.
  static const double phoneListPaddingH = 20;
  static const double phoneListPaddingV = 16;
  static const double phoneCardGap = 14;
  static const double phoneTimeSize = 13;
  static const double phoneTextSize = 15;
  static const double phoneTextGap = 10;

  // Tablet / desktop: 12 x 16 card margins, 18 x 20 padding.
  static const double wideCardGap = 24;
  static const double wideCardPaddingH = 20;
  static const double wideCardPaddingV = 18;
  static const double wideTimeSize = 14;
  static const double wideTextSize = 16;
  static const double wideTextGap = 10;
  static const double wideActionsGap = 14;

  /// The clock glyph sits on the time line's cap height.
  static const double iconTop = 2;
}
