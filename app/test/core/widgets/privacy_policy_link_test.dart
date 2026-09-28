import 'package:dzeroth/core/widgets/privacy_policy_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records calls instead of hitting a real platform channel, so tests never
/// depend on a device/browser being able to open a URL.
class _FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  bool launchResult = true;
  String? lastUrl;
  int launchCount = 0;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastUrl = url;
    launchCount++;
    return launchResult;
  }
}

void main() {
  late _FakeUrlLauncherPlatform fakeLauncher;

  setUp(() {
    fakeLauncher = _FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = fakeLauncher;
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('renders just the link when leadingText is not set', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const PrivacyPolicyLink()));

    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('renders the leading sentence before the link', (tester) async {
    await tester.pumpWidget(
      wrap(
        const PrivacyPolicyLink(leadingText: "By signing up you agree to our "),
      ),
    );

    expect(find.text("By signing up you agree to our "), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('.'), findsOneWidget);
  });

  testWidgets('tapping the link opens the production privacy policy URL', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const PrivacyPolicyLink()));

    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(fakeLauncher.launchCount, 1);
    expect(fakeLauncher.lastUrl, privacyPolicyUrl);
  });

  testWidgets('shows a snackbar when the platform fails to launch', (
    tester,
  ) async {
    fakeLauncher.launchResult = false;

    await tester.pumpWidget(wrap(const PrivacyPolicyLink()));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't open the Privacy Policy."), findsOneWidget);
  });
}
