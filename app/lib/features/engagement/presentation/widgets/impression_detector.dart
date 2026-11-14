import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/impression_tracker.dart';
import '../../domain/impression_visibility.dart';

/// Tells the app-wide [ImpressionTracker] that the post of [child] was seen.
///
/// Without a tracker above (tests) or with `post_views` off, it is a plain
/// pass-through that measures nothing.
///
/// Visibility: after each frame in which something may have changed (first
/// build, a scroll of the enclosing [Scrollable], a rebuild), the card's box
/// is measured against that scrollable's viewport and the screen. When at
/// least half of it is inside ([isMostlyVisible]) a [kImpressionDwell] timer
/// starts; when the timer fires the box is measured again and, if it is still
/// mostly visible, the id is reported and the detector goes quiet. Leaving
/// the viewport cancels the timer. No polling: the cost is one rectangle
/// intersection per card per scroll frame, and none once a card is counted.
///
/// [immediate] (the opened post of a detail or thread screen) counts at the
/// first frame, with no geometry.
class ImpressionDetector extends StatefulWidget {
  const ImpressionDetector({
    super.key,
    required this.postId,
    required this.child,
    this.immediate = false,
  });

  final String postId;
  final bool immediate;
  final Widget child;

  @override
  State<ImpressionDetector> createState() => _ImpressionDetectorState();
}

class _ImpressionDetectorState extends State<ImpressionDetector> {
  ImpressionTracker? _tracker;
  ScrollPosition? _position;
  Timer? _dwell;
  bool _queued = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    try {
      _tracker = context.read<ImpressionTracker>();
    } on ProviderNotFoundException {
      _tracker = null;
    }
    _queueCheck();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = _tracker == null || _done
        ? null
        : Scrollable.maybeOf(context)?.position;
    if (!identical(position, _position)) {
      _position?.removeListener(_queueCheck);
      _position = position?..addListener(_queueCheck);
    }
  }

  @override
  void didUpdateWidget(ImpressionDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.postId != widget.postId) {
      _done = false;
      _dwell?.cancel();
      _dwell = null;
    }
    _queueCheck();
  }

  @override
  void dispose() {
    _position?.removeListener(_queueCheck);
    _dwell?.cancel();
    super.dispose();
  }

  void _queueCheck() {
    if (_queued || _done || _tracker == null) return;
    _queued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) _check();
    });
  }

  bool _measuredVisible() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final item = box.localToGlobal(Offset.zero) & box.size;
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    var viewport = screen;
    final scrollBox = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (scrollBox is RenderBox && scrollBox.attached && scrollBox.hasSize) {
      viewport = viewport.intersect(
        scrollBox.localToGlobal(Offset.zero) & scrollBox.size,
      );
    }
    return isMostlyVisible(item, viewport);
  }

  void _check() {
    final tracker = _tracker;
    if (tracker == null || _done) return;
    if (tracker.hasSeen(widget.postId)) {
      _finish();
      return;
    }
    if (!tracker.active) return;
    if (widget.immediate) {
      tracker.markSeen(widget.postId);
      _finish();
      return;
    }
    if (_measuredVisible()) {
      _dwell ??= Timer(kImpressionDwell, _onDwell);
    } else {
      _dwell?.cancel();
      _dwell = null;
    }
  }

  void _onDwell() {
    _dwell = null;
    final tracker = _tracker;
    if (!mounted || tracker == null || _done) return;
    if (_measuredVisible()) {
      tracker.markSeen(widget.postId);
      _finish();
    }
  }

  void _finish() {
    _done = true;
    _dwell?.cancel();
    _dwell = null;
    _position?.removeListener(_queueCheck);
    _position = null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
