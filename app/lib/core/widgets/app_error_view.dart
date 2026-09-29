import 'package:flutter/material.dart';

import '../network/app_exception.dart';
import '../theme/app_theme.dart';

/// Friendly, typed rendering of an [AppException] (CLAUDE.md: "Handle
/// RESOURCE_EXHAUSTED and degraded mode with clear, friendly UI").
///
/// Never shows a raw exception message from an unrecognized source; always
/// branches on the exception type, not on its text.
class AppErrorView extends StatelessWidget {
  const AppErrorView({super.key, required this.error, this.onRetry});

  final AppException error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final (icon, title, canRetry) = switch (error) {
      DegradedModeException() => (
        Icons.cloud_off_outlined,
        'dZeroth is in a limited mode right now. Some actions are paused '
            'to keep the service healthy. Please try again shortly.',
        false,
      ),
      QuotaExceededException() => (
        Icons.hourglass_bottom_outlined,
        "You've hit today's limit for this action. It resets tomorrow.",
        false,
      ),
      RateLimitedException() => (
        Icons.speed_outlined,
        "You're doing that a bit too fast. Give it a moment and try again.",
        false,
      ),
      NetworkException() => (
        Icons.wifi_off_outlined,
        'No connection. Check your network and try again.',
        true,
      ),
      UnauthenticatedException() => (
        Icons.lock_outline,
        'Your session expired. Please sign in again.',
        false,
      ),
      AccountRestrictedException() => (
        Icons.block_outlined,
        'This account is restricted.',
        false,
      ),
      // Byte-identical wording for "missing" and "blocked me" (ADR-0008 D9):
      // never let the UI hint at which one it actually was.
      NotFoundException() => (
        Icons.person_off_outlined,
        "This account doesn't exist.",
        false,
      ),
      TargetBlockedException() => (
        Icons.block_outlined,
        'You blocked this account. Unblock them first to do that.',
        false,
      ),
      FeatureDisabledException() => (
        Icons.hourglass_empty_outlined,
        "This feature isn't available yet.",
        false,
      ),
      _ => (Icons.error_outline, error.message, true),
    };

    return Semantics(
      liveRegion: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: AppSpacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (canRetry && onRetry != null) ...[
                const SizedBox(height: AppSpacing.md),
                FilledButton.tonal(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
