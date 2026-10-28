import 'package:dzeroth/features/shells/presentation/calls_screen.dart';
import 'package:dzeroth/shared/widgets/app_status_pill.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

/// W8-7: the Calls page. Static copy and two static rows; no action.
void main() {
  group('matrix', () {
    forEachThemeAndWidth('hero, group and both rows, no overflow', (
      tester,
      env,
    ) async {
      await pumpThemed(
        tester,
        const CallsScreen(),
        brightness: env.brightness,
        size: env.size,
        textScale: env.textScale,
      );
      expectNoOverflow(tester);
      expect(find.text('Calls are coming soon'), findsOneWidget);
      expect(
        find.text(
          "Voice and video calls aren't available yet. You can still reach "
          'people by replying to or mentioning them.',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.call_outlined), findsWidgets);
      expect(find.text('Voice calls'), findsOneWidget);
      expect(find.text('Video calls'), findsOneWidget);
      expect(find.byType(AppStatusPill), findsNWidgets(2));
      expect(find.text('Coming soon'), findsNWidgets(2));
    }, textScales: kMatrixTextScalesLarge);
  });

  testWidgets('Back is the only button; nothing to tap but it', (tester) async {
    await pumpThemed(tester, const CallsScreen());
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(InkWell), findsOneWidget); // the IconButton's own
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('rows read once, as non-button text', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, const CallsScreen());
    for (final label in [
      'Voice calls, Coming soon',
      'Video calls, Coming soon',
    ]) {
      final finder = find.bySemanticsLabel(label);
      expect(finder, findsOneWidget, reason: label);
      final data = tester.getSemantics(finder).getSemanticsData();
      expect(data.flagsCollection.isButton, isFalse, reason: label);
      expect(data.hasAction(SemanticsAction.tap), isFalse, reason: label);
    }
    // The pill speaks only through its row.
    expect(find.bySemanticsLabel('Coming soon'), findsNothing);
    handle.dispose();
  });
}
