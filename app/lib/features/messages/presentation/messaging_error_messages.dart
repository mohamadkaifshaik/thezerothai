import '../../../core/network/app_exception.dart';
import '../../../core/widgets/app_error_view.dart';
import '../domain/messaging_feature_gate.dart';

/// Friendly, typed text for a failed messaging call (ADR-0027 D5), for a
/// snackbar or an inline notice. Branches on the exception type and the
/// limit name, never on the server text, so it never shows (or logs) message
/// content. Never auto-retried by the UI.
String messagingErrorMessage(AppException error) {
  return switch (error) {
    // Fixed text, identical for every cause (D4).
    CannotMessageException() => CannotMessageException.userMessage,
    LimitReachedException(quota: kMessagingLimitRequestUnanswered) =>
      'You can send more once they accept your request',
    LimitReachedException(quota: kMessagingLimitDmNewDaily) =>
      "You've started as many new conversations as allowed today. It resets "
          'tomorrow.',
    LimitReachedException() => "You've reached the limit for messaging.",
    final RateLimitedException e => rateLimitedMessage(e),
    QuotaExceededException() =>
      "You've hit today's limit for messaging. It resets tomorrow.",
    FeatureDisabledException() => "Messages aren't available right now.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. You can read your messages, '
          "but sending and changes are paused. Try again shortly.",
    NetworkException() => 'No connection. Check your network and try again.',
    NotFoundException() => "This conversation isn't available anymore.",
    ValidationException() => "That message can't be sent. Check it and retry.",
    _ => "Couldn't complete that. Please try again.",
  };
}

/// Text of the non-blocking banner the inbox shows over cached conversations
/// when a refresh or page failed (W7-14). Branches on the exception type,
/// never on its text; never auto-retried by the UI.
String conversationsNoticeMessage(AppException error) {
  return switch (error) {
    final RateLimitedException e when e.isDaily =>
      "You've reached today's refresh limit. Showing saved messages; it "
          'resets later today.',
    RateLimitedException() =>
      "You're refreshing too fast. Showing saved messages for a moment.",
    DegradedModeException() =>
      'dZeroth is in a limited mode right now. Showing saved messages.',
    NetworkException() => "You're offline. Showing saved messages.",
    FeatureDisabledException() => "Messages aren't available right now.",
    _ => "Couldn't refresh. Showing saved messages.",
  };
}
