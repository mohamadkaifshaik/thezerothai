import 'dart:ui' show Tristate;

import 'package:dzeroth/features/calls/presentation/calls_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

/// The Calls page. Static copy and one disabled button; no action.
void main() {
  group('matrix', () {
    forEachThemeAndWidth('hero and the off button, no overflow', (
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
      expect(find.text('COMING SOON'), findsOneWidget);
      expect(find.textContaining('coming'), findsOneWidget);
      expect(
        find.text("Voice and video calls with people you've met on a plan."),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.call_outlined), findsOneWidget);
      expect(find.text('Not available yet'), findsOneWidget);
    }, textScales: kMatrixTextScalesLarge);
  });

  testWidgets('Back is the only live control; the button is off', (
    tester,
  ) async {
    await pumpThemed(tester, const CallsScreen());
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(TextField), findsNothing);
    final button = tester.widget<AppPillButton>(find.byType(AppPillButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('the off button reads as a disabled button, nothing taps', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, const CallsScreen());
    final data = tester
        .getSemantics(find.bySemanticsLabel('Not available yet'))
        .getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });
}
