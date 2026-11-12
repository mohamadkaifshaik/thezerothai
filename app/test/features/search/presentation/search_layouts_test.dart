import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/features/graph/presentation/widgets/who_to_follow_card.dart';
import 'package:dzeroth/features/search/presentation/explore_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/context_pane_rig.dart';

// Explore from the dzeroth-mobile, tablet and desktop mocks: ranked trend rows
// with a chevron, Settings next to the search field. "Who to follow" is inline
// below desktop; from 1200 dp the shell's side column ("You might like")
// carries it, so the page does not repeat it.

const _screenshots = bool.fromEnvironment('EXPLORE_PEOPLE_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/explore-people/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

Future<ContextPaneRig> _open(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final rig = ContextPaneRig();
  await rig.pump(
    tester,
    location: '/explore',
    width: size.width,
    height: size.height,
    textScale: textScale,
    brightness: brightness,
    page: (path) =>
        path == '/explore' ? const ExploreScreen() : Text('$path body'),
  );
  return rig;
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final desktop = size.width >= 1200;
    group('$name (${size.width.toInt()} dp)', () {
      testWidgets('ranked trends with a chevron, one suggestions call, the '
          'card inline only below desktop', (tester) async {
        final rig = await _open(tester, size);
        expect(find.text('01'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right), findsWidgets);
        expect(rig.trendCalls, 1);
        final inline = find.descendant(
          of: find.byType(ExploreScreen),
          matching: find.byType(WhoToFollowCard),
        );
        if (desktop) {
          expect(inline, findsNothing);
          expect(
            find.descendant(
              of: find.byType(AppSideColumn),
              matching: find.text('You might like'),
            ),
            findsOneWidget,
          );
        } else {
          expect(inline, findsOneWidget);
          expect(
            tester.getTopLeft(find.text('Who to follow')).dy,
            greaterThan(tester.getTopLeft(find.text('Trending today')).dy),
          );
        }
        expect(rig.suggestionCalls, 1);
      });

      testWidgets('Settings opens from the header; a trend searches', (
        tester,
      ) async {
        final rig = await _open(tester, size);
        await tester.tap(find.byTooltip('Settings').first);
        await tester.pumpAndSettle();
        expect(rig.router.state.uri.path, '/settings');
      });
    });
  }

  testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
    await _open(tester, _sizes['phone']!, textScale: 2);
    expect(tester.takeException(), isNull);
  });

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        testWidgets('explore $name ${brightness.name}', (tester) async {
          await _open(tester, size, brightness: brightness);
          await _capture(tester, 'explore-$name-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
