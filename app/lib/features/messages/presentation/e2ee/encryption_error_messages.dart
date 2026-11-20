import '../../../../core/network/app_exception.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../messaging_error_messages.dart';
import '../widgets/outgoing_bubble.dart';
import 'encryption_copy.dart';

const _featureDisabledText = "Encrypted messages aren't available right now.";
const _degradedText =
    'The app is in a limited mode right now, so this is paused. Please try '
    'again shortly.';
const _networkText = 'No connection. Check your network and try again.';
const _genericText = "Couldn't complete that. Please try again.";

/// Friendly, typed text for a failed encryption action (device list, removal, set up again, conversation reset,
/// security code). Branches on the exception type only; never shows or logs the server text.
String encryptionErrorMessage(AppException error) {
  return switch (error) {
    LimitReachedException(quota: 'key_devices') => kStatusDeviceLimitBody,
    final RateLimitedException e => rateLimitedMessage(e),
    FeatureDisabledException() => _featureDisabledText,
    DegradedModeException() => _degradedText,
    NetworkException() => _networkText,
    CannotMessageException() => CannotMessageException.userMessage,
    _ => _genericText,
  };
}

/// The text of a failed conversation reset (Task 5): `ResetRefusedException` by its reason, an AppException through
/// encryptionErrorMessage, anything else kConversationResetFailed.
String conversationResetErrorMessage(Object error) {
  return switch (error) {
    final ResetRefusedException e => switch (e.reason) {
      ResetRefusal.notAccepted => kConversationResetNotAcceptedText,
      ResetRefusal.peerHasNoDevice => kStatePeerNoDeviceText,
    },
    final AppException e => encryptionErrorMessage(e),
    _ => kConversationResetFailed,
  };
}

/// The status line of an own row that is not delivered (Task 4). A delivered row has no status line (empty).
/// Exhaustive over both enums: a new value is a compile error here, never a silent "Tap to retry".
String sendStatusText(
  SendProgress progress,
  SendProblem problem,
  AppException? error,
) {
  return switch (progress) {
    SendProgress.delivered => '',
    SendProgress.sending => kOutgoingSendingText,
    SendProgress.waiting => kOutgoingWaitingText,
    SendProgress.notSent => switch (problem) {
      SendProblem.none || SendProblem.retryable => kOutgoingNotSentText,
      SendProblem.blocked => kOutgoingNotSentBlockedText,
      SendProblem.peerHasNoDevice => kStatePeerNoDeviceText,
      SendProblem.tryTomorrow => kOutgoingTryTomorrowText,
      // A refusal is definitive: with no typed reason the row says "Not sent" and promises no retry.
      SendProblem.refused =>
        error == null
            ? kOutgoingNotSentBlockedText
            : messagingErrorMessage(error),
    },
  };
}
