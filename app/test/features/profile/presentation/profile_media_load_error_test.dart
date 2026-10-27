import 'package:cached_network_image/cached_network_image.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_cover_band.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/failing_image_cache.dart';

/// W3-22 M-1 / ADR-0024 Amendment 1 A4 point 5: the profile's banner and
/// avatar when their object is gone from the media bucket (a removed or
/// replaced image is deleted 24-48 h later, `PROFILE_MEDIA_RETIRE`). Both
/// show the flat placeholder, at the same size as before, and the header does
/// not move by a dp. The download fails the way the bucket answers for a
/// missing object, an HTTP 404 (`useFailingImageCache`).
void main() {
  const widths = <double>[360, 600, 1200];
  const scales = <double>[1.0, 2.0];

  /// The fixture's URLs: thumbs below 600 dp, full images from 600 dp.
  identity.Profile profile({bool images = true}) => identity.Profile(
    userId: 'u',
    handle: 'kaif',
    displayName: 'Kaif Shaik',
    bio: 'Builds things.',
    location: 'Mumbai, India',
    website: 'https://example.com',
    bannerUrl: images ? 'https://m.test/m/banner.webp' : '',
    bannerThumbUrl: images ? 'https://m.test/m/banner_t.webp' : '',
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

  group('the header with both images missing (HTTP 404)', () {
    for (final brightness in Brightness.values) {
      for (final width in widths) {
        for (final scale in scales) {
          testWidgets('${brightness.name} ${width.toInt()}dp x$scale: first '
              'frame, settled and with no images at all are the same', (
            tester,
          ) async {
            await size(tester, width);
            final cache = useFailingImageCache();

            await tester.pumpWidget(
              screen(profile(), scale: scale, brightness: brightness),
            );
            // The frame the header is first built: both images asked for.
            expect(find.byType(CachedNetworkImage), findsOneWidget);
            final first = layoutOf(tester);

            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            // Both requests failed with 404, once each.
            expect(cache.requested.toSet(), hasLength(2));
            expect(cache.requested, hasLength(2));
            final settled = layoutOf(tester);

            // The same header with no banner and no avatar at all.
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
            expect(none, first, reason: 'with no images');
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

  group('ProfileCoverBand alone', () {
    Widget band({String url = 'https://m.test/m/b.webp'}) => MaterialApp(
      theme: buildAppTheme(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 100,
            child: ProfileCoverBand(url: url),
          ),
        ),
      ),
    );

    for (final status in [404, 403, 500]) {
      testWidgets('HTTP $status shows the flat surface, 300 x 100 as before', (
        tester,
      ) async {
        final cache = useFailingImageCache(
          manager: FailingImageCacheManager(statusCode: status),
        );
        await tester.pumpWidget(band());
        final loading = tester.getSize(find.byType(ProfileCoverBand));

        await tester.pumpAndSettle();

        expect(cache.requested, isNotEmpty);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(ProfileCoverBand)), loading);
        expect(loading, const Size(300, 100));
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
      });
    }

    testWidgets('a failure with no status (the web loader) is the same', (
      tester,
    ) async {
      useFailingImageCache(
        manager: FailingImageCacheManager(error: Exception('image error')),
      );
      await tester.pumpWidget(band());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(ProfileCoverBand)),
        const Size(300, 100),
      );
    });
  });
}
