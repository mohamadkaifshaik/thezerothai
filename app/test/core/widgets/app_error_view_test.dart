import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/app_error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(AppException error, {VoidCallback? onRetry}) {
    return MaterialApp(
      home: Scaffold(
        body: AppErrorView(error: error, onRetry: onRetry),
      ),
    );
  }

  testWidgets('degraded mode never shows a retry button', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      wrap(
        const DegradedModeException('limited'),
        onRetry: () => retried = true,
      ),
    );

    expect(find.text('Retry'), findsNothing);
    expect(retried, isFalse);
  });

  testWidgets('a network error shows a working retry button', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      wrap(const NetworkException('offline'), onRetry: () => retried = true),
    );

    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('quota exceeded shows a friendly message, no retry', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const QuotaExceededException('nope')));

    expect(find.textContaining("You've hit today's limit"), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'NotFoundException shows the generic "doesn\'t exist" wording, never '
    'the raw server message (ADR-0008: byte-identical to blocked-by)',
    (tester) async {
      await tester.pumpWidget(wrap(const NotFoundException('raw server text')));

      expect(find.text("This account doesn't exist."), findsOneWidget);
      expect(find.text('raw server text'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    },
  );

  testWidgets('TargetBlockedException shows a friendly message, no retry', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const TargetBlockedException('raw')));

    expect(find.textContaining('Unblock them first'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a transient RATE_LIMITED says to wait a moment', (tester) async {
    await tester.pumpWidget(
      wrap(
        const RateLimitedException(
          'raw',
          limitName: 'read_budget_inflight',
          retryAfter: Duration(seconds: 1),
        ),
      ),
    );

    expect(find.textContaining('Give it a moment'), findsOneWidget);
  });

  testWidgets('a daily RATE_LIMITED says it resets later, not "a moment"', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const RateLimitedException(
          'raw',
          limitName: 'read_budget_daily',
          retryAfter: Duration(hours: 5, minutes: 10),
        ),
      ),
    );

    expect(find.textContaining('resets in about 5 hours'), findsOneWidget);
    expect(find.textContaining('moment'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  test('rateLimitedMessage handles missing retryAfter and minutes', () {
    expect(
      rateLimitedMessage(
        const RateLimitedException('x', limitName: 'check_handle_daily'),
      ),
      contains('resets later today'),
    );
    expect(
      rateLimitedMessage(
        const RateLimitedException(
          'x',
          limitName: 'account_ops_daily',
          retryAfter: Duration(minutes: 1),
        ),
      ),
      contains('in about 1 minute.'),
    );
  });

  testWidgets('EmailNotVerifiedException shows a verify-your-email message', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const EmailNotVerifiedException('raw')));

    expect(find.textContaining('verify your email'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('FeatureDisabledException shows a friendly message, no retry', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const FeatureDisabledException('raw')));

    expect(find.textContaining("isn't available yet"), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
