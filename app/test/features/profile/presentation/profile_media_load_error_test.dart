import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_cover_band.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/failing_image_cache.dart';

/// The profile's avatar when its object is gone from the media bucket (a
/// removed or replaced image is deleted 24-48 h later,
/// `PROFILE_MEDIA_RETIRE`). It shows the placeholder, at the same size as
/// before, and the header does not move by a dp. The download fails the way the bucket answers for a
/// missing object, an HTTP 404 (`useFailingImageCache`).
void main() {
  const widths = <double>[360, 600, 1200];
  const scales = <double>[1.0, 2.0];

  /// The fixture's URLs.
  identity.Profile profile({bool images = true}) => identity.Profile(
    userId: 'u',
    handle: 'kaif',
    displayName: 'Kaif Shaik',
    bio: 'Builds things.',
    location: 'Mumbai, India',
    website: 'https://example.com',
    avatarUrl: images ? 'https://m.test/m/avatar.webp' : '',
    avatarThumbUrl: images ? 'https://m.test/m/avatar_t.webp' : '',
  );

  Widget screen(
    identity.Profile p, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) => MaterialApp(
    theme: buildAppTheme(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: ProfileHeader(
          profile: p,
          isOwnProfile: true,
          graphEnabled: false,
          onEditProfile: () {},
        ),
      ),
    ),
  );

  /// Everything around the band and the avatar that a jump would move.
  ({Size header, double name, Size band, Rect avatar, double handle}) layoutOf(
    WidgetTester tester,
  ) => (
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
    avatar: tester.getRect(find.byType(AppAvatar)),
    handle: tester.getTopLeft(find.text('@kaif')).dy,
  );

  Future<void> size(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('the header with the avatar missing (HTTP 404)', () {
    for (final brightness in Brightness.values) {
      for (final width in widths) {
        for (final scale in scales) {
          testWidgets('${brightness.name} ${width.toInt()}dp x$scale: first '
              'frame, settled and with no avatar at all are the same', (
            tester,
          ) async {
            await size(tester, width);
            final cache = useFailingImageCache();

            await tester.pumpWidget(
              screen(profile(), scale: scale, brightness: brightness),
            );
            final first = layoutOf(tester);

            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            // The request failed with 404, once.
            expect(cache.requested, hasLength(1));
            final settled = layoutOf(tester);

            // The same header with no avatar at all.
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpWidget(
              screen(
                profile(images: false),
                scale: scale,
                brightness: brightness,
              ),
            );
            await tester.pumpAndSettle();
            final none = layoutOf(tester);

            expect(settled, first, reason: 'after the 404');
            expect(none, first, reason: 'with no avatar');
            // 3:1 of the header's own width, reserved from the first frame.
            expect(first.band.width / first.band.height, closeTo(3, 0.02));
          });
        }
      }
    }

    testWidgets('the band is the flat placeholder surface and the avatar is '
        'the person icon', (tester) async {
      await size(tester, 360);
      useFailingImageCache();

      await tester.pumpWidget(screen(profile(), brightness: Brightness.dark));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(ProfileCoverBand));
      final surface = Theme.of(context).colorScheme.surfaceContainerHigh;
      expect(
        find.descendant(
          of: find.byType(ProfileCoverBand),
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == surface,
          ),
        ),
        findsOneWidget,
      );
      // No error icon or text of its own on the band.
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
      expect(
        find.descendant(
          of: find.byType(AppAvatar),
          matching: find.byIcon(Icons.person_outline),
        ),
        findsOneWidget,
      );
    });
  });
}
