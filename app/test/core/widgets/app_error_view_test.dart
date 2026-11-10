import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/app_error_view.dart';
import 'package:flutter/material.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/contrast.dart';
import '../../support/theme_harness.dart';

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

  testWidgets('a per-minute RATE_LIMITED says to wait a moment', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(const RateLimitedException('raw', retryAfter: Duration(seconds: 1))),
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
          limitName: 'search_daily',
          retryAfter: Duration(hours: 5, minutes: 10),
        ),
      ),
    );

    expect(find.textContaining('resets in about 6 hours'), findsOneWidget);
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

  // Copy regression guard: PR 2.8 restyles the view, never the words.
  const cases = <(AppException, String, bool)>[
    (
      DegradedModeException('x'),
      'Dzeroth is in a limited mode right now. Some actions are paused '
          'to keep the service healthy. Please try again shortly.',
      false,
    ),
    (
      QuotaExceededException('x'),
      "You've hit today's limit for this action. It resets tomorrow.",
      false,
    ),
    (
      RateLimitedException('x', limitName: 'graph_mutation_daily'),
      "You've reached today's limit for this. It resets later today.",
      false,
    ),
    (
      RateLimitedException('x'),
      "You're doing that a bit too fast. Give it a moment and try again.",
      false,
    ),
    (
      EmailNotVerifiedException('x'),
      'Please verify your email address to continue.',
      false,
    ),
    (
      NetworkException('x'),
      'No connection. Check your network and try again.',
      true,
    ),
    (
      UnauthenticatedException('x'),
      'Your session expired. Please sign in again.',
      false,
    ),
    (AccountRestrictedException('x'), 'This account is restricted.', false),
    (NotFoundException('x'), "This account doesn't exist.", false),
    (
      TargetBlockedException('x'),
      'You blocked this account. Unblock them first to do that.',
      false,
    ),
    (FeatureDisabledException('x'), "This feature isn't available yet.", false),
    // The fallback shows the exception's own message and offers Retry.
    (
      UnknownApiException('Something went wrong. Please try again.'),
      'Something went wrong. Please try again.',
      true,
    ),
    (ValidationException('Bad input'), 'Bad input', true),
  ];

  for (final (error, copy, canRetry) in cases) {
    testWidgets('${error.runtimeType}: exact copy, retry=$canRetry', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(error, onRetry: () {}));
      expect(find.text(copy), findsOneWidget);
      expect(find.text('Retry'), canRetry ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('without onRetry there is no Retry even when retryable', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const NetworkException('x')));
    expect(find.text('Retry'), findsNothing);
  });

  forEachThemeAndWidth(
    'error view: live region, 48dp Retry, error-role icon, no overflow',
    (tester, env) async {
      final handle = tester.ensureSemantics();
      var retries = 0;
      await pumpThemed(
        tester,
        AppErrorView(
          error: const NetworkException('x'),
          onRetry: () => retries++,
        ),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(AppPillButton)).height,
        greaterThanOrEqualTo(48),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      final node = tester.getSemantics(find.byType(AppErrorView));
      expect(node.flagsCollection.isLiveRegion, isTrue);
      final icon = tester.widget<Icon>(find.byType(Icon).first);
      final theme = Theme.of(tester.element(find.byType(AppErrorView)));
      expect(icon.color, theme.colorScheme.error);
      // Danger icon contrast on the page surface (ADR-0033 amendment 1).
      expect(
        contrast(theme.colorScheme.error, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        tester.getSize(find.byType(AppPillButton)).width,
        lessThan(env.size.width < 400 ? env.size.width : 400),
      );
      await expectGolden(tester, find.byType(AppErrorView), 'error_view', env);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
      handle.dispose();
    },
    widths: kRedesignWidths,
    textScales: kRedesignTextScales,
    heights: kRedesignHeights,
  );

  testWidgets('retrying shows the busy state and ignores taps', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppErrorView(
            error: const NetworkException('x'),
            onRetry: () => retries++,
            retrying: true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Retry'));
    expect(retries, 0);
  });
}
