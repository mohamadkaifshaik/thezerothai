import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/shell_geometry.dart';

/// Keeps a page in a reading column. Purely presentational.
///
/// - Phones, desktop and the legacy layout (today's page): centred, at most
///   [AppLayout.mainColumnMaxWidth] wide, between 1dp borders; edge to edge
///   on a phone.
/// - The tablet layout ([ShellGeometry.readableTabletAt]; tablet plan
///   sections 2.2, 3 and 6.3): the reading content is at most
///   [AppSize.readableMax] wide and centred in its pane, with no borders (the
///   pane's own hairlines bound it and the background is continuous). A pane
///   narrower than that is filled. The header's divider ([AppFullBleed]) and
///   the tab bar's hairline span the whole pane: the column publishes the
///   space on each side through [AppMainColumnBleed]. The header's controls
///   stay in the column, so their hit areas are real.
///
/// The same widgets at every width (only values change), so crossing 600,
/// 840 or 1200 dp keeps the page's state.
///
/// [scrollsAcrossPane]: the [child] is a scroll view that keeps its slivers in
/// the column itself (a `SliverPadding` of [AppMainColumnBleed.of] on each
/// side). On the tablet layout it is then laid out across the whole pane, so
/// a drag, a wheel or a scrollbar in the space beside the column reaches it
/// (a parent hit-tests its own box first). Everywhere else it is the same
/// column as without it.
class AppMainColumn extends StatelessWidget {
  const AppMainColumn({
    super.key,
    required this.child,
    this.scrollsAcrossPane = false,
  });

  final Widget child;
  final bool scrollsAcrossPane;

  @override
  Widget build(BuildContext context) {
    final tablet = ShellGeometry.readableTabletAt(context);
    final border = Theme.of(context).colorScheme.outlineVariant;
    return LayoutBuilder(
      builder: (context, constraints) {
        final pane = constraints.maxWidth;
        final double column;
        final BoxConstraints box;
        if (tablet && pane.isFinite) {
          column = math.min(pane, AppSize.readableMax);
          box = BoxConstraints.tightFor(
            width: scrollsAcrossPane ? pane : column,
          );
        } else {
          column = pane;
          box = const BoxConstraints(maxWidth: AppLayout.mainColumnMaxWidth);
        }
        return Center(
          child: ConstrainedBox(
            constraints: box,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: tablet
                    ? null
                    : Border.symmetric(vertical: BorderSide(color: border)),
              ),
              child: AppMainColumnBleed(
                bleed: tablet ? math.max(0.0, (pane - column) / 2) : 0,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The space between an [AppMainColumn]'s reading column and each side of
/// its pane, on the tablet layout (0 everywhere else). Header and tab-bar
/// hairlines read it to span the pane ([AppFullBleed], `AppTabBar`).
class AppMainColumnBleed extends InheritedWidget {
  const AppMainColumnBleed({
    super.key,
    required this.bleed,
    required super.child,
  });

  final double bleed;

  /// The bleed around [context]'s column; 0 outside an [AppMainColumn].
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppMainColumnBleed>()?.bleed ??
      0;

  @override
  bool updateShouldNotify(AppMainColumnBleed oldWidget) =>
      bleed != oldWidget.bleed;
}

/// Lays [child] out across the [AppMainColumnBleed] on both sides of the
/// column, so that a header divider (or a header background) spans the
/// pane while the column stays capped. Its own box (and the space it takes
/// in its parent) is unchanged; only the child is wider. For decoration
/// only: the parts outside the column take no taps (a parent hit-tests its
/// own box first). With no bleed it is a plain pass-through.
class AppFullBleed extends StatelessWidget {
  const AppFullBleed({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      _Bleed(bleed: AppMainColumnBleed.of(context), child: child);
}

class _Bleed extends SingleChildRenderObjectWidget {
  const _Bleed({required this.bleed, required super.child});

  final double bleed;

  @override
  _RenderBleed createRenderObject(BuildContext context) => _RenderBleed(bleed);

  @override
  void updateRenderObject(BuildContext context, _RenderBleed renderObject) {
    renderObject.bleed = bleed;
  }
}

class _RenderBleed extends RenderProxyBox {
  _RenderBleed(this._bleed);

  double _bleed;
  double get bleed => _bleed;
  set bleed(double value) {
    if (value == _bleed) return;
    _bleed = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final grow = 2 * _bleed;
    child.layout(
      constraints.copyWith(
        minWidth: constraints.minWidth + grow,
        maxWidth: constraints.maxWidth + grow,
      ),
      parentUsesSize: true,
    );
    size = constraints.constrain(
      Size(child.size.width - grow, child.size.height),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(0, super.computeMinIntrinsicWidth(height) - 2 * _bleed);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(0, super.computeMaxIntrinsicWidth(height) - 2 * _bleed);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final grow = 2 * _bleed;
    final size = child.getDryLayout(
      constraints.copyWith(
        minWidth: constraints.minWidth + grow,
        maxWidth: constraints.maxWidth + grow,
      ),
    );
    return constraints.constrain(Size(size.width - grow, size.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child != null) context.paintChild(child, offset - Offset(_bleed, 0));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(-_bleed, 0),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(-_bleed, 0, 0, 1);
  }
}
