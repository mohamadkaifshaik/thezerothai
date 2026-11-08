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
  testWidgets('hides Apple but shows Google on iOS by default', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_host());

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsNothing);
    // No leftover spacer: the column holds just the Google button.
    expect(
      find
          .byType(SizedBox)
          .evaluate()
          .where((e) => (e.widget as SizedBox).height == 12),
      isEmpty,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows Apple on iOS when the switch is enabled', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_host(iosAppleEnabled: true));

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows Apple on macOS regardless of the iOS switch', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(_host());

    expect(find.text('Continue with Apple'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('hides Apple on Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_host());

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Apple'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
