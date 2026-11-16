import 'package:material_ui/material_ui.dart';

import '../../../core/theme/app_theme.dart';

/// The shared pulse of one skeleton. Blocks below an [AppSkeletonScope] read it
/// and dim and brighten together; a block outside a scope is static.
class _SkeletonPulse extends InheritedNotifier<AnimationController> {
  const _SkeletonPulse({
    required AnimationController controller,
    required super.child,
  }) : super(notifier: controller);

  static double of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_SkeletonPulse>();
    return scope?.notifier?.value ?? 0;
  }
}

/// Wraps skeleton blocks: one pulse for all of them and one announcement.
///
/// The pulse is a slow fade of the hairline tint that stops after a few
/// cycles (a list that is still loading after that is not helped by motion,
/// and it spares the battery). Under reduced motion ([AppMotion.of]) there is
/// no ticker at all: the blocks are static. The whole subtree is hidden from
/// semantics and announced once as [semanticsLabel] ("Loading posts").
class AppSkeletonScope extends StatefulWidget {
  const AppSkeletonScope({
    super.key,
    required this.semanticsLabel,
    required this.child,
  });

  final String semanticsLabel;
  final Widget child;

  /// One full dim-and-brighten cycle.
  static const Duration period = Duration(milliseconds: 1200);

  /// Cycles before the pulse comes to rest.
  static const int cycles = 3;

  @override
  State<AppSkeletonScope> createState() => _AppSkeletonScopeState();
}

class _AppSkeletonScopeState extends State<AppSkeletonScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppSkeletonScope.period ~/ 2,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animate = AppMotion.of(context).movement;
    if (animate && !_started) {
      _started = true;
      // `count` counts each direction, so a cycle is two.
      _controller.repeat(reverse: true, count: AppSkeletonScope.cycles * 2);
    } else if (!animate && _started) {
      _started = false;
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: widget.semanticsLabel,
      child: ExcludeSemantics(
        child: _SkeletonPulse(controller: _controller, child: widget.child),
      ),
    );
  }
}

/// A hairline-tinted placeholder: a rounded bar, or a circle.
///
/// Give it a [width] and [height], or let a parent size it (a
/// `FractionallySizedBox`, an `AspectRatio`).
class AppSkeletonBlock extends StatelessWidget {
  const AppSkeletonBlock({
    super.key,
    this.width,
    this.height,
    this.radius = AppRadius.sm,
    this.circle = false,
  });

  final double? width;
  final double? height;
  final double radius;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final hairline = context.appColors.hairline;
    // Pulse between the full tint and two thirds of it.
    final t = _SkeletonPulse.of(context);
    final tint = hairline.withValues(alpha: hairline.a * (1 - t / 3));
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: tint,
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(radius),
      ),
    );
  }
}

/// A row placeholder: a circular avatar and bars of [barWidths] (fractions of
/// the text column), plus an optional 16:9 media slot under the text.
///
/// Reserves the footprint of the real row so nothing jumps when data arrives.
class AppSkeletonRow extends StatelessWidget {
  const AppSkeletonRow({
    super.key,
    required this.avatarSize,
    required this.barWidths,
    this.mediaSlot = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.sm,
    ),
    this.gap = AppSpacing.md,
  });

  final double avatarSize;
  final List<double> barWidths;
  final bool mediaSlot;
  final EdgeInsetsGeometry padding;

  /// Between the avatar and the text column.
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSkeletonBlock(width: avatarSize, height: avatarSize, circle: true),
          SizedBox(width: gap),
          Expanded(
            child: Column(
              children: [
                for (var i = 0; i < barWidths.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.sm),
                  FractionallySizedBox(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: barWidths[i],
                    child: const AppSkeletonBlock(height: AppSpacing.md),
                  ),
                ],
                if (mediaSlot) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const AspectRatio(
                    aspectRatio: 16 / 9,
                    child: AppSkeletonBlock(radius: AppRadius.cardSmall),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A card placeholder laid out like a feed post card: the header row (a
/// circular avatar beside two name bars) and, under it, the body bars
/// ([barWidths], fractions of the width) and an optional 16:9 media slot
/// all starting at the avatar's left edge
/// and spanning the full width of the card. [AppSkeletonRow] keeps the
/// indented body for the rows that draw a rail beside the avatar.
class AppSkeletonCard extends StatelessWidget {
  const AppSkeletonCard({
    super.key,
    required this.avatarSize,
    required this.barWidths,
    this.mediaSlot = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.sm,
    ),
    this.gap = AppSpacing.md,
  });

  final double avatarSize;
  final List<double> barWidths;
  final bool mediaSlot;
  final EdgeInsetsGeometry padding;

  /// Between the avatar and the name bars.
  final double gap;

  /// The name bars' widths (fractions of the space beside the avatar).
  static const List<double> nameBarWidths = [0.4, 0.25];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppSkeletonBlock(
                width: avatarSize,
                height: avatarSize,
                circle: true,
              ),
              SizedBox(width: gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < nameBarWidths.length; i++) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.sm),
                      FractionallySizedBox(
                        widthFactor: nameBarWidths[i],
                        child: const AppSkeletonBlock(height: AppSpacing.md),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.smd),
          for (var i = 0; i < barWidths.length; i++) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            FractionallySizedBox(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: barWidths[i],
              child: const AppSkeletonBlock(height: AppSpacing.md),
            ),
          ],
          if (mediaSlot) ...[
            const SizedBox(height: AppSpacing.smd),
            const AspectRatio(
              aspectRatio: 16 / 9,
              child: AppSkeletonBlock(radius: AppRadius.cardSmall),
            ),
          ],
        ],
      ),
    );
  }
}
