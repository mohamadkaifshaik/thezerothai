import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/edit_profile_preview.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/profile_tablet_rig.dart';

/// Edit profile's header on the tablet layout with the app's real fonts
/// (T8c): Cancel, Preview and Save share the row (`AppFormHeader` gives each
/// button 28 % of it). Measured, not assumed: which labels show in full.
bool _fits(WidgetTester tester, String label) => !tester
    .renderObject<RenderParagraph>(
      find
          .descendant(
            of: find.byType(EditProfileScreen),
            matching: find.text(label),
          )
          .first,
    )
    .didExceedMaxLines;

void main() {
  setUpAll(loadAppFonts);

  for (final w in <double>[600, 744, 839, 840, 1024, 1199]) {
    for (final scale in <double>[1, 1.3]) {
      testWidgets('$w x$scale: every header label in full', (tester) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: w,
          height: 1194,
          textScale: scale,
          location: AppRouter.editProfilePath,
        );
        for (final label in [
          'Cancel',
          kEditProfilePreviewAction,
          'Save',
          'Edit profile',
        ]) {
          expect(_fits(tester, label), isTrue, reason: label);
        }
      });
    }
  }

  // At 2.0 the buttons fit wherever the page is at least 520 dp wide; the
  // title yields first, as the header documents.
  for (final w in <double>[600, 744, 1024, 1199]) {
    testWidgets('$w x2.0: Cancel, Preview and Save in full', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        width: w,
        height: 1194,
        textScale: 2,
        location: AppRouter.editProfilePath,
      );
      for (final label in ['Cancel', kEditProfilePreviewAction, 'Save']) {
        expect(_fits(tester, label), isTrue, reason: label);
      }
    });
  }

  // Known limit (ruling 4): the 439 dp detail at 840 x2.0 leaves each button
  // 118 dp, so Preview and Save ellipsize (Save by under 1 dp).
  testWidgets('840 x2.0: Preview and Save ellipsize (the known limit)', (
    tester,
  ) async {
    final rig = ProfileTabletRig();
    await rig.pump(
      tester,
      width: 840,
      height: 1194,
      textScale: 2,
      location: AppRouter.editProfilePath,
    );
    expect(_fits(tester, 'Cancel'), isTrue);
    expect(_fits(tester, kEditProfilePreviewAction), isFalse);
    expect(_fits(tester, 'Save'), isFalse);
  });
}
