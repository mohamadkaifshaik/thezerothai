import 'package:dzeroth/features/auth/presentation/widgets/social_sign_in_buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host() => MaterialApp(
  home: Scaffold(
    body: SocialSignInButtons(
      isSubmitting: false,
      onGoogleTap: () {},
      onAppleTap: () {},
    ),
  ),
);

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('shows Google and Apple on iOS (native Apple flow)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_host());

    expect(find.text('Continue with Google'), findsOneWidget);
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
