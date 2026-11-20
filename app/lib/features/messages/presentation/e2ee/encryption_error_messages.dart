import '../../../../core/network/app_exception.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../domain/e2ee/encrypted_messaging.dart';
import '../messaging_error_messages.dart';
import '../widgets/outgoing_bubble.dart';
import 'encryption_copy.dart';

/// Friendly, typed text for a failed encryption action (device list, removal, set up again, conversation reset,
/// security code). Branches on the exception type only; never shows or logs the server text.
String encryptionErrorMessage(AppException error) {
  return switch (error) {
    LimitReachedException(quota: 'key_devices') => kStatusDeviceLimitBody,
    final RateLimitedException e => rateLimitedMessage(e),
    FeatureDisabledException() =>
      "Encrypted messages aren't available right now.",
    DegradedModeException() =>
      'The app is in a limited mode right now, so this is paused. Please try '
          'again shortly.',
    NetworkException() => 'No connection. Check your network and try again.',
    CannotMessageException() => CannotMessageException.userMessage,
    _ => "Couldn't complete that. Please try again.",
  };
}

/// The text of a failed conversation reset (Task 5): `ResetRefusedException` by its reason, an AppException through
/// encryptionErrorMessage, anything else kConversationResetFailed.
String conversationResetErrorMessage(Object error) {
  return switch (error) {
    ResetRefusedException(reason: ResetRefusal.notAccepted) =>
      kConversationResetNotAcceptedText,
    ResetRefusedException(reason: ResetRefusal.peerHasNoDevice) =>
      kStatePeerNoDeviceText,
    final AppException e => encryptionErrorMessage(e),
    _ => kConversationResetFailed,
  };
}

/// The status line of an own row that is not delivered (Task 4). A delivered row has no status line (empty).
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
      SendProblem.blocked => kOutgoingNotSentBlockedText,
      SendProblem.peerHasNoDevice => kStatePeerNoDeviceText,
      SendProblem.tryTomorrow => kOutgoingTryTomorrowText,
      SendProblem.refused when error != null => messagingErrorMessage(error),
      // retryable, none, and a refusal that carries no typed reason: the row can be retried.
      _ => kOutgoingNotSentText,
    },
  };
}
