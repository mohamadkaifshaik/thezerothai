import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/widgets/shell_bottom_inset_sliver.dart';
import '../../../../core/widgets/shell_geometry.dart';
import '../../../../shared/widgets/primitives/app_main_column.dart';
import '../bloc/trending_paged_cubit.dart';

/// Wraps one content sliver of a Trending section in the reading column.
typedef TrendingSliverWrap = Widget Function(Widget sliver);

/// The scroll view of one Trending section (Posts or Media), shared by the
/// phone/tablet inner views and the desktop panes.
///
/// - Starts with the [leading] slivers; ends with [ShellBottomInsetSliver].
/// - Asks [cubit] for the next rows near the end of the list and when the
///   rows do not fill the view, only while [active] and only when the cubit
///   allows it (never while stalled, failed or rate limited: the "Load
///   more" and Retry buttons ask then).
/// - Jumps to the top when the cubit restarted the list after an expired
///   token.
/// - Rebuilds from [cubit]'s state; [slivers] draws it. Content slivers are
///   passed through the `wrap` it is given, so on a tablet they sit in the
///   reading column.
class TrendingSectionScroll extends StatefulWidget {
  const TrendingSectionScroll({
    super.key,
    required this.cubit,
    required this.slivers,
    this.active = true,
    this.leading = const [],
    this.controller,
  });

  final PagedTrendingCubit<Object?> cubit;

  /// The content slivers for the cubit's current state.
  final List<Widget> Function(BuildContext context, TrendingSliverWrap wrap)
  slivers;

  /// Whether this section is the one on screen (a section kept alive behind
  /// the other asks for nothing).
  final bool active;

  /// Slivers above the content (Explore's header on a phone or tablet),
  /// drawn as given: the caller insets them.
  final List<Widget> leading;

  /// The scroll controller (the section's offset, kept by its owner).
  final ScrollController? controller;

  @override
  State<TrendingSectionScroll> createState() => _TrendingSectionScrollState();
}

class _TrendingSectionScrollState extends State<TrendingSectionScroll> {
  BuildContext? _probe;

  /// The restarts of the list (expired token) already answered with a jump.
  late int _lastSerial = widget.cubit.snapshot.resetSerial;

  @override
  void initState() {
    super.initState();
    _checkAfterFrame();
  }

  @override
  void didUpdateWidget(TrendingSectionScroll old) {
    super.didUpdateWidget(old);
    if (old.cubit != widget.cubit) {
      _lastSerial = widget.cubit.snapshot.resetSerial;
    }
    if (!old.active && widget.active) _checkAfterFrame();
  }

  ScrollPosition? get _position {
    final probe = _probe;
    if (probe == null || !probe.mounted) return null;
    return Scrollable.maybeOf(probe)?.position;
  }

  /// After a frame: ask when the rows leave nothing to scroll or the end is
  /// near.
  void _checkAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final position = _position;
      if (position == null || !position.hasContentDimensions) return;
      _maybeAsk(position.extentAfter, position.viewportDimension);
    });
  }

  void _maybeAsk(double extentAfter, double viewport) {
    if (!mounted || !widget.active) return;
    if (!widget.cubit.snapshot.canAutoLoad) return;
    if (extentAfter < viewport) unawaited(widget.cubit.loadMore());
  }

  bool _onNotification(Notification n) {
    final ScrollMetrics? metrics = switch (n) {
      ScrollNotification() => n.depth == 0 ? n.metrics : null,
      ScrollMetricsNotification() => n.metrics,
      _ => null,
    };
    if (metrics == null || metrics.axis != Axis.vertical) return false;
    final extentAfter = metrics.extentAfter;
    final viewport = metrics.viewportDimension;
    // Not while the tree is laying out: the cubit emits at once.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeAsk(extentAfter, viewport),
    );
    return false;
  }

  void _jumpToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final position = _position;
      if (mounted && position != null && position.pixels != 0) {
        position.jumpTo(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<PagedTrendingCubit<Object?>, Object?>(
      bloc: widget.cubit,
      listenWhen: (before, after) =>
          widget.cubit.snapshot.resetSerial != _lastSerial,
      listener: (context, _) {
        _lastSerial = widget.cubit.snapshot.resetSerial;
        _jumpToTop();
      },
      child: BlocBuilder<PagedTrendingCubit<Object?>, Object?>(
        bloc: widget.cubit,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final inset = ShellGeometry.readableInset(
              context,
              constraints.maxWidth,
            );
            Widget wrap(Widget sliver) => inset == 0
                ? sliver
                : SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: AppMainColumnBleed(bleed: inset, child: sliver),
                  );
            return NotificationListener<Notification>(
              onNotification: _onNotification,
              child: CustomScrollView(
                controller: widget.controller,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  ...widget.leading,
                  SliverToBoxAdapter(
                    child: Builder(
                      builder: (context) {
                        _probe = context;
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                  ...widget.slivers(context, wrap),
                  const ShellBottomInsetSliver(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
