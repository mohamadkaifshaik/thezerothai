import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart' show ProviderNotFoundException;

import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import '../theme/app_theme.dart';
import 'shell_geometry.dart';

/// Where a modal surface (dialog, menu, sheet turned dialog) opened on the
/// tablet layout sits (tablet plan section 5.4).
///
/// The tablet layout is `ui_shell` and `ui_tablet` both on and a window of
/// 600-1199 dp. There the modal goes on the root navigator, its barrier
/// covers the whole window (the rail included, so the rail is inert and
/// focus is trapped), and it is centred on the content area: the window
/// beside the pinned rail when it was opened from a shell page
/// ([overShell]), the whole window when it was opened from a full-screen
/// route (the composer, a DM thread), which has no rail.
///
/// Phones (< 600), desktop (>= 1200) and the 600-1199 layout with either flag
/// off get no host ([of] is null): callers keep today's presentation exactly
/// (ruling R-1).
@immutable
class TabletModalHost {
  const TabletModalHost({required this.overShell});

  /// A rail is under the barrier: the modal was opened from a shell page, or
  /// from a modal that was.
  final bool overShell;

  /// Space between a modal and the edges of the content area.
  static const double margin = AppSpacing.lg;

  /// The host for a modal opened from [context] now, or null when the
  /// tablet layout is not in effect. Safe in event handlers (no
  /// dependencies are registered) and without an `OnboardingBloc` above
  /// [context] (no flags: no tablet layout).
  static TabletModalHost? of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (!ShellBand.of(width).isTablet) return null;
    final shell = context.getInheritedWidgetOfExactType<ShellGeometry>()?.data;
    if (shell != null && shell.tablet) {
      return const TabletModalHost(overShell: true);
    }
    final modal = context.getInheritedWidgetOfExactType<TabletModalScope>();
    if (modal != null) return modal.host;
    return _tabletFlagsOn(context)
        ? const TabletModalHost(overShell: false)
        : null;
  }

  static bool _tabletFlagsOn(BuildContext context) {
    try {
      return featureEnabledSnapshot(context, kFeatureUiShell) &&
          featureEnabledSnapshot(context, kFeatureUiTablet);
    } on ProviderNotFoundException {
      return false;
    }
  }

  /// The content area in window coordinates, for the window of
  /// [modalContext] (a context inside the modal's route, so that a rotation
  /// while it is open moves it along).
  Rect contentIn(BuildContext modalContext) => ShellGeometry.contentRectFor(
    MediaQuery.sizeOf(modalContext),
    MediaQuery.paddingOf(modalContext),
    overShell ? ShellLayout.tablet : ShellLayout.legacy,
    textDirection: Directionality.of(modalContext),
  ).content;

  /// The `insetPadding` of a dialog shown without a `SafeArea`
  /// (`useSafeArea: false`): [margin] inside the content area and inside the
  /// safe area on every side. The dialog is centred on the content area and
  /// at most `C - 48` wide; `Dialog` adds the keyboard inset to this, so the
  /// height stops at `H - keyboard - 48` (less the safe area).
  EdgeInsets dialogInsets(BuildContext modalContext) {
    final size = MediaQuery.sizeOf(modalContext);
    final padding = MediaQuery.paddingOf(modalContext);
    final content = contentIn(modalContext);
    return EdgeInsets.fromLTRB(
      math.max(content.left, padding.left) + margin,
      padding.top + margin,
      math.max(size.width - content.right, padding.right) + margin,
      padding.bottom + margin,
    );
  }
}

/// Carries the [TabletModalHost] of a tablet modal into its route, so a
/// dialog opened from inside it (the list editor's delete confirmation, the
/// report's block confirmation) is centred the same way.
class TabletModalScope extends InheritedWidget {
  const TabletModalScope({super.key, required this.host, required super.child});

  final TabletModalHost host;

  @override
  bool updateShouldNotify(TabletModalScope oldWidget) =>
      host.overShell != oldWidget.host.overShell;
}

/// Places the floating snack bars of the `Scaffold`s below it on the tablet
/// layout (tablet plan section 4.2): at most [AppSize.dialogMax] wide and
/// centred over [content] (window coordinates), never over the rail. The
/// tablet shell passes its content area; [TabletRouteSnackBars] passes the
/// window for full-screen routes.
class TabletSnackBarTheme extends StatelessWidget {
  const TabletSnackBarTheme({
    super.key,
    required this.content,
    required this.child,
  });

  final Rect content;
  final Widget child;

  static ThemeData themeFor(BuildContext context, Rect content) {
    final theme = Theme.of(context);
    return theme.copyWith(
      snackBarTheme: theme.snackBarTheme.copyWith(
        insetPadding: tabletSnackBarInsets(
          window: MediaQuery.sizeOf(context),
          padding: MediaQuery.paddingOf(context),
          content: content,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      Theme(data: themeFor(context, content), child: child);
}

/// The snack bars of full-screen routes (the composer, a DM thread: no rail)
/// on the tablet layout: at most [AppSize.dialogMax] wide, centred on the
/// window. Sits above the router, so it builds the same tree at every width
/// and flag state (only the theme's data changes); outside the tablet layout
/// the theme is passed on unchanged.
class TabletRouteSnackBars extends StatelessWidget {
  const TabletRouteSnackBars({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final tablet =
        ShellBand.of(width).isTablet &&
        isFeatureEnabled(context, kFeatureUiShell) &&
        isFeatureEnabled(context, kFeatureUiTablet);
    return Theme(
      data: tablet
          ? TabletSnackBarTheme.themeFor(
              context,
              Offset.zero & MediaQuery.sizeOf(context),
            )
          : Theme.of(context),
      child: child,
    );
  }
}

/// The `insetPadding` that centres a floating snack bar on [content] (window
/// coordinates) at most [AppSize.dialogMax] wide, for a `Scaffold` that spans
/// the [window] with the safe-area [padding] (a floating snack bar adds the
/// left and right insets itself). Top and bottom are Material's defaults.
EdgeInsets tabletSnackBarInsets({
  required Size window,
  required EdgeInsets padding,
  required Rect content,
}) {
  // Material's floating margin is 15 on each side.
  const minSide = 15.0;
  final side = math.max(minSide, (content.width - AppSize.dialogMax) / 2);
  return EdgeInsets.fromLTRB(
    math.max(content.left - padding.left, 0) + side,
    5,
    math.max(window.width - content.right - padding.right, 0) + side,
    10,
  );
}
