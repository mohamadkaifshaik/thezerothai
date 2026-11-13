import '../../../core/network/app_exception.dart';
import '../domain/messaging_feature_flag.dart';
import 'messaging_error_messages.dart';

/// Whether [error] ends the whole share, not just one recipient: the post
/// itself (not found, protected, a bad id), the caption, the caller's flag,
/// a rate limit, the read-only mode or a lost connection. The same send to the
/// next person would fail the same way, so the cubit stops and marks the rest
/// "Not sent".
///
/// A refused recipient (CANNOT_MESSAGE, a LIMIT_REACHED variant) is not
/// whole-share: the next person may be fine.
bool sharePostErrorEndsShare(AppException error) => switch (error) {
  NotFoundException() ||
  ProtectedAccountException() ||
  ValidationException() ||
  FeatureDisabledException() ||
  RateLimitedException() ||
  QuotaExceededException() ||
  DegradedModeException() ||
  NetworkException() => true,
  _ => false,
};

/// Friendly, typed text for a failed share send, for the line under the rows.
/// Branches on the exception type and `metadata["feature"]`, never on server
/// text. NOT_FOUND means the post here (the recipient is named by id, and an
/// unreachable one is CANNOT_MESSAGE).
String sharePostErrorMessage(AppException error) {
  return switch (error) {
    NotFoundException() => "This post isn't available anymore.",
    ProtectedAccountException() =>
      "Only the author can send a protected account's post in a message.",
    FeatureDisabledException(feature: kFeatureDmPostShare) =>
      "Sending a post in a message isn't available right now.",
    ValidationException() => "That post can't be sent. Check it and retry.",
    _ => messagingErrorMessage(error),
  };
}

/// The short reason beside a failed row ("Can't send", "Limit reached"); the
/// full text of [sharePostErrorMessage] goes to the line below and to
/// assistive technology.
String sharePostRowReason(AppException error) => switch (error) {
  CannotMessageException() => "Can't send",
  LimitReachedException() || QuotaExceededException() => 'Limit reached',
  RateLimitedException() => 'Too fast',
  NetworkException() => 'No connection',
  _ => 'Not sent',
};
