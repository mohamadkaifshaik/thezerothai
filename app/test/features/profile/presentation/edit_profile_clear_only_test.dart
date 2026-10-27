import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/media/domain/media_feature_flag.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:dzeroth/features/profile/presentation/widgets/banner_editor.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/edit_profile_harness.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_edit_fixtures.dart';
import '../../../support/theme_harness.dart';

/// Edit profile for a caller WITHOUT `profile_extras` (W3-22 M-1 item (c),
/// ADR-0024 Amendment 1 A2): a saved banner, location and website are shown
/// read-only with Remove, nothing can be set, and the only thing a request
/// carries for them is an exact `""`. The server accepts that from any
/// caller, and refuses a clear next to a set, so the screen sends clears
/// alone: never a non-empty banner id, location or website.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  // `profile_snapshot` reaches the screen; media on or off.
  const withMedia = {kFeatureProfileSnapshot, kFeatureMedia};
  const noMedia = {kFeatureProfileSnapshot};

  final saved = editableProfile(
    location: 'Pune',
    website: 'https://a.example',
    banner: true,
  );

  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder save() => find.widgetWithText(AppPillButton, 'Save');
  Finder removeLocation() => find.byTooltip('Remove location');
  Finder removeWebsite() => find.byTooltip('Remove website');
  Finder inBanner(IconData icon) => find.descendant(
    of: find.byType(BannerEditor),
    matching: find.byIcon(icon),
  );
  String textOf(WidgetTester tester, String label) =>
      tester.widget<TextField>(field(label)).controller!.text;

  /// The clear-only invariant: each extra of [call] is absent or exactly "".
  void expectClearsOnly(UpdateProfileCall call) {
    for (final value in [call.bannerMediaId, call.location, call.website]) {
      expect(value == null || value.isEmpty, isTrue, reason: 'sent "$value"');
    }
    expect(call.pinnedPostId, isNull);
  }

  group('what the screen shows', () {
    forEachThemeAndWidth(
      'banner, location and website read-only, each with a 48dp Remove, and '
      'nothing to change them with',
      (tester, env) async {
        final rig = EditProfileRig(profile: saved);
        await openEditProfile(
          tester,
          rig,
          flags: withMedia,
          size: env.size,
          brightness: env.brightness,
          textScale: env.textScale,
        );

        expect(tester.takeException(), isNull);
        // The banner: the band, Remove only (no Change, no Add).
        expect(find.byType(BannerEditor), findsOneWidget);
        expect(inBanner(Icons.photo_camera_outlined), findsNothing);
        final bannerRemove = tester.getSize(
          find.ancestor(
            of: inBanner(Icons.close),
            matching: find.byType(InkResponse),
          ),
        );
        expect(bannerRemove.width, greaterThanOrEqualTo(48));
        expect(bannerRemove.height, greaterThanOrEqualTo(48));

        // The location and website: the stored value, read-only, with Remove.
        for (final (label, value, remove) in [
          ('Location', 'Pune', removeLocation()),
          ('Website', 'https://a.example', removeWebsite()),
        ]) {
          await reveal(tester, field(label));
          expect(tester.takeException(), isNull, reason: label);
          expect(tester.widget<TextField>(field(label)).readOnly, isTrue);
          expect(find.text(value), findsOneWidget, reason: label);
          final target = tester.getSize(
            find.ancestor(of: remove, matching: find.byType(IconButton)).first,
          );
          expect(target.width, greaterThanOrEqualTo(48), reason: label);
          expect(target.height, greaterThanOrEqualTo(48), reason: label);
          expect(
            tester.getRect(remove).right,
            lessThanOrEqualTo(env.size.width),
            reason: label,
          );
        }
        // No "Shows as ..." helper: there is nothing to type.
        expect(find.textContaining('Shows as'), findsNothing);
        // Nothing changed yet.
        expect(tester.widget<AppPillButton>(save()).onPressed, isNull);
      },
      textScales: const [1.0, 2.0],
      height: 900,
    );

    testWidgets('only what is saved is offered: with the flag globally off '
        'the server omits the website, so only the banner and the location '
        'show', (tester) async {
      final rig = EditProfileRig(
        profile: editableProfile(location: 'Pune', banner: true),
      );
      await openEditProfile(tester, rig, flags: withMedia);

      expect(find.byType(BannerEditor), findsOneWidget);
      await reveal(tester, field('Location'));
      expect(field('Location'), findsOneWidget);
      expect(field('Website'), findsNothing);
      expect(removeWebsite(), findsNothing);
    });

    testWidgets('with the flag on there is no Remove button: the fields are '
        'typed in', (tester) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: extrasFlags);

      await reveal(tester, field('Location'));
      expect(tester.widget<TextField>(field('Location')).readOnly, isFalse);
      expect(removeLocation(), findsNothing);
      expect(removeWebsite(), findsNothing);
    });
  });

  group('removing', () {
    testWidgets('Remove location: the field reads empty, then Save sends '
        'location "" and nothing else', (tester) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: withMedia);
      await reveal(tester, removeLocation());

      await tester.tap(removeLocation());
      await tester.pump();

      expect(textOf(tester, 'Location'), '');
      expect(find.text('Removed when you save.'), findsOneWidget);
      // One removal each: the button is gone, the other field is untouched.
      expect(removeLocation(), findsNothing);
      expect(removeWebsite(), findsOneWidget);
      expect(tester.widget<AppPillButton>(save()).onPressed, isNotNull);

      await tester.tap(save());
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.location, '');
      expect(call.website, isNull);
      expect(call.bannerMediaId, isNull);
      expect(call.displayName, isNull);
      expect(call.bio, isNull);
      expectClearsOnly(call);
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('Remove website: sends website "" and nothing else', (
      tester,
    ) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: withMedia);
      await reveal(tester, removeWebsite());

      await tester.tap(removeWebsite());
      await tester.pump();
      await tester.tap(save());
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.website, '');
      expect(call.location, isNull);
      expect(call.bannerMediaId, isNull);
      expectClearsOnly(call);
    });

    testWidgets('Remove banner with media ON: sends banner_media_id "" and '
        'uploads nothing', (tester) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: withMedia);

      await tester.tap(inBanner(Icons.close));
      await tester.pump();
      await tester.tap(save());
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.bannerMediaId, '');
      expect(call.location, isNull);
      expect(call.website, isNull);
      expectClearsOnly(call);
      verifyNever(
        () => rig.media.createUpload(
          idempotencyKey: any(named: 'idempotencyKey'),
          purpose: any(named: 'purpose'),
          images: any(named: 'images'),
        ),
      );
    });

    testWidgets('Remove banner needs neither media nor profile_extras', (
      tester,
    ) async {
      final rig = EditProfileRig(profile: editableProfile(banner: true));
      await openEditProfile(tester, rig, flags: noMedia);

      expect(inBanner(Icons.photo_camera_outlined), findsNothing);
      await tester.tap(inBanner(Icons.close));
      await tester.pump();
      // The band goes: it was the saved banner, and Save will clear it.
      expect(find.byType(BannerEditor), findsNothing);
      await tester.tap(save());
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.bannerMediaId, '');
      expectClearsOnly(call);
    });

    testWidgets('all three together, next to a name change, are clears only', (
      tester,
    ) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: withMedia);

      await tester.tap(inBanner(Icons.close));
      await tester.pump();
      await reveal(tester, removeLocation());
      await tester.tap(removeLocation());
      await tester.pump();
      await reveal(tester, removeWebsite());
      await tester.tap(removeWebsite());
      await tester.pump();
      await reveal(tester, field('Display name'));
      await tester.enterText(field('Display name'), 'Kaif S');
      await tester.pump();
      await tester.tap(save());
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.displayName, 'Kaif S');
      expect(call.bannerMediaId, '');
      expect(call.location, '');
      expect(call.website, '');
      expectClearsOnly(call);
    });

    testWidgets('a name save alone never carries an extra, whatever the '
        'profile holds', (tester) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: withMedia);

      await tester.enterText(field('Display name'), 'Kaif S');
      await tester.pump();
      await tester.tap(save());
      await tester.pumpAndSettle();

      final call = rig.repo.calls.single;
      expect(call.displayName, 'Kaif S');
      expect(call.hasExtras, isFalse);
    });

    testWidgets('a pending removal is a change: Cancel asks before '
        'discarding it', (tester) async {
      final rig = EditProfileRig(profile: saved);
      await openEditProfile(tester, rig, flags: withMedia);
      await reveal(tester, removeLocation());
      await tester.tap(removeLocation());
      await tester.pump();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(rig.repo.calls, isEmpty);
    });

    testWidgets('a server that still refuses the clear (FEATURE_DISABLED '
        'profile_extras) says so, puts the saved values back and hides '
        'Remove', (tester) async {
      final rig = EditProfileRig(profile: saved);
      rig.repo.failures.add(
        const FeatureDisabledException('off', feature: kFeatureProfileExtras),
      );
      await openEditProfile(tester, rig, flags: withMedia);
      await reveal(tester, removeLocation());
      await tester.tap(removeLocation());
      await tester.pump();

      await tester.tap(save());
      await tester.pumpAndSettle();

      expect(find.text(kProfileExtrasUnavailableMessage), findsOneWidget);
      expect(textOf(tester, 'Location'), 'Pune');
      expect(removeLocation(), findsNothing);
      expect(removeWebsite(), findsNothing);
      expect(inBanner(Icons.close), findsNothing);
      expect(find.byType(BannerEditor), findsOneWidget);
      expect(find.text("You can't change this right now."), findsNWidgets(2));
      expect(tester.widget<AppPillButton>(save()).onPressed, isNull);
    });
  });
}
