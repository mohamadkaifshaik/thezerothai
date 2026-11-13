import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/creator_studio/presentation/creator_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/shells_harness.dart';

// Creator Studio from the dzeroth-mobile, tablet and desktop mocks: the same
// stat cards and coming-soon groups. The phone has the "Your account"
// eyebrow and raised groups; the tablet and desktop have the "Creator tools"
// eyebrow, the bar's subtitle and flat boxes.

const _screenshots = bool.fromEnvironment('STUDIO_SCREENSHOTS');

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

final _flags = {...kShellFlags, kFeatureUiTablet};

Future<ShellsApp> _open(
  WidgetTester tester,
  Size size, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => pumpShellsApp(
  tester,
  location: AppRouter.creatorStudioPath,
  size: size,
  flags: _flags,
  brightness: brightness,
  textScale: textScale,
);

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/studio/$name.png');
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
        expect(find.byType(CreatorStudioScreen), findsOneWidget);
        expect(
          find.text(phone ? 'YOUR ACCOUNT' : 'CREATOR TOOLS'),
          findsOneWidget,
        );
        // On the desktop the Settings categories are beside the page and
        // say "Your account" and "Your reach" too: look inside the page.
        final page = find.byType(CreatorStudioScreen);
        Finder onPage(Finder f) => find.descendant(of: page, matching: f);
        expect(onPage(find.textContaining('reach')), findsOneWidget);
        // The bar's subtitle is the wide look's only.
        expect(
          onPage(find.text('Your account')),
          phone ? findsNothing : findsOneWidget,
        );
        for (final label in ['Followers', 'Following', 'Posts']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(find.text('INSIGHTS'), findsOneWidget);
        expect(find.text('PROGRAMS'), findsOneWidget);
        // Two stat cards side by side in both looks.
        final followers = tester.getRect(find.text('Followers'));
        final following = tester.getRect(find.text('Following'));
        expect(followers.top, following.top);
        expect(followers.left, lessThan(following.left));
        expect(tester.takeException(), isNull);
      });

      testWidgets('Back leaves for Home, as everywhere', (tester) async {
        final app = await _open(tester, size);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(app.path, AppRouter.homePath);
      });
    });
  }

  testWidgets('phone, text scale 2.0: nothing overflows', (tester) async {
    await _open(tester, _sizes['phone']!, textScale: 2);
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
