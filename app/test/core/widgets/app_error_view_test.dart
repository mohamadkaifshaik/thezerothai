import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/widgets/app_error_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(AppException error, {VoidCallback? onRetry}) {
    return MaterialApp(
      home: Scaffold(body: AppErrorView(error: error, onRetry: onRetry)),
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

    expect(
      find.textContaining("You've hit today's limit"),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
  });
}
