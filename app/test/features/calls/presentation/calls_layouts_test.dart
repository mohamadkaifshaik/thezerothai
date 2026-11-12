import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/calls/presentation/calls_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_rings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/shells_harness.dart';

// Calls from the dzeroth-mobile, tablet and desktop mocks: one coming-soon
// page. The phone centres it over teal rings; the tablet and desktop start it
// at the leading edge under a "Voice · Video" bar subtitle.

const _screenshots = bool.fromEnvironment('CALLS_SCREENSHOTS');

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
  location: AppRouter.callsPath,
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
    final file = File('build/artifacts/calls/$name.png');
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
        expect(find.byType(CallsScreen), findsOneWidget);
        expect(find.text('COMING SOON'), findsOneWidget);
        expect(find.textContaining('coming'), findsOneWidget);
        expect(
          find.text('Voice · Video'),
          phone ? findsNothing : findsOneWidget,
        );
        // Rings behind a centred page on a phone; a leading-edge page after.
        expect(find.byType(AppRings), phone ? findsOneWidget : findsNothing);
        final headline = tester.getRect(find.textContaining('coming'));
        final pane = tester.getRect(find.byType(CallsScreen));
        if (phone) {
          expect(headline.center.dx, closeTo(pane.center.dx, 1));
        } else {
          expect(headline.left - pane.left, lessThan(pane.width / 2));
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('the only button is off; Back leaves for Home', (
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
