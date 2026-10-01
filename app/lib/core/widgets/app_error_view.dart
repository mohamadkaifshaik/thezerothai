import 'package:flutter/material.dart';

import '../network/app_exception.dart';
import '../theme/app_theme.dart';

/// User-facing text for a [RateLimitedException]. A daily limit says it resets
/// later (never "try again in a moment"); a transient one says to wait briefly.
String rateLimitedMessage(RateLimitedException error) {
  if (error.isDaily) {
    final wait = error.retryAfter;
    if (wait == null || wait.inMinutes < 1) {
      return "You've reached today's limit for this. It resets later today.";
    }
    final text = wait.inHours >= 1
        ? 'in about ${wait.inHours} ${wait.inHours == 1 ? 'hour' : 'hours'}'
        : 'in about ${wait.inMinutes} '
              '${wait.inMinutes == 1 ? 'minute' : 'minutes'}';
    return "You've reached today's limit for this. It resets $text.";
  }
  return "You're doing that a bit too fast. Give it a moment and try again.";
}

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
      final RateLimitedException e => (
        e.isDaily ? Icons.hourglass_bottom_outlined : Icons.speed_outlined,
        rateLimitedMessage(e),
        false,
      ),
      // Provider-not-allowed / unverified-password gates reuse these codes
      // (ADR-0010 D5 A10): EMAIL_NOT_VERIFIED on exempt RPCs.
      EmailNotVerifiedException() => (
        Icons.mark_email_unread_outlined,
        'Please verify your email address to continue.',
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
