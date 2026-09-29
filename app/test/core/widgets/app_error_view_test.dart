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

  testWidgets('FeatureDisabledException shows a friendly message, no retry', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const FeatureDisabledException('raw')));

    expect(find.textContaining("isn't available yet"), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
