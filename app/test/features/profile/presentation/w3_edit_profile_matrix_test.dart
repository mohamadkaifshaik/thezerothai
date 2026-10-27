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
import '../../../support/geometry.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_edit_fixtures.dart';
import '../../../support/theme_harness.dart';

/// W3-21: Edit profile with the W3 additions (banner editor, Location,
/// Website, their counters, helper and inline errors) at every cell of the
/// matrix: 360 / 600 / 1200 dp, light and dark, text scale 1.0 / 1.3 / 2.0.
/// `edit_profile_extras_gating_test` covers 1.0 and 2.0 only, and only that
/// the screen does not overflow; this file also checks that every control is
/// reachable by scrolling, inside the screen, and a 48 dp target.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder save() => find.widgetWithText(AppPillButton, 'Save');

  Finder inBanner(IconData icon) => find.descendant(
    of: find.byType(BannerEditor),
    matching: find.byIcon(icon),
  );

  Future<void> type(WidgetTester tester, String label, String text) async {
    await reveal(tester, field(label));
    await tester.enterText(field(label), text);
    await tester.pump();
  }

  // A long location (30 code points, the limit) and a long website (under
  // the 100-character limit), to give the fields something to fit.
  final location = 'Mumbai, Maharashtra, India'.padRight(30, '.');
  final website = 'https://example.com/${'path/' * 12}';

  group('profile_extras and media on', () {
    forEachThemeAndWidth(
      'banner, avatar and the four fields fit and are 48 dp '
      'targets',
      (tester, env) async {
        final rig = EditProfileRig(
          profile: editableProfile(
            location: location,
            website: website,
            banner: true,
          ),
        );
        await openEditProfile(
          tester,
          rig,
          flags: extrasFlags,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        // The banner band is 3:1 and inside the column; its buttons are 48 dp.
        final band = tester.getSize(find.byType(BannerEditor));
        expect(band.width / band.height, closeTo(3, 0.01));
        expect(band.width, lessThanOrEqualTo(env.size.width + 0.5));
        for (final icon in [Icons.photo_camera_outlined, Icons.close]) {
          expectMinTarget(
            tester,
            find.ancestor(
              of: inBanner(icon),
              matching: find.byType(InkResponse),
            ),
            reason: 'banner button $icon',
          );
        }
        expectMinTarget(tester, save(), reason: 'Save');
        // Every field is reachable, inside the screen and tall enough to tap.
        for (final label in ['Display name', 'Bio', 'Location', 'Website']) {
          await reveal(tester, field(label));
          expect(tester.takeException(), isNull, reason: label);
          expectInsideHorizontally(tester, field(label), env.size.width);
          expect(
            tester.getSize(field(label)).height,
            greaterThanOrEqualTo(AppSpacing.minTapTarget),
            reason: '$label field height',
          );
        }
        // The saved values are in the fields, untouched.
        expect(find.text(location), findsOneWidget);
        expect(find.text(website), findsOneWidget);
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );

    forEachThemeAndWidth(
      'inline errors, helper text and counters stay inside '
      'the screen',
      (tester, env) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(
          tester,
          rig,
          flags: extrasFlags,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        await type(tester, 'Location', 'a' * 31);
        await type(tester, 'Website', 'example.com');
        expect(tester.takeException(), isNull);
        for (final error in [
          'At most 30 characters.',
          'Enter a web address that starts with https:// or http://.',
        ]) {
          expect(find.text(error), findsOneWidget, reason: error);
          expectInsideHorizontally(tester, find.text(error), env.size.width);
        }
        // With an error, Save is off but is still a 48 dp control in the header.
        expect(tester.widget<AppPillButton>(save()).onPressed, isNull);
        expectMinTarget(tester, save(), reason: 'Save (disabled)');

        await type(tester, 'Location', 'Pune');
        await type(tester, 'Website', 'https://Example.com/about');
        expect(find.text('Shows as example.com'), findsOneWidget);
        expectInsideHorizontally(
          tester,
          find.text('Shows as example.com'),
          env.size.width,
        );
        expect(tester.widget<AppPillButton>(save()).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );
  });

  group('profile_extras on, media off', () {
    const noMedia = {kFeatureProfileSnapshot, kFeatureProfileExtras};

    forEachThemeAndWidth(
      'a saved banner is shown read-only, the fields still '
      'fit',
      (tester, env) async {
        final rig = EditProfileRig(
          profile: editableProfile(
            location: location,
            website: website,
            banner: true,
          ),
        );
        await openEditProfile(
          tester,
          rig,
          flags: noMedia,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(BannerEditor), findsOneWidget);
        expect(inBanner(Icons.photo_camera_outlined), findsNothing);
        expect(inBanner(Icons.close), findsNothing);
        final band = tester.getSize(find.byType(BannerEditor));
        expect(band.width / band.height, closeTo(3, 0.01));
        for (final label in ['Location', 'Website']) {
          await reveal(tester, field(label));
          expectInsideHorizontally(tester, field(label), env.size.width);
        }
      },
      textScales: kMatrixTextScalesLarge,
      height: 900,
    );

    forEachThemeAndWidth(
      'no saved banner: no band, only the fields',
      (tester, env) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(
          tester,
          rig,
          flags: noMedia,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(BannerEditor), findsNothing);
        await reveal(tester, field('Website'));
        expect(find.text('Location'), findsOneWidget);
        expect(find.text('Website'), findsOneWidget);
      },
      textScales: const [1.0, 2.0],
      height: 900,
    );
  });

  group('profile_extras off', () {
    forEachThemeAndWidth(
      'no banner, location or website, and the name and bio '
      'fit',
      (tester, env) async {
        final rig = EditProfileRig(
          profile: editableProfile(
            location: location,
            website: website,
            banner: true,
          ),
        );
        await openEditProfile(
          tester,
          rig,
          flags: const {kFeatureProfileSnapshot, kFeatureMedia},
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        expect(find.byType(BannerEditor), findsNothing);
        expect(find.text('Location'), findsNothing);
        expect(find.text('Website'), findsNothing);
        for (final label in ['Display name', 'Bio']) {
          await reveal(tester, field(label));
          expectInsideHorizontally(tester, field(label), env.size.width);
        }
      },
      textScales: const [1.0, 2.0],
      height: 900,
    );
  });
}
