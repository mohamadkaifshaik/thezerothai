import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/advertise/presentation/advertise_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_rings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../../support/app_fonts.dart';
import '../../../support/shells_harness.dart';

// Advertise from the dzeroth-mobile, tablet and desktop mocks: one coming-soon
// page. The phone centres it over teal rings; the tablet and desktop start it
// at the leading edge. The button is off ("Not available yet") until the
// contact address is set, then it is "Email us".

const _screenshots = bool.fromEnvironment('ADVERTISE_SCREENSHOTS');

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

const _address = 'comingsoon@dzeroth.com';

final _flags = {...kShellFlags, kFeatureUiTablet};

class _Launcher extends UrlLauncherPlatform {
  final launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

Future<ShellsApp> _open(
  WidgetTester tester,
  Size size, {
  String? address,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) {
  final before = kAdvertisingContactEmail;
  kAdvertisingContactEmail = address;
  addTearDown(() => kAdvertisingContactEmail = before);
  return pumpShellsApp(
    tester,
    location: AppRouter.advertisePath,
    size: size,
    flags: _flags,
    brightness: brightness,
    textScale: textScale,
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/advertise/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;

    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('the look', (tester) async {
        await _open(tester, size);
        expect(find.byType(AdvertiseScreen), findsOneWidget);
        expect(find.text('COMING SOON'), findsOneWidget);
        expect(find.textContaining('coming'), findsOneWidget);
        expect(find.byType(AppRings), phone ? findsOneWidget : findsNothing);
        final headline = tester.getRect(find.textContaining('coming'));
        final pane = tester.getRect(find.byType(AdvertiseScreen));
        if (phone) {
          expect(headline.center.dx, closeTo(pane.center.dx, 1));
        } else {
          expect(headline.left, lessThan(pane.center.dx));
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('no address: the only button is off; Back leaves', (
        tester,
      ) async {
        final app = await _open(tester, size);
        final button = tester.widget<AppPillButton>(find.byType(AppPillButton));
        expect(button.label, 'Not available yet');
        expect(button.onPressed, isNull);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(app.path, AppRouter.homePath);
      });

      testWidgets('address set: Email us opens the mailto', (tester) async {
        final launcher = _Launcher();
        final before = UrlLauncherPlatform.instance;
        UrlLauncherPlatform.instance = launcher;
        addTearDown(() => UrlLauncherPlatform.instance = before);
        await _open(tester, size, address: _address);
        expect(find.text('Want to talk about advertising?'), findsOneWidget);
        await tester.tap(find.text('Email us'));
        await tester.pumpAndSettle();
        expect(launcher.launched, [
          'mailto:$_address?subject=Advertising%20enquiry',
        ]);
      });
    });
  }

  testWidgets('phone, text scale 2.0: nothing overflows', (tester) async {
    await _open(tester, _sizes['phone']!, address: _address, textScale: 2);
    expect(tester.takeException(), isNull);
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('$name ${brightness.name}', (tester) async {
          await _open(tester, size, brightness: brightness);
          await _capture(tester, '$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
