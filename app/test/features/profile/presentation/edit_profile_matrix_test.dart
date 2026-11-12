import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/edit_profile_harness.dart';
import '../../../support/geometry.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_edit_fixtures.dart';
import '../../../support/theme_harness.dart';

/// Edit profile with the W3 additions (Location,
/// Website, their counters, helper and inline errors) at every cell of the
/// matrix: 360 / 600 / 1200 dp, light and dark, text scale 1.0 / 1.3 / 2.0.
/// `edit_profile_extras_gating_test` covers 1.0 and 2.0 only, and only that
/// the screen does not overflow; this file also checks that every control is
/// reachable by scrolling, inside the screen, and a 48 dp target.
///
/// M-1 (c): without `profile_extras` a saved location and website are shown
/// read-only with Remove; the last group asserts the Remove affordance and
/// that nothing editable is shown.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  Finder field(String label) => find.byKey(ValueKey('field-$label'));
  Finder save() => find.widgetWithText(AppPillButton, 'Save');

  Finder removeButton(String noun) => find.ancestor(
    of: find.byTooltip('Remove $noun'),
    matching: find.byType(IconButton),
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
      'the avatar and the four fields fit and are 48 dp targets',
      (tester, env) async {
        final rig = EditProfileRig(
          profile: editableProfile(location: location, website: website),
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

  group('profile_extras off', () {
    forEachThemeAndWidth(
      'a saved location and website are read-only with a 48 dp '
      'Remove, nothing editable is shown, and the name and bio fit',
      (tester, env) async {
        final rig = EditProfileRig(
          profile: editableProfile(location: location, website: website),
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
        // Location and website: the saved value, read-only, with Remove.
        for (final (label, noun) in [
          ('Location', 'location'),
          ('Website', 'website'),
        ]) {
          await reveal(tester, field(label));
          expect(tester.takeException(), isNull, reason: label);
          expectInsideHorizontally(tester, field(label), env.size.width);
          expect(
            tester.widget<TextField>(field(label)).readOnly,
            isTrue,
            reason: '$label is not editable',
          );
          expect(removeButton(noun), findsOneWidget, reason: 'Remove $noun');
          expectInsideHorizontally(
            tester,
            removeButton(noun),
            env.size.width,
            reason: 'Remove $noun',
          );
          expectMinTarget(tester, removeButton(noun), reason: 'Remove $noun');
        }
        // Nothing to type a website with: no "Shows as host" helper.
        expect(find.textContaining('Shows as'), findsNothing);
        for (final label in ['Display name', 'Bio']) {
          await reveal(tester, field(label));
          expectInsideHorizontally(tester, field(label), env.size.width);
          expect(tester.widget<TextField>(field(label)).readOnly, isFalse);
        }
      },
      textScales: const [1.0, 2.0],
      height: 900,
    );
  });
}
