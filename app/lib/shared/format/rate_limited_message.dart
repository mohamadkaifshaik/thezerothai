import '../../core/network/app_exception.dart';
import 'coarse_wait.dart';

/// User-facing text for a [RateLimitedException]. A daily limit says it resets
/// later (never "try again in a moment"); a transient one says to wait briefly.
String rateLimitedMessage(RateLimitedException error) {
  if (error.isDaily) {
    final wait = error.retryAfter;
    if (wait == null || wait.inMinutes < 1) {
      return "You've reached today's limit for this. It resets later today.";
    }
    return "You've reached today's limit for this. It resets in about "
        '${coarseWait(wait)}.';
  }
  return "You're doing that a bit too fast. Give it a moment and try again.";
}
