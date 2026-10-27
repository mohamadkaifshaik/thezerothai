import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/profile_edit_error_messages.dart';
import 'package:dzeroth/features/profile/presentation/widgets/banner_editor.dart';
import 'package:dzeroth/gen/dzeroth/media/v1/media.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/app_pill_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/edit_profile_harness.dart';
import '../../../support/media_fixtures.dart';
import '../../../support/profile_edit_fixtures.dart';
import '../../../support/theme_harness.dart';

/// The banner editor on Edit profile, state by state (W3-15): placeholder,
/// picked, uploading, error and remove, at 360/600/1200 dp.
void main() {
  setUpAll(() {
    registerMediaFallbacks();
    registerFallbackValue(const OnboardingRefreshRequested());
  });

  Finder camera() => find.descendant(
    of: find.byType(BannerEditor),
    matching: find.byIcon(Icons.photo_camera_outlined),
  );
  Finder remove() => find.descendant(
    of: find.byType(BannerEditor),
    matching: find.byIcon(Icons.close),
  );
  Finder save() => find.widgetWithText(AppPillButton, 'Save');
  bool saveEnabled(WidgetTester tester) =>
      tester.widget<AppPillButton>(save()).onPressed != null;

  Future<void> pickBanner(WidgetTester tester, EditProfileRig rig) async {
    rig.picker.next = [imageBytes('a')];
    await tester.tap(camera());
    await tester.pumpAndSettle();
  }

  for (final width in kMatrixWidths) {
    final size = Size(width, 900);

    group('at ${width.toInt()}dp', () {
      testWidgets('placeholder: add button only, no Remove, Save off', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);

        expect(camera(), findsOneWidget);
        expect(remove(), findsNothing);
        expect(find.bySemanticsLabel('Add banner photo'), findsOneWidget);
        expect(saveEnabled(tester), isFalse);
      });

      testWidgets('picked: shows the preview, offers Change and Remove', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);

        await pickBanner(tester, rig);

        expect(
          find.descendant(
            of: find.byType(BannerEditor),
            matching: find.byType(Image),
          ),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('Change banner photo'), findsOneWidget);
        expect(find.bySemanticsLabel('Remove banner photo'), findsOneWidget);
        expect(saveEnabled(tester), isTrue);
      });

      testWidgets('Save uploads and sends the banner, then leaves', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await pickBanner(tester, rig);

        await tester.tap(save());
        await tester.pumpAndSettle();

        final call = rig.repo.calls.single;
        expect(call.bannerMediaId, 'm1');
        expect(call.displayName, isNull);
        final purposes = verify(
          () => rig.media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: captureAny(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).captured;
        expect(purposes, [pb.MediaPurpose.MEDIA_PURPOSE_BANNER]);
        expect(find.text('settings'), findsOneWidget);
      });

      testWidgets('uploading: the band dims and both buttons ignore taps', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await pickBanner(tester, rig);
        final gate = Completer<List<pb.UploadTarget>>();
        when(
          () => rig.media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).thenAnswer((_) => gate.future);

        await tester.tap(save());
        await tester.pump();

        expect(find.bySemanticsLabel('Saving'), findsOneWidget);
        final buttons = tester.widgetList<InkResponse>(
          find.descendant(
            of: find.byType(BannerEditor),
            matching: find.byType(InkResponse),
          ),
        );
        expect(buttons, isNotEmpty);
        expect(buttons.every((b) => b.onTap == null), isTrue);
        gate.complete([uploadTarget('m1')]);
        await tester.pumpAndSettle();
        expect(rig.repo.calls.single.bannerMediaId, 'm1');
      });

      testWidgets('error: a quota answer is friendly and keeps the pick', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await pickBanner(tester, rig);
        when(
          () => rig.media.createUpload(
            idempotencyKey: any(named: 'idempotencyKey'),
            purpose: any(named: 'purpose'),
            images: any(named: 'images'),
          ),
        ).thenThrow(const QuotaExceededException('uploads'));

        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(find.textContaining('limit for photo uploads'), findsOneWidget);
        expect(rig.repo.calls, isEmpty);
        expect(saveEnabled(tester), isTrue);
      });

      testWidgets('error: a refused banner explains itself and is dropped', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        stubHappyUpload(
          rig.media,
          result: (id) => rejectedResult(id, 'Not allowed'),
        );
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await pickBanner(tester, rig);

        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(find.text('Not allowed'), findsOneWidget);
        expect(saveEnabled(tester), isFalse);
        expect(remove(), findsNothing);
      });

      testWidgets('error: MEDIA_NOT_READY on save asks to choose it again', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile());
        rig.repo.failures.add(const MediaNotReadyException('gone'));
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await pickBanner(tester, rig);

        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(find.text(kBannerGoneMessage), findsOneWidget);
        expect(camera(), findsOneWidget);
        expect(remove(), findsNothing);
      });

      testWidgets('remove: a saved banner is removed with an empty id', (
        tester,
      ) async {
        final rig = EditProfileRig(profile: editableProfile(banner: true));
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        expect(remove(), findsOneWidget);
        expect(saveEnabled(tester), isFalse);

        await tester.tap(remove());
        await tester.pumpAndSettle();

        expect(remove(), findsNothing);
        expect(find.bySemanticsLabel('Add banner photo'), findsOneWidget);
        expect(saveEnabled(tester), isTrue);
        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(rig.repo.calls.single.bannerMediaId, '');
        verifyZeroInteractions(rig.media);
        expect(find.text('settings'), findsOneWidget);
      });

      testWidgets('FEATURE_DISABLED profile_extras on save hides the extras '
          'and says so', (tester) async {
        final rig = EditProfileRig(profile: editableProfile());
        rig.repo.failures.add(
          const FeatureDisabledException('off', feature: kFeatureProfileExtras),
        );
        await openEditProfile(tester, rig, flags: extrasFlags, size: size);
        await tester.enterText(
          find.widgetWithText(TextField, 'Display name'),
          'Kaif S',
        );
        await tester.pump();
        await pickBanner(tester, rig);

        await tester.tap(save());
        await tester.pumpAndSettle();

        expect(find.text(kProfileExtrasUnavailableMessage), findsOneWidget);
        expect(find.byType(BannerEditor), findsNothing);
        expect(find.text('Location'), findsNothing);
        expect(find.text('Website'), findsNothing);
        expect(saveEnabled(tester), isTrue);
        await tester.tap(save());
        await tester.pumpAndSettle();
        expect(rig.repo.calls.last.displayName, 'Kaif S');
        expect(rig.repo.calls.last.hasExtras, isFalse);
      });
    });
  }
}
