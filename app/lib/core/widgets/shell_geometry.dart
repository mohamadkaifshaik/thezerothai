import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// The width band of the window (tablet plan section 1). Decided by the window
/// width only, never by the device type.
enum ShellBand {
  /// < 600 dp: the phone chrome (ADR-0034).
  phone,

  /// 600-839 dp, band A: rail + one fluid column.
  medium,

  /// 840-1199 dp, band B: rail + two panes (from T3 on; T1 draws one).
  expanded,

  /// >= 1200 dp: the desktop composition, unchanged (ruling R-1).
  desktop;

  static ShellBand of(double width) {
    if (width < AppBreakpoints.mobile) return ShellBand.phone;
    if (width < AppBreakpoints.expanded) return ShellBand.medium;
    if (width < AppBreakpoints.tablet) return ShellBand.expanded;
    return ShellBand.desktop;
  }

  /// One of the two tablet bands (600-1199 dp).
  bool get isTablet => this == ShellBand.medium || this == ShellBand.expanded;
}

/// Which composition `ResponsiveScaffold` draws at 600-1199 dp.
enum ShellLayout {
  /// Today's composition: the `NavigationRail` and the capped column,
  /// centred inside one outer `SafeArea` (styled by `redesignedRail` under
  /// `ui_shell`). Every layout with `ui_shell` or `ui_tablet` off.
  legacy,

  /// The tablet shell (`ui_shell` and `ui_tablet` both on): the `AppNavRail`
  /// pinned to the leading edge and the panes filling the rest, each pane
  /// taking its own safe-area insets (tablet plan section 2).
  tablet,
}

/// Where the shell's chrome ends and its content starts, for one window.
///
/// Only the tablet layout at 600-1199 dp is modelled ([tablet] true): the
/// rail is [AppSize.railCompact] plus the leading safe-area inset and the
/// content is the rest of the width minus the trailing inset (the
/// `C = W - 80 - insets` of plan section 3). Phones, desktop and the legacy
/// layout report the whole window as [content] and a zero [railWidth]:
/// callers keep today's behaviour there (dialogs centred on the window).
///
/// [content] spans the full window height: the top and bottom insets stay
/// inside the panes (a pane pads its header by the top inset; scrollables
/// take the bottom one).
@immutable
class ShellGeometryData {
  const ShellGeometryData({
    required this.band,
    required this.layout,
    required this.railWidth,
    required this.content,
  });

  final ShellBand band;
  final ShellLayout layout;

  /// Width of the pinned rail including the leading inset; 0 where the
  /// geometry is not modelled.
  final double railWidth;

  /// The content area in window coordinates.
  final Rect content;

  /// The tablet layout is in effect: the rail is pinned and [content] is the
  /// pane area beside it.
  bool get tablet => layout == ShellLayout.tablet && band.isTablet;

  @override
  bool operator ==(Object other) =>
      other is ShellGeometryData &&
      other.band == band &&
      other.layout == layout &&
      other.railWidth == railWidth &&
      other.content == content;

  @override
  int get hashCode => Object.hash(band, layout, railWidth, content);

  @override
  String toString() =>
      'ShellGeometryData($band, $layout, rail $railWidth, content $content)';
}

/// Publishes the [ShellGeometryData] of the tablet layout to the panes below
/// `ResponsiveScaffold` (later: dialogs, sheets and snackbars centre on the
/// content, tablet plan section 5.4). Absent outside the tablet layout, where
/// [maybeOf] returns null and callers keep today's behaviour.
class ShellGeometry extends InheritedWidget {
  const ShellGeometry({super.key, required this.data, required super.child});

  final ShellGeometryData data;

  /// The geometry of a [window] with the safe-area [padding] in [layout]
  /// (a pure function: no `BuildContext`). [textDirection] decides which
  /// side is leading: the rail and its inset sit there.
  static ShellGeometryData contentRectFor(
    Size window,
    EdgeInsets padding,
    ShellLayout layout, {
    TextDirection textDirection = TextDirection.ltr,
  }) {
    final band = ShellBand.of(window.width);
    if (layout != ShellLayout.tablet || !band.isTablet) {
      return ShellGeometryData(
        band: band,
        layout: layout,
        railWidth: 0,
        content: Offset.zero & window,
      );
    }
    final ltr = textDirection == TextDirection.ltr;
    final leading = ltr ? padding.left : padding.right;
    final trailing = ltr ? padding.right : padding.left;
    final rail = AppSize.railCompact + leading;
    final width = (window.width - rail - trailing).clamp(0.0, window.width);
    final left = ltr ? rail : trailing;
    return ShellGeometryData(
      band: band,
      layout: layout,
      railWidth: rail,
      content: Rect.fromLTWH(left, 0, width, window.height),
    );
  }

  static ShellGeometryData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellGeometry>()?.data;

  /// The side inset that centres a reading column in a pane [width] wide
  /// (tablet plan sections 3 and 5.4): on the tablet layout the column grows
  /// to [AppSize.readableMax]; everywhere else it stays
  /// [AppBreakpoints.mobile] wide, as before.
  static double readableInset(BuildContext context, double width) {
    final tablet = maybeOf(context)?.tablet ?? false;
    final column = tablet ? AppSize.readableMax : AppBreakpoints.mobile;
    return math.max(0.0, (width - column) / 2);
  }

  @override
  bool updateShouldNotify(ShellGeometry oldWidget) => data != oldWidget.data;
}
