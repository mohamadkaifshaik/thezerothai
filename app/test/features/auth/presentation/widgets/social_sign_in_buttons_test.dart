import 'package:dzeroth/features/auth/presentation/widgets/social_sign_in_buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({bool iosAppleEnabled = false}) => MaterialApp(
  home: Scaffold(
    body: SocialSignInButtons(
      isSubmitting: false,
      onGoogleTap: () {},
      onAppleTap: () {},
      appleOnIosEnabled: iosAppleEnabled,
    ),
  ),
);

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('hides Apple but shows Google on iOS by default', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_host());

    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue with Apple'), findsNothing);
    // No leftover spacer: the row holds just the Google pill.
    final row = tester.widget<Row>(
      find
          .descendant(
            of: find.byType(SocialSignInButtons),
            matching: find.byType(Row),
          )
          .first,
    );
    expect(row.children, hasLength(1));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows Apple on iOS when the switch is enabled', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_host(iosAppleEnabled: true));

    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue with Apple'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows Apple on macOS regardless of the iOS switch', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(_host());

    expect(find.bySemanticsLabel('Continue with Apple'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('hides Apple on Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_host());

    expect(find.bySemanticsLabel('Continue with Google'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue with Apple'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('screen readers can activate the provider pills', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var google = 0;
    var apple = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SocialSignInButtons(
            isSubmitting: false,
            onGoogleTap: () => google++,
            onAppleTap: () => apple++,
          ),
        ),
      ),
    );
    for (final label in ['Continue with Google', 'Continue with Apple']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        containsSemantics(isButton: true, hasTapAction: true, isEnabled: true),
      );
    }
    tester.semantics.tap(find.semantics.byLabel('Continue with Google'));
    tester.semantics.tap(find.semantics.byLabel('Continue with Apple'));
    expect((google, apple), (1, 1));
    debugDefaultTargetPlatformOverride = null;
  });
}
