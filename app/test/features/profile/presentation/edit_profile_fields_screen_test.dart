import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/edit_profile_harness.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_edit_fixtures.dart';
import '../../../support/theme_harness.dart';

/// The location and website fields of Edit profile (W3-15): counters in code
/// points, local checks as inline errors, the host preview, and the server's
/// VALIDATION answers as inline errors, at 360/600/1200 dp.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  Finder field(String label) => find.widgetWithText(TextField, label);
  Finder save() => find.widgetWithText(AppPillButton, 'Save');
  bool saveEnabled(WidgetTester tester) =>
      tester.widget<AppPillButton>(save()).onPressed != null;

  // The counter is announced as part of the field's own semantics.
  String label(WidgetTester tester, String fieldLabel) =>
      tester.getSemantics(field(fieldLabel)).label;

  Future<void> type(WidgetTester tester, String label, String text) async {
    await reveal(tester, field(label));
    await tester.enterText(field(label), text);
    await tester.pump();
  }

  for (final width in kMatrixWidths) {
    final size = Size(width, 900);

    group('at ${width.toInt()}dp', () {
      testWidgets('location: the counter counts code points and 31 is over', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);

        await type(
          tester,
          'Location',
          String.fromCharCodes([0x1F600, 0x1F600]),
        );
        expect(label(tester, 'Location'), contains('Characters remaining: 28'));

        await type(tester, 'Location', 'a' * 31);
        expect(find.text('At most 30 characters.'), findsOneWidget);
        expect(
          label(tester, 'Location'),
          contains('Characters over the limit: 1'),
        );
        expect(saveEnabled(tester), isFalse);

        await type(tester, 'Location', 'a' * 30);
        expect(find.text('At most 30 characters.'), findsNothing);
        expect(saveEnabled(tester), isTrue);
        semantics.dispose();
      });

      testWidgets('website: invalid shows inline, valid shows its host', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);

        await type(tester, 'Website', 'example.com');
        expect(
          find.text(
            'Enter a web address that starts with https:// or http://.',
          ),
          findsOneWidget,
        );
        expect(saveEnabled(tester), isFalse);

        await type(tester, 'Website', 'https://Example.com/about');
        expect(find.text('Shows as example.com'), findsOneWidget);
        expect(saveEnabled(tester), isTrue);

        await type(tester, 'Website', 'https://example.com/${'a' * 100}');
        expect(find.text('At most 100 characters.'), findsOneWidget);
        expect(saveEnabled(tester), isFalse);
      });

      testWidgets('Save sends the trimmed location and website, only those', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile(location: 'Pune'));
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);

        await type(tester, 'Website', '  https://example.com  ');
        await tester.tap(save());
        await tester.pumpAndSettle();

        final call = rig.repo.calls.single;
        expect(call.website, 'https://example.com');
        expect(call.location, isNull);
        expect(call.displayName, isNull);
        expect(find.text('settings'), findsOneWidget);
      });

      testWidgets('clearing both sends empty strings', (tester) async {
        final rig = EditProfileRig(
          profile: editableProfile(location: 'Pune', website: 'https://a.b'),
        );
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        expect(field('Location'), findsOneWidget);
        expect(find.text('Pune'), findsOneWidget);

        await type(tester, 'Location', '');
        await type(tester, 'Website', '');
        await tester.tap(save());
        await tester.pumpAndSettle();

        final call = rig.repo.calls.single;
        expect(call.location, '');
        expect(call.website, '');
      });

      testWidgets('a server VALIDATION on location shows inline until edited', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        rig.repo.failures.add(
          const ValidationException('bad', field: 'location'),
        );
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await type(tester, 'Location', 'Somewhere');

        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(find.text(kLocationRejectedMessage), findsOneWidget);
        expect(saveEnabled(tester), isFalse);
        await type(tester, 'Location', 'Elsewhere');
        expect(find.text(kLocationRejectedMessage), findsNothing);
        expect(saveEnabled(tester), isTrue);
      });

      testWidgets('a server VALIDATION on website shows inline until edited', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        rig.repo.failures.add(
          const ValidationException('bad', field: 'website'),
        );
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await type(tester, 'Website', 'https://example.com');

        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(find.text(kWebsiteRejectedMessage), findsOneWidget);
        expect(saveEnabled(tester), isFalse);
      });
    });
  }
}
