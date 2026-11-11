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
        return AppBleedHitRegion(
          allowsScrollView: scrollsAcrossPane,
          child: Center(
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

  /// Whether [context] is inside a reading column (an [AppMainColumn], or a
  /// view that publishes its inset as the bleed), at any width.
  static bool inColumn(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppMainColumnBleed>() != null;

  @override
  bool updateShouldNotify(AppMainColumnBleed oldWidget) =>
      bleed != oldWidget.bleed;
}

/// Lays [child] out across the [AppMainColumnBleed] on both sides of the
/// column, so that a header (or its divider) spans the pane while the column
/// stays capped. Its own box (and the space it takes in its parent) is
/// unchanged; only the child is wider. With no bleed it is a plain
/// pass-through.
///
/// Decorative by default: the parts outside the column take no taps (a
/// parent hit-tests its own box first).
///
/// [interactive] (a header's row of controls; T8f, one header rule): the
/// nearest [AppBleedHitRegion] above (every [AppMainColumn] has one) also
/// delivers the taps, hovers and long presses outside the column to the
/// child, so Back, Cancel and the actions keep real hit areas at the pane's
/// edges. The child is only widened where that holds: with no region above,
/// or a clip between the region and the child (a [ClipRect], or a scroll
/// view the region does not span), it stays in the column, so nothing is
/// drawn where it could not be tapped or seen.
class AppFullBleed extends StatelessWidget {
  const AppFullBleed({
    super.key,
    required this.child,
    this.interactive = false,
  });

  final Widget child;
  final bool interactive;

  @override
  Widget build(BuildContext context) => _Bleed(
    bleed: AppMainColumnBleed.of(context),
    interactive: interactive,
    child: child,
  );
}

/// The box that delivers pointer events outside a reading column to the
/// interactive [AppFullBleed]s below it (T8f). [AppMainColumn] always has
/// one around the whole pane; a view that lays a scroll view across its pane
/// and publishes its own [AppMainColumnBleed] (a feed's header slivers) puts
/// one around that scroll view, with [allowsScrollView].
///
/// An event reaches a widened child only where nothing else in the region
/// takes it (the rest of the hit path holds only the child's ancestors), the
/// child is painted there (inside every clip on the way, so not scrolled
/// away or under a pinned header) and nothing on the way ignores or absorbs
/// pointers, is offstage or is a hidden child of an [IndexedStack]. A plain
/// pass-through everywhere else.
class AppBleedHitRegion extends SingleChildRenderObjectWidget {
  const AppBleedHitRegion({
    super.key,
    this.allowsScrollView = false,
    required super.child,
  });

  /// The region spans a scroll view as wide as itself (laid out across the
  /// pane): one viewport between the region and a header does not keep the
  /// header in the column.
  final bool allowsScrollView;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBleedHitRegion(allowsScrollView);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderBleedHitRegion).allowsScrollView = allowsScrollView;
  }
}

class _RenderBleedHitRegion extends RenderProxyBox {
  _RenderBleedHitRegion(this._allowsScrollView);

  bool _allowsScrollView;
  bool get allowsScrollView => _allowsScrollView;
  set allowsScrollView(bool value) {
    if (value == _allowsScrollView) return;
    _allowsScrollView = value;
    // Every interactive bleed below decides at layout whether it may widen,
    // registered or not (one that fell back is in no set).
    void visit(RenderObject node) {
      if (node is _RenderBleed && node.interactive) node.markNeedsLayout();
      node.visitChildren(visit);
    }

    visitChildren(visit);
  }

  final Set<_RenderBleed> _targets = {};

  /// Hit testing outside the column. Known limits, by design: a gesture
  /// handler, `Listener` or `TapRegion` that is an ancestor of the header
  /// (a `GestureDetector` around it) does not see a gutter event, as its own
  /// box ends at the column; only the header's controls and the pane-wide
  /// scroll view (when there is one) do. Nothing in the app wraps a header
  /// in one. The cost is one `getTransformTo` per registered header per hit
  /// test (one or two per page), and none for a point inside the column,
  /// which is where mouse hovers almost always are.
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final target in _targets) {
      final child = target.child;
      final applied = target._applied;
      if (applied == 0 || child == null || !target.attached) continue;
      if (!target.hasSize || !child.hasSize) continue;
      final toRegion = child.getTransformTo(this);
      final inverse = Matrix4.tryInvert(toRegion);
      if (inverse == null) continue;
      final local = MatrixUtils.transformPoint(inverse, position);
      // Only the parts outside the column: inside it, the normal path
      // reaches the child through its own box.
      if (!(Offset.zero & child.size).contains(local)) continue;
      if ((Offset.zero & target.size).contains(local - Offset(applied, 0))) {
        continue;
      }
      if (!_reaches(target, position)) continue;
      if (!_fallsThrough(target, position)) continue;
      final hit = result.addWithPaintTransform(
        transform: toRegion,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) {
        // The pane's own handlers (a scroll view the header is in) follow,
        // as they would for a tap inside the column.
        super.hitTestChildren(result, position: position);
        return true;
      }
    }
    return super.hitTestChildren(result, position: position);
  }

  /// [target] is painted at [position] and nothing between it and this
  /// region keeps pointers from it.
  bool _reaches(_RenderBleed target, Offset position) {
    RenderObject child = target;
    var node = target.parent;
    while (node != null && node != this) {
      if (node is RenderIgnorePointer && node.ignoring) return false;
      if (node is RenderAbsorbPointer && node.absorbing) return false;
      if (node is RenderOffstage && node.offstage) return false;
      if (node is RenderSliverIgnorePointer && node.ignoring) return false;
      if (node is RenderSliverOffstage && node.offstage) return false;
      if (node is RenderIndexedStack && !_shown(node, child)) return false;
      final clip = node.describeApproximatePaintClip(child);
      if (clip != null) {
        final inRegion = MatrixUtils.transformRect(
          node.getTransformTo(this),
          clip,
        );
        if (!inRegion.contains(position)) return false;
      }
      child = node;
      node = node.parent;
    }
    return node == this;
  }

  static bool _shown(RenderIndexedStack stack, RenderObject child) {
    var index = 0;
    var current = stack.firstChild;
    while (current != null) {
      if (identical(current, child)) return index == stack.index;
      index++;
      current = stack.childAfter(current);
    }
    return false;
  }

  /// Nothing else in the region takes [position]: its own hit path holds
  /// only [target]'s ancestors (a scroll view the header is in), never a
  /// sibling drawn there.
  bool _fallsThrough(_RenderBleed target, Offset position) {
    final probe = BoxHitTestResult();
    super.hitTestChildren(probe, position: position);
    if (probe.path.isEmpty) return true;
    final ancestors = <Object>{};
    for (var node = target.parent; node != null && node != this;) {
      ancestors.add(node);
      node = node.parent;
    }
    return probe.path.every((entry) => ancestors.contains(entry.target));
  }

  @override
  void detach() {
    _targets.clear();
    super.detach();
  }
}

class _Bleed extends SingleChildRenderObjectWidget {
  const _Bleed({
    required this.bleed,
    required this.interactive,
    required super.child,
  });

  final double bleed;
  final bool interactive;

  @override
  _RenderBleed createRenderObject(BuildContext context) =>
      _RenderBleed(bleed, interactive: interactive);

  @override
  void updateRenderObject(BuildContext context, _RenderBleed renderObject) {
    renderObject
      ..bleed = bleed
      ..interactive = interactive;
  }
}

class _RenderBleed extends RenderProxyBox {
  _RenderBleed(this._bleed, {required bool interactive})
    : _interactive = interactive;

  double _bleed;
  double get bleed => _bleed;
  set bleed(double value) {
    if (value == _bleed) return;
    _bleed = value;
    markNeedsLayout();
  }

  bool _interactive;
  bool get interactive => _interactive;
  set interactive(bool value) {
    if (value == _interactive) return;
    _interactive = value;
    markNeedsLayout();
  }

  /// The bleed this layout used: [bleed], or 0 for an [interactive] child
  /// that could not be reached outside the column.
  double _applied = 0;

  _RenderBleedHitRegion? _region;

  void _register(_RenderBleedHitRegion? region) {
    if (identical(region, _region)) return;
    _region?._targets.remove(this);
    _region = region;
    region?._targets.add(this);
  }

  /// The bleed an [interactive] child may take, and the region that then
  /// delivers its events: [bleed] when an [AppBleedHitRegion] is above with
  /// no clip on the way (except the one scroll view a region that
  /// [AppBleedHitRegion.allowsScrollView] spans), else 0.
  (double, _RenderBleedHitRegion?) _resolve() {
    if (!_interactive) return (_bleed, null);
    if (_bleed <= 0) return (0, null);
    var viewports = 0;
    for (var node = parent; node != null; node = node.parent) {
      if (node is _RenderBleedHitRegion) {
        final ok = viewports == 0 || (viewports == 1 && node.allowsScrollView);
        return ok ? (_bleed, node) : (0, null);
      }
      if (node is RenderViewportBase) {
        if (node.clipBehavior != Clip.none) viewports++;
      } else if (_clips(node)) {
        return (0, null);
      }
    }
    return (0, null);
  }

  static bool _clips(RenderObject node) => switch (node) {
    RenderClipRect(:final clipBehavior) ||
    RenderClipRRect(:final clipBehavior) ||
    RenderClipOval(:final clipBehavior) ||
    RenderClipPath(:final clipBehavior) ||
    RenderPhysicalModel(:final clipBehavior) ||
    RenderPhysicalShape(:final clipBehavior) => clipBehavior != Clip.none,
    _ => false,
  };

  BoxConstraints _wider(BoxConstraints constraints, double bleed) =>
      constraints.copyWith(
        minWidth: constraints.minWidth + 2 * bleed,
        maxWidth: constraints.maxWidth + 2 * bleed,
      );

  @override
  void performLayout() {
    final (applied, region) = _resolve();
    _applied = applied;
    _register(region);
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_wider(constraints, applied), parentUsesSize: true);
    size = constraints.constrain(
      Size(child.size.width - 2 * applied, child.size.height),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(0, super.computeMinIntrinsicWidth(height) - 2 * _resolve().$1);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(0, super.computeMaxIntrinsicWidth(height) - 2 * _resolve().$1);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final applied = _resolve().$1;
    final size = child.getDryLayout(_wider(constraints, applied));
    return constraints.constrain(Size(size.width - 2 * applied, size.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final shift = offset - Offset(_applied, 0);
    final region = _region;
    if (region == null || _applied == 0) {
      context.paintChild(child, shift);
      return;
    }
    // What the region would not deliver to (a scrolled header's part under
    // a pinned sliver, per the viewport's own paint clip) is not painted
    // beside the column either: nothing is drawn that cannot be tapped.
    final visible = _visibleBeyondColumn();
    if (visible == null) {
      context.paintChild(child, shift);
      return;
    }
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRect(visible.intersect(Rect.fromLTRB(-_applied, -1e5, 0, 1e5)))
      ..addRect(
        visible.intersect(
          Rect.fromLTRB(size.width, -1e5, size.width + _applied, 1e5),
        ),
      );
    context.pushClipPath(
      needsCompositing,
      offset,
      Rect.fromLTWH(-_applied, 0, size.width + 2 * _applied, size.height),
      path.shift(Offset.zero),
      (context, offset) => context.paintChild(child, shift),
    );
  }

  /// The part of this box's row (in its own coordinates) that every paint
  /// clip between it and the region leaves visible; null when all of it is.
  Rect? _visibleBeyondColumn() {
    final full = Rect.fromLTWH(
      -_applied,
      0,
      size.width + 2 * _applied,
      size.height,
    );
    var visible = full;
    RenderObject child = this;
    for (
      var node = parent;
      node != null && node != _region;
      node = node.parent
    ) {
      final clip = node.describeApproximatePaintClip(child);
      if (clip != null) {
        final inverse = Matrix4.tryInvert(getTransformTo(node));
        if (inverse == null) return null;
        visible = visible.intersect(MatrixUtils.transformRect(inverse, clip));
        if (visible.isEmpty) return Rect.zero;
      }
      child = node;
    }
    return visible == full ? null : visible;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(-_applied, 0),
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translateByDouble(-_applied, 0, 0, 1);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    // A reattach (a moved or reparented subtree) lost the registration in
    // detach; layout puts it back.
    markNeedsLayout();
  }

  @override
  void detach() {
    _register(null);
    super.detach();
  }
}
