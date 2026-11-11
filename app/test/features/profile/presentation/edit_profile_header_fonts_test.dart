import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/edit_profile_preview.dart';
import 'package:flutter/material.dart';
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

  // Save never ellipsizes (T8c review item 2): above 1.3 the Preview
  // action leaves the header (Save gets 40 % of the row again) for the
  // form's first row.
  for (final w in <double>[600, 840, 1024]) {
    for (final scale in <double>[1, 1.3, 1.5, 2, 3]) {
      testWidgets('$w x$scale: Save in full; Preview '
          '${scale > 1.3 ? 'in the form' : 'in the header'}', (tester) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: w,
          height: 1194,
          textScale: scale,
          location: AppRouter.editProfilePath,
        );
        expect(tester.takeException(), isNull);
        expect(_fits(tester, 'Save'), isTrue);
        expect(_fits(tester, 'Cancel'), isTrue);
        expect(_fits(tester, kEditProfilePreviewAction), isTrue);
        final inHeader = find.descendant(
          of: find.byType(EditProfileScreen),
          matching: find.widgetWithText(TextButton, kEditProfilePreviewAction),
        );
        expect(inHeader, scale > 1.3 ? findsNothing : findsOneWidget);
      });
    }
  }
}
