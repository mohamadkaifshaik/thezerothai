import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

/// Grows the tap area of a control drawn smaller than the minimum tap target
/// (the Dz artboards draw 44 dp actions) to [minSize] without changing the
/// layout: the control keeps its drawn size and position, and a tap that
/// lands in the ring around it (up to [minSize], centred on it) is forwarded
/// to the nearest point inside it. The same idea as Material's
/// `_InputPadding`, but the box keeps the child's size instead of padding it
/// out, so rows stay at the design's numbers.
///
/// The accessibility node of the control is this box, sized like the tap
/// area ([minSize]), so screen readers and the tap-target guideline see the
/// 48 dp target too.
///
/// Flutter hit testing walks down from the root and every box rejects a
/// point outside its own bounds, so a ring (or a row's bleed) that pokes out
/// of an ancestor is only reachable through an [AppTapAreaHost] above it:
/// the host hands a tap that nothing under it took to the tap area whose
/// box (or else ring) contains it. Without a host the ring still works
/// wherever the ancestors are larger than the control (a 76 dp header row
/// around a 44 dp back arrow).
class AppTapArea extends SingleChildRenderObjectWidget {
  const AppTapArea({
    super.key,
    this.minSize = const Size.square(AppSpacing.minTapTarget),
    this.mergeSemantics = true,
    super.child,
  }) : bleed = 0,
       ring = 0;

  /// A row of [AppTapArea] controls, laid out [bleed] dp wider on each side
  /// than the space it is given (CSS `margin: 0 -10px`): its first and last
  /// items line up with the content edge around them while their padding
  /// hangs into the gutter. Taps are accepted on the bled child and [ring]
  /// dp around it (the 44 to 48 dp ring of its items), so its items' rings
  /// can be reached; an item's ring only takes a tap that lands on no item.
  /// The row is not a semantics node of its own.
  const AppTapArea.bleed({
    super.key,
    required this.bleed,
    this.ring = (AppSpacing.minTapTarget - AppIconSize.actionTarget) / 2,
    super.child,
  }) : minSize = Size.zero,
       mergeSemantics = false;

  /// The smallest tap area, centred on the child.
  final Size minSize;

  /// Horizontal overhang of the child on each side (layout).
  final double bleed;

  /// A row's tap margin around its (bled) child.
  final double ring;

  /// Make this box the child's accessibility node (with the tap area's
  /// bounds). False for a row ([AppTapArea.bleed]).
  final bool mergeSemantics;

  @override
  RenderAppTapArea createRenderObject(BuildContext context) => RenderAppTapArea(
    minSize: minSize,
    bleed: bleed,
    ring: ring,
    mergeSemantics: mergeSemantics,
  );

  @override
  void updateRenderObject(BuildContext context, RenderAppTapArea renderObject) {
    renderObject
      ..minSize = minSize
      ..bleed = bleed
      ..ring = ring
      ..mergeSemantics = mergeSemantics;
  }
}

/// The render box of [AppTapArea].
class RenderAppTapArea extends RenderShiftedBox {
  RenderAppTapArea({
    required Size minSize,
    double bleed = 0,
    double ring = 0,
    bool mergeSemantics = true,
    RenderBox? child,
  }) : _minSize = minSize,
       _bleed = bleed,
       _ring = ring,
       _mergeSemantics = mergeSemantics,
       super(child);

  Size get minSize => _minSize;
  Size _minSize;
  set minSize(Size value) {
    if (value == _minSize) return;
    _minSize = value;
    markNeedsSemanticsUpdate();
  }

  double get ring => _ring;
  double _ring;
  set ring(double value) {
    if (value == _ring) return;
    _ring = value;
    markNeedsSemanticsUpdate();
  }

  double get bleed => _bleed;
  double _bleed;
  set bleed(double value) {
    if (value == _bleed) return;
    _bleed = value;
    markNeedsLayout();
  }

  bool get mergeSemantics => _mergeSemantics;
  bool _mergeSemantics;
  set mergeSemantics(bool value) {
    if (value == _mergeSemantics) return;
    _mergeSemantics = value;
    markNeedsSemanticsUpdate();
  }

  RenderAppTapHost? _host;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    // Single controls register with the nearest host (rows need not: the
    // host reaches their items directly).
    if (!_mergeSemantics) return;
    for (var node = parent; node != null; node = node.parent) {
      if (node is RenderAppTapHost) {
        _host = node.._areas.add(this);
        break;
      }
    }
  }

  @override
  void detach() {
    _host?._areas.remove(this);
    _host = null;
    super.detach();
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) {
    if (_bleed == 0 || !constraints.hasBoundedWidth) return constraints;
    return constraints.copyWith(
      minWidth: constraints.minWidth + 2 * _bleed,
      maxWidth: constraints.maxWidth + 2 * _bleed,
    );
  }

  Size _sizeFor(BoxConstraints constraints, Size childSize) {
    final bled = _bleed != 0 && constraints.hasBoundedWidth;
    return constraints.constrain(
      Size(
        bled ? math.max(0, childSize.width - 2 * _bleed) : childSize.width,
        childSize.height,
      ),
    );
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(0, (child?.getMinIntrinsicWidth(height) ?? 0) - 2 * _bleed);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(0, (child?.getMaxIntrinsicWidth(height) ?? 0) - 2 * _bleed);

  @override
  double computeMinIntrinsicHeight(double width) =>
      child?.getMinIntrinsicHeight(width + 2 * _bleed) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      child?.getMaxIntrinsicHeight(width + 2 * _bleed) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return _sizeFor(
      constraints,
      child.getDryLayout(_childConstraints(constraints)),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryBaseline(_childConstraints(constraints), baseline);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final childConstraints = _childConstraints(constraints);
    child.layout(childConstraints, parentUsesSize: true);
    size = _sizeFor(constraints, child.size);
    final bled = childConstraints != constraints;
    (child.parentData! as BoxParentData).offset = Offset(
      bled ? -_bleed : (size.width - child.size.width) / 2,
      (size.height - child.size.height) / 2,
    );
  }

  Rect get _childRect {
    final child = this.child;
    if (child == null) return Offset.zero & size;
    return (child.parentData! as BoxParentData).offset & child.size;
  }

  /// The area that takes taps, in this box's coordinates: the child's
  /// rect grown to [minSize] around its centre.
  Rect get hitRect {
    final rect = _childRect;
    if (!_mergeSemantics) return rect.inflate(_ring);
    final dx = math.max(0.0, (_minSize.width - rect.width) / 2);
    final dy = math.max(0.0, (_minSize.height - rect.height) / 2);
    return Rect.fromLTRB(
      rect.left - dx,
      rect.top - dy,
      rect.right + dx,
      rect.bottom + dy,
    );
  }

  @override
  Rect get semanticBounds => _mergeSemantics ? hitRect : super.semanticBounds;

  @override
  Rect? describeApproximatePaintClip(RenderObject child) => null;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_mergeSemantics) {
      config
        ..isSemanticBoundary = true
        ..isMergingSemanticsOfDescendants = true;
    }
  }

  /// Above zero while a [AppTapArea.bleed] row tests the exact bounds of its
  /// items: rings are off then, so an item's ring never takes a tap that
  /// lands on its neighbour (the row retries with rings on only when no
  /// item was hit exactly).
  static int _exactOnly = 0;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null || !hitRect.contains(position)) return false;
    final rect = _childRect;
    final childOffset = rect.topLeft;
    bool exact(Offset at) => result.addWithPaintOffset(
      offset: childOffset,
      position: at,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );

    var hit = false;
    if (!_mergeSemantics) {
      // A row: its items exactly first, then with their rings, at the
      // nearest height inside the row.
      _exactOnly++;
      try {
        hit = rect.contains(position) && exact(position);
      } finally {
        _exactOnly--;
      }
      if (!hit) {
        hit = exact(
          Offset(
            position.dx.clamp(rect.left + _inset, rect.right - _inset),
            position.dy.clamp(rect.top + _inset, rect.bottom - _inset),
          ),
        );
      }
    } else if (rect.contains(position)) {
      hit = exact(position);
    } else if (_exactOnly == 0) {
      // In the ring: forward the nearest point inside the child (as
      // Material's _InputPadding forwards its centre).
      final local =
          Offset(
            position.dx.clamp(rect.left + _inset, rect.right - _inset),
            position.dy.clamp(rect.top + _inset, rect.bottom - _inset),
          ) -
          childOffset;
      hit = result.addWithRawTransform(
        transform: MatrixUtils.forceToPoint(local),
        position: local,
        hitTest: (result, _) => child.hitTest(result, position: local),
      );
    }
    if (hit) result.add(BoxHitTestEntry(this, position));
    return hit;
  }

  static const double _inset = 0.5;
}

/// Makes the [AppTapArea]s below it reachable where they poke out of an
/// ancestor's bounds: a row's bleed into the card's gutter, the 2 dp ring
/// above and below a 44 dp row. Put it around a block whose own bounds hold
/// those areas (a post card, with its gutter and its bottom padding).
///
/// A tap that something under the host takes is left alone (so a ring never
/// steals a tap from the post text above the row). Otherwise the host gives
/// it to the tap area whose drawn box contains it, or else to the one whose
/// ring does (the nearest).
class AppTapAreaHost extends SingleChildRenderObjectWidget {
  const AppTapAreaHost({super.key, super.child});

  @override
  RenderAppTapHost createRenderObject(BuildContext context) =>
      RenderAppTapHost();
}

/// The render box of [AppTapAreaHost].
class RenderAppTapHost extends RenderProxyBox {
  RenderAppTapHost({RenderBox? child}) : super(child);

  final Set<RenderAppTapArea> _areas = {};

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    RenderAppTapArea? best;
    Matrix4? bestFromHost;
    var bestDistance = double.infinity;
    for (final area in _areas) {
      if (!area.attached || !area.hasSize) continue;
      final toHost = area.getTransformTo(this);
      final fromHost = Matrix4.tryInvert(toHost);
      if (fromHost == null) continue;
      final local = MatrixUtils.transformPoint(fromHost, position);
      if (!area.hitRect.contains(local)) continue;
      final box = area._childRect;
      // 0 inside the drawn box, else how far into the ring.
      final dx = math.max(
        0.0,
        math.max(box.left - local.dx, local.dx - box.right),
      );
      final dy = math.max(
        0.0,
        math.max(box.top - local.dy, local.dy - box.bottom),
      );
      final distance = dx * dx + dy * dy;
      if (distance < bestDistance) {
        best = area;
        bestFromHost = fromHost;
        bestDistance = distance;
      }
    }
    if (best == null) return false;
    final target = best;
    final hit = result.addWithRawTransform(
      transform: bestFromHost,
      position: position,
      hitTest: (result, local) => target.hitTest(result, position: local),
    );
    if (hit) result.add(BoxHitTestEntry(this, position));
    return hit;
  }
}
