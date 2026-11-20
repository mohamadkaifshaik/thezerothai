import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/app_error_view.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_error_messages.dart';
import 'package:dzeroth/features/messages/presentation/messaging_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encryptionErrorMessage', () {
    test('the device limit says how to get out', () {
      expect(
        encryptionErrorMessage(
          const LimitReachedException('x', quota: 'key_devices'),
        ),
        kStatusDeviceLimitBody,
      );
    });

    test('another limit is the generic text', () {
      expect(
        encryptionErrorMessage(const LimitReachedException('x', quota: 'o')),
        "Couldn't complete that. Please try again.",
      );
    });

    test('a rate limit uses the existing retry text', () {
      const e = RateLimitedException('secret', limitName: 'x_daily');
      expect(encryptionErrorMessage(e), rateLimitedMessage(e));
    });

    test('feature disabled, degraded, offline, cannot message', () {
      expect(
        encryptionErrorMessage(const FeatureDisabledException('x')),
        "Encrypted messages aren't available right now.",
      );
      expect(
        encryptionErrorMessage(const DegradedModeException('x')),
        'The app is in a limited mode right now, so this is paused. Please '
        'try again shortly.',
      );
      expect(
        encryptionErrorMessage(const NetworkException('x')),
        'No connection. Check your network and try again.',
      );
      expect(
        encryptionErrorMessage(const CannotMessageException()),
        CannotMessageException.userMessage,
      );
    });

    test('anything else is generic and never the server text', () {
      final text = encryptionErrorMessage(const UnknownApiException('secret'));
      expect(text, "Couldn't complete that. Please try again.");
      expect(text, isNot(contains('secret')));
    });
  });

  group('sendStatusText', () {
    test('sending and waiting', () {
      expect(
        sendStatusText(SendProgress.sending, SendProblem.none, null),
        'Sending…',
      );
      expect(
        sendStatusText(SendProgress.waiting, SendProblem.none, null),
        'Waiting to send',
      );
    });

    test('every not-sent problem', () {
      String t(SendProblem p, [AppException? e]) =>
          sendStatusText(SendProgress.notSent, p, e);
      expect(t(SendProblem.retryable), 'Not sent. Tap to retry');
      expect(t(SendProblem.blocked), 'Not sent');
      expect(
        t(SendProblem.peerHasNoDevice),
        "They can't receive encrypted messages yet",
      );
      expect(t(SendProblem.tryTomorrow), 'Not sent. Try again tomorrow');
      const e = CannotMessageException();
      expect(t(SendProblem.refused, e), messagingErrorMessage(e));
    });

    test(
      'a refusal without a typed reason says Not sent and offers no retry',
      () {
        final text = sendStatusText(
          SendProgress.notSent,
          SendProblem.refused,
          null,
        );
        expect(text, 'Not sent');
        expect(text, isNot(contains('retry')));
      },
    );

    test('a delivered row has no status line', () {
      expect(
        sendStatusText(SendProgress.delivered, SendProblem.none, null),
        '',
      );
    });

    test('none and retryable both offer the retry', () {
      expect(
        sendStatusText(SendProgress.notSent, SendProblem.none, null),
        'Not sent. Tap to retry',
      );
    });
  });

  group('conversationResetErrorMessage', () {
    test('refusals by their reason', () {
      expect(
        conversationResetErrorMessage(
          const ResetRefusedException(ResetRefusal.notAccepted),
        ),
        'You can reset encryption once the request is accepted.',
      );
      expect(
        conversationResetErrorMessage(
          const ResetRefusedException(ResetRefusal.peerHasNoDevice),
        ),
        "They can't receive encrypted messages yet",
      );
    });

    test('an AppException goes through encryptionErrorMessage', () {
      const rate = RateLimitedException('x', limitName: 'reset_daily');
      expect(conversationResetErrorMessage(rate), rateLimitedMessage(rate));
      expect(
        conversationResetErrorMessage(const FeatureDisabledException('x')),
        "Encrypted messages aren't available right now.",
      );
    });

    test('anything else is the reset failure text', () {
      expect(
        conversationResetErrorMessage(StateError('x')),
        kConversationResetFailed,
      );
    });
  });
}
