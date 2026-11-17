import 'package:dzeroth/core/widgets/privacy_policy_link.dart';
import 'package:material_ui/material_ui.dart';
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

  test('static pages follow the build origin outside web', () {
    addTearDown(() => staticPagesOrigin = 'https://dzeroth.com');
    staticPagesOrigin = 'https://dzeroth-dev.web.app';
    expect(
      privacyPolicyUri().toString(),
      'https://dzeroth-dev.web.app/privacy.html',
    );
    expect(
      sitePageUri('terms').toString(),
      'https://dzeroth-dev.web.app/terms.html',
    );
    expect(
      communityRulesUri().toString(),
      'https://dzeroth-dev.web.app/rules.html#polls',
    );
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

  group('SiteLinksRow', () {
    for (final (label, page) in const [
      ('Terms', 'terms'),
      ('About', 'about'),
      ('Help centre', 'help'),
    ]) {
      testWidgets('$label opens $page.html', (tester) async {
        await tester.pumpWidget(wrap(const SiteLinksRow()));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        expect(fakeLauncher.lastUrl, 'https://dzeroth.com/$page.html');
      });
    }

    testWidgets('a failed launch is a snackbar, never a throw', (tester) async {
      fakeLauncher.launchResult = false;
      await tester.pumpWidget(wrap(const SiteLinksRow()));
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't open the About page."), findsOneWidget);
    });
  });
}
