import 'package:material_ui/material_ui.dart';

import '../../../core/network/app_exception.dart';
import '../../../core/theme/app_theme.dart';
import 'app_pill_button.dart';

/// Whether retrying right away can help after [error]: not for a rate limit,
/// the degraded mode or a disabled feature, which only time (or a flag) fixes.
bool noticeCanRetry(AppException error) =>
    error is! RateLimitedException &&
    error is! DegradedModeException &&
    error is! FeatureDisabledException;

/// The non-blocking banner a list shows over its cached rows when a refresh
/// or page failed (also the offline banner: "You're offline. Showing saved
/// posts."), with an optional 48dp text Retry. Announced as a live region; it
/// never retries by itself. Without [onRetry] it is the degraded-mode banner:
/// no Retry, because only time fixes it.
///
/// Opt-in [actionLabel]: a banner whose one action has another label (and no
/// Retry). It keeps the same margins, border and live region; at a large
/// text scale (1.5 and up) the action goes under the message so a long line
/// keeps the width. A banner without [actionLabel] is unchanged.
class AppNoticeBanner extends StatelessWidget {
  const AppNoticeBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.retrying = false,
    this.actionLabel,
    this.onAction,
  }) : assert(
         actionLabel == null || onRetry == null,
         'an action label replaces Retry',
       );

  final String message;

  /// Shows the Retry action when set.
  final VoidCallback? onRetry;

  /// A retry is running: the Retry action shows progress and ignores taps.
  final bool retrying;

  /// Opt-in: the label of a text action in place of Retry. Null: no such
  /// action. With a label and a null [onAction] the action shows disabled.
  final String? actionLabel;

  /// Called by the [actionLabel] action.
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final text = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colors.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final label = actionLabel;
    final Widget child;
    if (label != null) {
      final action = AppPillButton(
        label: label,
        variant: AppButtonVariant.text,
        onPressed: onAction,
      );
      // A large text scale puts the action under the message, so the message
      // keeps the width (a long line would otherwise wrap into a thin column).
      final stacked = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
      child = stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                text,
                Align(alignment: AlignmentDirectional.centerEnd, child: action),
              ],
            )
          : Row(
              children: [
                Expanded(child: text),
                action,
              ],
            );
    } else {
      child = Row(
        children: [
          Expanded(child: text),
          if (onRetry != null)
            AppPillButton(
              label: 'Retry',
              variant: AppButtonVariant.text,
              onPressed: onRetry,
              busy: retrying,
              busySemanticsLabel: retrying ? 'Retrying' : null,
            ),
        ],
      );
    }
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: context.appColors.uiBorder),
        ),
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.md,
          end: AppSpacing.sm,
          top: AppSpacing.xs,
          bottom: AppSpacing.xs,
        ),
        child: child,
      ),
    );
  }
}
