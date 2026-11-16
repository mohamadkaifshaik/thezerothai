import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';

/// How a [FollowPill] is painted.
enum FollowPillStyle {
  /// Follow / Follow back: a solid pill (pale on dark, near-black on light).
  filled,

  /// Following / Requested: an outline; on hover or press it reads
  /// [FollowPill.hoverLabel] in red.
  outlined,

  /// Unblock: a solid red pill.
  danger,
}

/// The Follow pill of x.com, for every follow control in the app.
///
/// 32dp tall (36dp when [large]) inside a 48dp hit target; the label wraps
/// the pill, which grows with the text size. A [busy] pill keeps its size and
/// shows a spinner in the label colour; one with a null [onPressed] that is
/// not busy is drawn at 50 %. [onDark] draws it as on the dark theme whatever
/// the theme is (the navy hero).
///
/// It does not announce itself: wrap it in the caller's own [Semantics].
class FollowPill extends StatefulWidget {
  const FollowPill({
    super.key,
    required this.label,
    required this.onPressed,
    this.style = FollowPillStyle.filled,
    this.hoverLabel,
    this.large = false,
    this.busy = false,
    this.onDark = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final FollowPillStyle style;

  /// Shown (red) while the pointer is over the pill or it is pressed; only
  /// the [FollowPillStyle.outlined] style uses it.
  final String? hoverLabel;
  final bool large;
  final bool busy;
  final bool onDark;

  @override
  State<FollowPill> createState() => _FollowPillState();
}

class _FollowPillState extends State<FollowPill> {
  bool _hovered = false;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null && !widget.busy;

  void _set({bool? hovered, bool? pressed}) {
    final h = hovered ?? _hovered;
    final p = pressed ?? _pressed;
    if (h == _hovered && p == _pressed) return;
    setState(() {
      _hovered = h;
      _pressed = p;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = widget.onDark || theme.brightness == Brightness.dark;
    final active = _enabled && (_hovered || _pressed);
    final reveal =
        widget.style == FollowPillStyle.outlined && widget.hoverLabel != null;
    final red = reveal && active;

    final Color fill;
    final Color ink;
    Color? border;
    switch (widget.style) {
      case FollowPillStyle.filled:
        fill = dark ? AppFollowButton.darkFill : AppFollowButton.lightFill;
        ink = dark
            ? AppFollowButton.darkFillText
            : AppFollowButton.lightFillText;
      case FollowPillStyle.danger:
        fill = AppFollowButton.danger;
        ink = AppFollowButton.onDanger;
      case FollowPillStyle.outlined:
        if (red) {
          fill = AppFollowButton.dangerFill;
          ink = AppFollowButton.danger;
          border = AppFollowButton.dangerBorder;
        } else {
          fill = Colors.transparent;
          ink = widget.onDark ? AppPalette.pearl : theme.colorScheme.onSurface;
          border = dark
              ? AppFollowButton.darkBorder
              : AppFollowButton.lightBorder;
        }
    }

    final fontSize = widget.large
        ? AppFollowButton.fontLarge
        : AppFollowButton.fontCompact;
    final text = red ? widget.hoverLabel! : widget.label;
    final label = Text(
      text,
      style: theme.textTheme.labelLarge?.copyWith(
        color: ink,
        fontSize: fontSize,
        fontWeight: FontWeight.w700,
      ),
    );
    // Busy keeps the label laid out (invisible) so the pill does not change
    // size, and draws the spinner over it.
    final Widget content = widget.busy
        ? Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: 0, child: ExcludeSemantics(child: label)),
              SizedBox(
                width: AppFollowButton.spinner,
                height: AppFollowButton.spinner,
                child: CircularProgressIndicator(strokeWidth: 2, color: ink),
              ),
            ],
          )
        : label;

    final pill = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: AppFollowButton.minWidth,
        minHeight: widget.large
            ? AppFollowButton.heightLarge
            : AppFollowButton.heightCompact,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: border == null
              ? null
              : Border.all(color: border, width: AppFollowButton.borderWidth),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppFollowButton.paddingH,
          ),
          child: Center(widthFactor: 1, heightFactor: 1, child: content),
        ),
      ),
    );

    final target = ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: AppSpacing.minTapTarget,
        minHeight: AppSpacing.minTapTarget,
      ),
      child: Center(widthFactor: 1, heightFactor: 1, child: pill),
    );

    return Opacity(
      opacity: _enabled || widget.busy ? 1 : AppFollowButton.disabledOpacity,
      child: FocusableActionDetector(
        enabled: _enabled,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: MouseRegion(
          cursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => _set(hovered: true),
          onExit: (_) => _set(hovered: false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _enabled ? (_) => _set(pressed: true) : null,
            onTapUp: (_) => _set(pressed: false),
            onTapCancel: () => _set(pressed: false),
            onTap: _enabled ? widget.onPressed : null,
            child: target,
          ),
        ),
      ),
    );
  }
}
