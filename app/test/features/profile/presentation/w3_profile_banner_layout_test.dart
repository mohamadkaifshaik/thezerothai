import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_cover_band.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/w3_profile_rig.dart';

/// W3-21: the profile banner loads without a layout jump (ADR-0024 D2,
/// W3-14: "flat placeholder while loading, no layout jump").
///
/// The mechanism under test: `ProfileHeader` gives the band a fixed
/// `width / 3` box, so no state of the image (not requested, loading, loaded,
/// failed with a 403 or a 404) can change what is laid out around it. A
/// widget test cannot load a network image (every request answers 400, and the
/// cache manager needs platform plugins), and `ProfileCoverBand` has no seam
/// for a fake one, so this file checks the contract in three parts instead:
/// the whole screen with a banner URL at every stage the image can be in (the
/// frame the profile arrives, settled, two seconds later, and with no banner at
/// all), the header when the banner arrives, changes or goes after the first
/// layout (an edit), and the failure fallback being the placeholder's own
/// surface. A 403 and a 404 are the same case at this level: both go to
/// `errorWidget`. The decoded (and corrupt) on-device picture of Edit profile,
/// the one source that does decode in a widget test, is in
/// `w3_profile_cover_band_test.dart` (it needs real time, which must not run
/// in a file that builds a `CachedNetworkImage`).
void main() {
  late W3ProfileRig rig;

  setUpAll(W3ProfileRig.registerFallbacks);
  setUp(() => rig = W3ProfileRig());
  tearDown(() => rig.dispose());

  const widths = <double>[360, 600, 1200];
  const scales = <double>[1.0, 2.0];

  /// Everything around the band that a jump would move.
  ({Size header, double name, Size band}) layoutOf(WidgetTester tester) => (
    header: tester.getSize(find.byType(ProfileHeader)),
    name: tester
        .getTopLeft(
          find.descendant(
            of: find.byType(ProfileHeader),
            matching: find.text('Kaif Shaik'),
          ),
        )
        .dy,
    band: tester.getSize(find.byType(ProfileCoverBand)),
  );

  group('the screen, banner URL present', () {
    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('${width.toInt()}dp x$scale: the same header before, '
            'while and after the image resolves, and with no banner at all', (
          tester,
        ) async {
          final size = Size(width, 800);
          rig.arrange(profile: w3Profile(W3ProfileRig.target));
          await rig.open(tester, size: size, textScale: scale, settle: false);
          // The profile arrives; the image has only just been asked for.
          await tester.pump();
          await tester.pump();
          expect(find.byType(ProfileHeader), findsOneWidget);
          expect(find.byType(CachedNetworkImage), findsOneWidget);
          final first = layoutOf(tester);

          await tester.pumpAndSettle();
          final settled = layoutOf(tester);
          // Fake time only: the cache manager needs a plugin that does not
          // exist in the VM, and real time would surface its error here.
          await tester.pump(const Duration(seconds: 2));
          final late = layoutOf(tester);
          expect(tester.takeException(), isNull);

          expect(settled, first, reason: 'after settling');
          expect(late, first, reason: 'two seconds later');
          // 3:1 of the header's own width, reserved from the first frame.
          expect(first.band.width / first.band.height, closeTo(3, 0.02));
          expect(first.band.width, first.header.width);

          // The same screen without a banner: not one dp apart.
          await tester.pumpWidget(const SizedBox.shrink());
          rig.arrange(
            profile: w3Profile(
              W3ProfileRig.target,
              banner: '',
              bannerThumb: '',
            ),
          );
          await rig.open(tester, size: size, textScale: scale);
          expect(find.byType(CachedNetworkImage), findsNothing);
          expect(layoutOf(tester), first, reason: 'no banner at all');
        });
      }
    }
  });

  group('the header, banner arriving after the first layout', () {
    Widget header(String banner, double scale) => MaterialApp(
      theme: appLightTheme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProfileHeader(
            profile: w3Profile(
              'u',
              banner: banner,
              bannerThumb: banner.isEmpty ? '' : '$banner?thumb',
            ),
            isOwnProfile: true,
            graphEnabled: false,
            onEditProfile: () {},
          ),
        ),
      ),
    );

    for (final width in widths) {
      for (final scale in scales) {
        testWidgets('${width.toInt()}dp x$scale: adding, replacing and '
            'removing a banner moves nothing', (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(header('', scale));
          final none = layoutOf(tester);
          expect(find.byType(CachedNetworkImage), findsNothing);

          await tester.pumpWidget(header('https://m.test/one.webp', scale));
          expect(find.byType(CachedNetworkImage), findsOneWidget);
          expect(layoutOf(tester), none, reason: 'added');

          await tester.pumpWidget(header('https://m.test/two.webp', scale));
          await tester.pump();
          expect(layoutOf(tester), none, reason: 'replaced');

          await tester.pumpWidget(header('', scale));
          expect(layoutOf(tester), none, reason: 'removed');
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group(
    'a failed image (403 or 404) falls back to the placeholder surface',
    () {
      for (final brightness in Brightness.values) {
        testWidgets('${brightness.name}: errorWidget and placeholder are the '
            'same flat surfaceContainerHigh band', (tester) async {
          rig.arrange(profile: w3Profile(W3ProfileRig.target));
          await rig.open(
            tester,
            size: const Size(360, 800),
            brightness: brightness,
          );

          final image = tester.widget<CachedNetworkImage>(
            find.byType(CachedNetworkImage),
          );
          final context = tester.element(find.byType(CachedNetworkImage));
          final surface = Theme.of(context).colorScheme.surfaceContainerHigh;
          final placeholder = image.placeholder!(context, image.imageUrl);
          expect(placeholder, isA<ColoredBox>());
          expect((placeholder as ColoredBox).color, surface);
          for (final failure in <Object>[
            Exception('HTTP 404'),
            Exception('HTTP 403'),
            Exception('connection closed'),
          ]) {
            final fallback = image.errorWidget!(
              context,
              image.imageUrl,
              failure,
            );
            expect(fallback, isA<ColoredBox>(), reason: '$failure');
            expect((fallback as ColoredBox).color, surface, reason: '$failure');
          }
          // And the band itself shows no error icon or text of its own.
          expect(
            find.descendant(
              of: find.byType(ProfileCoverBand),
              matching: find.byType(Icon),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(ProfileCoverBand),
              matching: find.byType(Text),
            ),
            findsNothing,
          );
        });
      }
    },
  );
}
