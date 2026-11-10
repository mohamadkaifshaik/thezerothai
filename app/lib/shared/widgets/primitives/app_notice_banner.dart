import 'package:flutter/material.dart';

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
class AppNoticeBanner extends StatelessWidget {
  const AppNoticeBanner({super.key, required this.message, this.onRetry});

  final String message;

  /// Shows the Retry action when set.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
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
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (onRetry != null)
              AppPillButton(
                label: 'Retry',
                variant: AppButtonVariant.text,
                onPressed: onRetry,
              ),
          ],
        ),
      ),
    );
  }
}
