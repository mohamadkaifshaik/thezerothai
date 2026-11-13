import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart' show ProviderNotFoundException;

import '../feature_flags/feature_flags.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import '../theme/app_theme.dart';
import 'shell_geometry.dart';

/// Which panes the desktop shell (`ResponsiveScaffold` at >= 1200 dp) shows
/// around its feed column, for [ShellGeometry.desktopColumnFor]: the
/// Settings [master] pane before it, or the [side] column after it.
@immutable
class DesktopColumnSlots {
  const DesktopColumnSlots({
    this.master = false,
    this.side = true,
    this.railWidth = AppSize.railExtended,
  });

  /// The 350 dp list pane between the rail and the column (Settings). The
  /// side column is not shown with it.
  final bool master;

  /// The 24 + 350 dp side column after the column (when there is no
  /// [master] pane).
  final bool side;

  /// The extended rail's laid-out width: [AppSize.railExtended], or more
  /// when its labels need it (large text).
  final double railWidth;

  /// The column for a [window] with the safe-area [padding].
  Rect columnFor(
    Size window,
    EdgeInsets padding, {
    TextDirection textDirection = TextDirection.ltr,
  }) => ShellGeometry.desktopColumnFor(
    window,
    padding,
    master: master,
    side: side,
    railWidth: railWidth,
    textDirection: textDirection,
  );

  @override
  bool operator ==(Object other) =>
      other is DesktopColumnSlots &&
      other.master == master &&
      other.side == side &&
      other.railWidth == railWidth;

  @override
  int get hashCode => Object.hash(master, side, railWidth);
}

/// The live panes of the desktop shell, kept per root navigator: the shell
/// publishes its [DesktopColumnSlots] (master or side, and the extended
/// rail's laid-out width) after each layout that changed them. A modal that
/// outlives the layout it was opened in (a window widened past 1200 dp, a
/// text scale change that widens the rail) and a dialog that is a page of
/// its own on that navigator (`/premium`, `/messages/new`), which cannot see
/// the shell's [TabletModalScope], read the current value and listen to it,
/// so they never place the column from a stale snapshot. Weakly keyed: it
/// goes with the navigator.
abstract final class DesktopShellSlots {
  static final _notifiers = Expando<ValueNotifier<DesktopColumnSlots?>>(
    'desktop shell slots',
  );

  /// The notifier of the root navigator above [context], or null without
  /// one. Safe in event handlers (no dependency is registered).
  static ValueNotifier<DesktopColumnSlots?>? notifierOf(BuildContext context) {
    final root = Navigator.maybeOf(context, rootNavigator: true);
    if (root == null) return null;
    return _notifiers[root] ??= ValueNotifier<DesktopColumnSlots?>(null);
  }

  /// The slots the desktop shell last published, or null when none has.
  static DesktopColumnSlots? of(BuildContext context) =>
      notifierOf(context)?.value;

  /// Publishes [slots] for the root navigator above [shellContext].
  static void publish(BuildContext shellContext, DesktopColumnSlots slots) {
    final notifier = notifierOf(shellContext);
    if (notifier != null) notifier.value = slots;
  }
}

/// Where a modal surface (dialog, menu, sheet turned dialog) opened on the
/// tablet or desktop layout sits (tablet plan section 5.4; D1).
///
/// The tablet layout is `ui_shell` and `ui_tablet` both on and a window of
/// 600-1199 dp. There the modal goes on the root navigator, its barrier
/// covers the whole window (the rail included, so the rail is inert and
/// focus is trapped), and it is centred on the content area: the window
/// beside the pinned rail when it was opened from a shell page
/// ([overShell]), the whole window when it was opened from a full-screen
/// route (the composer, a DM thread), which has no rail.
///
/// The desktop layout (the same two flags, >= 1200 dp) does the same, but
/// centres a modal opened from the shell on its feed column ([desktop]),
/// and lets it be as wide as the window allows (`min(spec, W - 48)`), not
/// only the column.
///
/// Phones (< 600) and every width with either flag off get no host ([of] is
/// null): callers keep today's presentation exactly (ruling R-1).
@immutable
class TabletModalHost {
  const TabletModalHost({
    required this.overShell,
    this.desktop = const DesktopColumnSlots(),
  });

  /// A rail is under the barrier: the modal was opened from a shell page, or
  /// from a modal that was.
  final bool overShell;

  /// The panes of the desktop shell under the barrier ([overShell]), which
  /// place its column at >= 1200 dp. Unused below 1200 dp.
  final DesktopColumnSlots desktop;

  /// Space between a modal and the edges of the content area.
  static const double margin = AppSpacing.lg;

  /// The host for a modal opened from [context] now, or null when neither
  /// the tablet nor the desktop layout is in effect. Safe in event handlers
  /// (no dependencies are registered) and without an `OnboardingBloc` above
  /// [context] (no flags: no host).
  static TabletModalHost? of(BuildContext context) {
    final band = ShellBand.of(MediaQuery.sizeOf(context).width);
    if (band == ShellBand.phone) return null;
    if (band.isTablet) {
      final shell = context
          .getInheritedWidgetOfExactType<ShellGeometry>()
          ?.data;
      if (shell != null && shell.tablet) {
        return const TabletModalHost(overShell: true);
      }
    }
    // The tablet and desktop shells carry a scope (a modal opened from the
    // rail is over the shell too), and so does a modal's route.
    final modal = context
        .getInheritedWidgetOfExactType<_TabletModalHostScope>();
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
  /// or a resize while it is open moves it along). At >= 1200 dp it is the
  /// desktop shell's feed column ([overShell]) or the whole window.
  Rect contentIn(BuildContext modalContext) {
    final size = MediaQuery.sizeOf(modalContext);
    final padding = MediaQuery.paddingOf(modalContext);
    final direction = Directionality.of(modalContext);
    if (ShellBand.of(size.width) == ShellBand.desktop) {
      if (!overShell) return Offset.zero & size;
      // The shell's current panes, not the snapshot this host was made with
      // (a modal opened at 600-1199 dp knows nothing of them). Registers the
      // dependency on the enclosing scope, which rebuilds when they change.
      modalContext.dependOnInheritedWidgetOfExactType<_TabletModalHostScope>();
      final live = DesktopShellSlots.of(modalContext) ?? desktop;
      return live.columnFor(size, padding, textDirection: direction);
    }
    return ShellGeometry.contentRectFor(
      size,
      padding,
      overShell ? ShellLayout.tablet : ShellLayout.legacy,
      textDirection: direction,
    ).content;
  }

  /// The `insetPadding` of a dialog shown without a `SafeArea`
  /// (`useSafeArea: false`). Top and bottom are [margin], or the safe area
  /// where that is taller (a status bar over 24 dp), so the height is
  /// `H - keyboard - 48` (`Dialog` adds the keyboard inset).
  ///
  /// Below 1200 dp: [margin] inside the content area (and inside the side
  /// safe area) on the left and right, so the dialog is centred on the
  /// content area and at most `C - 48` wide.
  ///
  /// From 1200 dp: centred on the content area (the desktop column) but as
  /// wide as the window allows, `min(maxWidth, W - 48)` inside the side safe
  /// area. A dialog of [maxWidth] that would cross the window's margin
  /// beside an off-centre column (1200 dp with the Settings pane) moves just
  /// enough to keep its width; without [maxWidth] (the date and time
  /// pickers, which size themselves) the room is symmetric about the centre.
  EdgeInsets dialogInsets(BuildContext modalContext, {double? maxWidth}) {
    final size = MediaQuery.sizeOf(modalContext);
    final padding = MediaQuery.paddingOf(modalContext);
    final content = contentIn(modalContext);
    final top = math.max(padding.top, margin);
    final bottom = math.max(padding.bottom, margin);
    if (ShellBand.of(size.width) != ShellBand.desktop) {
      return EdgeInsets.fromLTRB(
        math.max(content.left, padding.left) + margin,
        top,
        math.max(size.width - content.right, padding.right) + margin,
        bottom,
      );
    }
    final start = padding.left + margin;
    final end = math.max(start, size.width - padding.right - margin);
    final centre = content.center.dx.clamp(start, end);
    final double half;
    final double mid;
    if (maxWidth != null) {
      half = math.min(maxWidth, end - start) / 2;
      mid = centre.clamp(start + half, end - half);
    } else {
      half = math.min(centre - start, end - centre);
      mid = centre;
    }
    return EdgeInsets.fromLTRB(
      mid - half,
      top,
      size.width - mid - half,
      bottom,
    );
  }
}

/// Carries a [TabletModalHost] down the tree: around the tablet shell (so a
/// modal opened from the rail, its account menu included, is over the shell)
/// and into a tablet modal's route (so a dialog opened from inside it, the
/// list editor's delete confirmation for instance, is centred the same
/// way). A scope in a modal route also follows the desktop shell's live
/// panes ([DesktopShellSlots]): it rebuilds the modal's placement when they
/// change. The shell's own scope has no need to ([followShell] false).
class TabletModalScope extends StatefulWidget {
  const TabletModalScope({
    super.key,
    required this.host,
    required this.child,
    this.followShell = true,
  });

  final TabletModalHost host;
  final Widget child;
  final bool followShell;

  @override
  State<TabletModalScope> createState() => _TabletModalScopeState();
}

class _TabletModalScopeState extends State<TabletModalScope> {
  ValueNotifier<DesktopColumnSlots?>? _slots;
  int _revision = 0;

  void _changed() {
    if (mounted) setState(() => _revision++);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = widget.followShell
        ? DesktopShellSlots.notifierOf(context)
        : null;
    if (next == _slots) return;
    _slots?.removeListener(_changed);
    next?.addListener(_changed);
    _slots = next;
  }

  @override
  void didUpdateWidget(TabletModalScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.followShell != widget.followShell) didChangeDependencies();
  }

  @override
  void dispose() {
    _slots?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TabletModalHostScope(
    host: widget.host,
    revision: _revision,
    child: widget.child,
  );
}

class _TabletModalHostScope extends InheritedWidget {
  const _TabletModalHostScope({
    required this.host,
    required this.revision,
    required super.child,
  });

  final TabletModalHost host;

  /// Bumped when the desktop shell's panes change, so dependents re-place.
  final int revision;

  @override
  bool updateShouldNotify(_TabletModalHostScope oldWidget) =>
      host.overShell != oldWidget.host.overShell ||
      host.desktop != oldWidget.host.desktop ||
      revision != oldWidget.revision;
}

/// Places the floating snack bars of the `Scaffold`s below it on the tablet
/// and desktop layouts (tablet plan section 4.2; D1): at most
/// [AppSize.dialogMax] wide and centred over [content] (window coordinates),
/// never over the rail. The tablet shell passes its content area, the
/// desktop shell its feed column; [TabletRouteSnackBars] passes the window
/// for full-screen routes.
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
/// on the tablet and desktop layouts (>= 600 dp, both flags): at most
/// [AppSize.dialogMax] wide, centred on the window. Sits above the router,
/// so it builds the same tree at every width and flag state (only the
/// theme's data changes); on phones and with either flag off the theme is
/// passed on unchanged.
class TabletRouteSnackBars extends StatelessWidget {
  const TabletRouteSnackBars({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final tablet =
        ShellBand.of(width) != ShellBand.phone &&
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
