import 'package:flutter/material.dart';

import '../../core/network/app_exception.dart';
import '../../core/theme/app_theme.dart';

/// Whether retrying right away can help after [error]: not for a rate limit,
/// the degraded mode or a disabled feature, which only time (or a flag) fixes.
bool noticeCanRetry(AppException error) =>
    error is! RateLimitedException &&
    error is! DegradedModeException &&
    error is! FeatureDisabledException;

/// The non-blocking banner a list shows over its cached rows when a refresh
/// or page failed (also the offline banner: "You're offline. Showing saved
/// posts."), with an optional 48dp Retry. Announced as a live region; it
/// never retries by itself.
class AppNoticeBanner extends StatelessWidget {
  const AppNoticeBanner({super.key, required this.message, this.onRetry});

  final String message;

  /// Shows the Retry action when set.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          border: Border(bottom: BorderSide(color: colors.outlineVariant)),
        ),
        padding: const EdgeInsetsDirectional.only(
          start: AppSpacing.md,
          end: AppSpacing.sm,
          top: AppSpacing.sm,
          bottom: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurface),
              ),
            ),
            if (onRetry != null)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, AppSpacing.minTapTarget),
                ),
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }
}
