import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/widgets/banner_editor.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/edit_profile_harness.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_edit_fixtures.dart';
import '../../../support/theme_harness.dart';

/// Edit profile's `profile_extras` gating and layout (W3-15): without the
/// flag no banner, location or website exists and none can reach a request;
/// with it they show at 360/600/1200 dp, light and dark, without overflow.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  Finder inBanner(IconData icon) => find.descendant(
    of: find.byType(BannerEditor),
    matching: find.byIcon(icon),
  );

  group('flag off', () {
    for (final width in kMatrixWidths) {
      testWidgets('shows no banner, location or website at ${width.toInt()}dp, '
          'and a name save sends none', (tester) async {
        final rig = EditProfileRig(
          profile: editableProfile(
            location: 'Pune',
            website: 'https://a.example',
            banner: true,
          ),
        );
        await openEditProfile(
          tester,
          rig,
          flags: {kFeatureProfileSnapshot, kFeatureMedia},
          size: Size(width, 900),
        );

        expect(find.byType(BannerEditor), findsNothing);
        expect(find.text('Location'), findsNothing);
        expect(find.text('Website'), findsNothing);
        expect(find.text('Display name'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, 'Display name'),
          'Kaif S',
        );
        await tester.pump();
        await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
        await tester.pumpAndSettle();

        final call = rig.repo.calls.single;
        expect(call.displayName, 'Kaif S');
        expect(call.hasExtras, isFalse);
      });
    }
  });

  group('flag on', () {
    forEachThemeAndWidth('shows the banner, location and website, no '
        'overflow, 48dp banner buttons', (tester, env) async {
      final rig = EditProfileRig(profile: editableProfile(banner: true));
      await openEditProfile(
        tester,
        rig,
        flags: extrasFlags,
        size: env.size,
        brightness: env.brightness,
        textScale: env.textScale,
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(BannerEditor), findsOneWidget);
      final band = tester.getSize(find.byType(BannerEditor));
      expect(band.width / band.height, closeTo(3, 0.01));
      for (final icon in [Icons.photo_camera_outlined, Icons.close]) {
        final target = tester.getSize(
          find.ancestor(of: inBanner(icon), matching: find.byType(InkResponse)),
        );
        expect(target.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
        expect(target.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
      await reveal(tester, find.text('Location'));
      expect(find.text('Location'), findsOneWidget);
      await reveal(tester, find.text('Website'));
      expect(find.text('Website'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, textScales: const [1.0, 2.0]);

    testWidgets('320dp at text scale 2.0 does not overflow', (tester) async {
      final rig = EditProfileRig(profile: editableProfile(banner: true));
      await openEditProfile(
        tester,
        rig,
        flags: extrasFlags,
        size: const Size(320, 640),
        textScale: 2,
        brightness: Brightness.dark,
      );

      expect(tester.takeException(), isNull);
      await reveal(tester, find.text('Website'));
      expect(tester.takeException(), isNull);
    });
  });

  group('media off, profile_extras on', () {
    const noMedia = {kFeatureProfileSnapshot, kFeatureProfileExtras};

    testWidgets('location and website show; with no saved banner the band is '
        'left out', (tester) async {
      final rig = EditProfileRig(profile: editableProfile());
      await openEditProfile(tester, rig, flags: noMedia);

      expect(find.byType(BannerEditor), findsNothing);
      expect(find.text('Location'), findsOneWidget);
      expect(find.text('Website'), findsOneWidget);
    });

    testWidgets('a saved banner is shown read-only (no buttons)', (
      tester,
    ) async {
      final rig = EditProfileRig(profile: editableProfile(banner: true));
      await openEditProfile(tester, rig, flags: noMedia);

      expect(find.byType(BannerEditor), findsOneWidget);
      expect(inBanner(Icons.photo_camera_outlined), findsNothing);
      expect(inBanner(Icons.close), findsNothing);
    });

    testWidgets('location and website can still be saved', (tester) async {
      final rig = EditProfileRig(profile: editableProfile());
      await openEditProfile(tester, rig, flags: noMedia);

      await tester.enterText(
        find.widgetWithText(TextField, 'Location'),
        'Pune',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(AppPillButton, 'Save'));
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.location, 'Pune');
      expect(call.bannerMediaId, isNull);
      expect(find.text('settings'), findsOneWidget);
    });
  });
}
