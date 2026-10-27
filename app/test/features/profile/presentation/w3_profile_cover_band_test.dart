import 'dart:typed_data';

import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_cover_band.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/media_fixtures.dart';

/// W3-21: the on-device picture of Edit profile (`ProfileCoverBand(bytes:)`),
/// the one banner source that decodes in a widget test (a network banner
/// cannot: see `w3_profile_banner_layout_test.dart`). It lives in its own file
/// because decoding needs real time (`tester.runAsync`), and real time must not
/// run in a file that also builds a `CachedNetworkImage`: its cache manager
/// asks the path_provider plugin, which does not exist in the VM, and the
/// error surfaces in whatever test happens to be running.
void main() {
  const widths = <double>[360, 600, 1200];

  /// Lets real time pass until [done] holds (the codec runs outside the fake
  /// clock), polling instead of sleeping a fixed time, for at most 2 s.
  Future<void> eventually(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Finder flatSurface() => find.descendant(
    of: find.byType(ProfileCoverBand),
    matching: find.byWidgetPredicate(
      (w) =>
          w is ColoredBox &&
          w.color == appLightTheme.colorScheme.surfaceContainerHigh,
    ),
  );

  group('the on-device picture (Edit profile preview)', () {
    Widget band(double width, Uint8List? bytes) => MaterialApp(
      theme: appLightTheme,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: width / 3,
            child: ProfileCoverBand(bytes: bytes),
          ),
        ),
      ),
    );

    for (final width in widths) {
      testWidgets('${width.toInt()}dp: decoding the picture keeps the 3:1 '
          'band and fills it', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(band(width, null));
        final flat = tester.getSize(find.byType(ProfileCoverBand));
        expect(flatSurface(), findsOneWidget);

        await tester.pumpWidget(band(width, fakeProcessed().thumbBytes));
        expect(tester.getSize(find.byType(ProfileCoverBand)), flat);
        await eventually(
          tester,
          () =>
              find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage)).image != null,
        );

        // Decoded for real: a RawImage that holds pixels, filling the band.
        final raw = tester.widget<RawImage>(find.byType(RawImage));
        expect(raw.image, isNotNull, reason: 'the picture decoded');
        expect(tester.getSize(find.byType(RawImage)), flat);
        expect(tester.getSize(find.byType(ProfileCoverBand)), flat);
        expect(flat.width / flat.height, closeTo(3, 0.01));
        expect(flatSurface(), findsNothing);
      });

      testWidgets('${width.toInt()}dp: corrupt bytes fall back to the flat '
          'surface in the same box', (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(band(width, null));
        final flat = tester.getSize(find.byType(ProfileCoverBand));

        await tester.pumpWidget(
          band(width, Uint8List.fromList(const [1, 2, 3, 4])),
        );
        await eventually(tester, () => flatSurface().evaluate().isNotEmpty);

        expect(tester.getSize(find.byType(ProfileCoverBand)), flat);
        expect(flatSurface(), findsOneWidget);
      });
    }
  });
}
