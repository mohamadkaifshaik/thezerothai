import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/presentation/graph_error_messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('relationshipErrorMessage', () {
    test('a transient rate limit says to try again shortly', () {
      expect(
        relationshipErrorMessage(
          const RateLimitedException('x', limitName: 'read_budget_inflight'),
        ),
        contains('Give it a moment'),
      );
    });

    test('a daily rate limit says it resets later, not "in a moment"', () {
      final msg = relationshipErrorMessage(
        const RateLimitedException(
          'x',
          limitName: 'read_budget_daily',
          retryAfter: Duration(hours: 3),
        ),
      );
      expect(msg, contains('resets in about 3 hours'));
      expect(msg, isNot(contains('moment')));
    });

    test('a long retryAfter without a limit name is treated as daily', () {
      final msg = relationshipErrorMessage(
        const RateLimitedException('x', retryAfter: Duration(hours: 2)),
      );
      expect(msg, contains('resets'));
    });

    test('EMAIL_NOT_VERIFIED asks the user to verify', () {
      expect(
        relationshipErrorMessage(const EmailNotVerifiedException('x')),
        contains('verify your email'),
      );
    });
  });

  group('protected accounts (ADR-0025)', () {
    test('a full follow-requests limit has its own words', () {
      final msg = relationshipErrorMessage(
        const LimitReachedException('x', quota: 'follow_requests'),
      );
      expect(msg, contains('follow requests'));
      expect(msg, isNot(contains('limit for this action')));
    });

    test('other limits keep the generic words', () {
      expect(
        relationshipErrorMessage(
          const LimitReachedException('x', quota: 'following'),
        ),
        contains('limit for this action'),
      );
    });

    test('PROTECTED_ACCOUNT never shows the server text', () {
      expect(
        relationshipErrorMessage(const ProtectedAccountException('raw')),
        isNot(contains('raw')),
      );
    });
  });
}
