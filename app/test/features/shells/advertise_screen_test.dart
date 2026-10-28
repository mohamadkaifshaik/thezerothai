import 'package:dzeroth/features/shells/presentation/advertise_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../support/geometry.dart';
import '../../support/theme_harness.dart';

class _FakeLauncher extends UrlLauncherPlatform {
  _FakeLauncher({this.succeeds = true});

  final bool succeeds;
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => succeeds;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return succeeds;
  }
}

const _address = 'comingsoon@dzeroth.com';
const _mailto = 'mailto:$_address?subject=Advertising%20enquiry';

/// W8-6: the Advertise page. The contact affordance exists only while
/// [kAdvertisingContactEmail] is set (it ships `null`, plan F4).
void main() {
  void useAddress(String? address) {
    final before = kAdvertisingContactEmail;
    kAdvertisingContactEmail = address;
    addTearDown(() => kAdvertisingContactEmail = before);
  }

  Future<_FakeLauncher> pump(
    WidgetTester tester, {
    bool launchSucceeds = true,
    Brightness brightness = Brightness.light,
    Size size = const Size(400, 800),
    double textScale = 1.0,
  }) async {
    final launcher = _FakeLauncher(succeeds: launchSucceeds);
    final before = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = before);
    await pumpThemed(
      tester,
      const AdvertiseScreen(),
      brightness: brightness,
      size: size,
      textScale: textScale,
    );
    return launcher;
  }

  test('ships with the contact address off', () {
    expect(kAdvertisingContactEmail, isNull);
  });

  group('matrix', () {
    for (final address in <String?>[null, _address]) {
      forEachThemeAndWidth(
        'copy shown, no overflow (address ${address ?? 'null'})',
        (tester, env) async {
          useAddress(address);
          await pump(
            tester,
            brightness: env.brightness,
            size: env.size,
            textScale: env.textScale,
          );
          expectNoOverflow(tester);
          expect(find.text('Advertising is coming soon'), findsOneWidget);
          expect(
            find.text(
              "We don't sell ads or promoted posts yet, and there are no ads "
              'in your timeline.',
            ),
            findsOneWidget,
          );
          expect(find.byIcon(Icons.campaign_outlined), findsOneWidget);
          expect(
            find.text('Email us'),
            address == null ? findsNothing : findsOneWidget,
          );
        },
        textScales: kMatrixTextScalesLarge,
      );
    }
  });

  testWidgets('null address: Back is the only button, no contact line', (
    tester,
  ) async {
    useAddress(null);
    await pump(tester);
    expect(find.byType(IconButton), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('Want to talk about advertising?'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
    'address set: one 48dp Email us button opens exactly the mailto',
    (tester) async {
      useAddress(_address);
      final launcher = await pump(tester);
      expect(find.text('Want to talk about advertising?'), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      expectMinTarget(tester, find.byType(TextButton));
      expect(find.byType(TextField), findsNothing);

      await tester.tap(find.text('Email us'));
      await tester.pumpAndSettle();
      expect(launcher.launched, [_mailto]);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'a failing launcher: snackbar and the address as selectable text',
    (tester) async {
      useAddress(_address);
      final launcher = await pump(tester, launchSucceeds: false);
      await tester.tap(find.text('Email us'));
      await tester.pumpAndSettle();
      expect(launcher.launched, [_mailto]);
      expect(find.text("Couldn't open your email app"), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithText(SelectableText, _address),
        ),
        findsOneWidget,
      );
    },
  );
}
