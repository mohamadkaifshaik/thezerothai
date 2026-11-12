import 'dart:async';

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/edit_profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/edit_profile_preview.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_cover_band.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/features/search/presentation/widgets/app_search_field.dart';
import 'package:dzeroth/features/settings/presentation/settings_screen.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/context_pane_rig.dart' show findContextPane;
import '../../../support/profile_tablet_rig.dart';
import '../../../support/tablet_modal_harness.dart'
    show openDialogRect, tabletContentRect;

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

bool _tablet(double w) =>
    w >= AppBreakpoints.mobile && w < AppBreakpoints.tablet;

bool _bandB(double w) =>
    w >= AppBreakpoints.expanded && w < AppBreakpoints.tablet;

/// The header's Preview action.
Finder _previewAction() => find.descendant(
  of: find.byType(EditProfileScreen),
  matching: find.widgetWithText(TextButton, kEditProfilePreviewAction),
);

/// The form's own Preview row (text scale above 1.3).
Finder _previewRow() => find.descendant(
  of: find.byType(EditProfileScreen),
  matching: find.widgetWithText(OutlinedButton, kEditProfilePreviewAction),
);

Finder _inPreview(Finder finder) =>
    find.descendant(of: find.byType(EditProfilePreview), matching: finder);

Future<void> _openPreview(WidgetTester tester) async {
  await tester.tap(_previewAction());
  await tester.pumpAndSettle();
  expect(find.text(kEditProfilePreviewTitle), findsOneWidget);
}

Finder _field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);

void main() {
  group('Edit profile: the header action, flag modes x widths', () {
    for (final MapEntry(key: mode, value: flags) in kProfileFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: Preview in the header', (tester) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: w,
            flags: flags,
            location: AppRouter.editProfilePath,
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(EditProfileScreen), findsOneWidget);
          expect(_previewAction(), findsOneWidget);
          // Cancel and Save are there in every mode.
          expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
          expect(find.text('Save'), findsOneWidget);
          // Band B on the tablet layout (T4) and the desktop master-detail
          // (`ui_shell`, >= 1200): the Settings categories beside it, never
          // a context pane.
          final desktop = flags.contains(kFeatureUiShell) && w >= 1200;
          expect(
            find.byType(SettingsCategoriesPane),
            (_tabletFlags(flags) && _bandB(w)) || desktop
                ? findsOneWidget
                : findsNothing,
          );
          if (_tablet(w)) expect(findContextPane(), findsNothing);
        });
      }
    }
  });

  group('Edit profile: "How others see you"', () {
    for (final w in <double>[600, 744, 839, 840, 1024, 1199]) {
      testWidgets('at $w: a D 560 dialog on the content area, the saved '
          'profile, Close', (tester) async {
        final rig = ProfileTabletRig();
        await rig.pump(tester, width: w, location: AppRouter.editProfilePath);
        await _openPreview(tester);
        expect(tester.takeException(), isNull);

        final content = tabletContentRect(Size(w, 900));
        final dialog = openDialogRect(tester);
        final max = (content.width - 48).clamp(0, AppSize.dialogMax);
        expect(dialog.width, lessThanOrEqualTo(max + 0.5));
        expect(dialog.center.dx, closeTo(content.center.dx, 1));

        expect(_inPreview(find.byType(ProfileHeader)), findsOneWidget);
        expect(_inPreview(find.text('@$kRigOwnHandle')), findsOneWidget);
        expect(_inPreview(find.text('Bio of Alice A.')), findsOneWidget);
        // No controls: no Edit profile, Follow or menu.
        expect(_inPreview(find.text('Edit profile')), findsNothing);
        expect(_inPreview(find.byType(PopupMenuButton<String>)), findsNothing);
        expect(_inPreview(find.text('Follow')), findsNothing);
        // Nothing unsaved yet: no line about it.
        expect(find.text(kEditProfilePreviewUnsaved), findsNothing);

        final close = find.widgetWithText(TextButton, 'Close');
        expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text(kEditProfilePreviewTitle), findsNothing);
        expect(find.byType(EditProfileScreen), findsOneWidget);
      });
    }

    testWidgets('it shows the form as typed, and says so', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024, location: AppRouter.editProfilePath);
      await tester.enterText(_field('Display name'), '  Alice B  ');
      await tester.enterText(_field('Bio'), '');
      await tester.enterText(_field('Location'), 'Pune');
      await tester.pumpAndSettle();
      await _openPreview(tester);

      expect(find.text(kEditProfilePreviewUnsaved), findsOneWidget);
      final header = tester.widget<ProfileHeader>(
        _inPreview(find.byType(ProfileHeader)),
      );
      expect(header.profile.displayName, 'Alice B');
      expect(header.profile.bio, isEmpty);
      expect(header.profile.location, 'Pune');
      // Kept from the saved profile.
      expect(header.profile.handle, kRigOwnHandle);
      expect(header.profile.followersCount.toInt(), 12);
      // An empty optional field draws nothing.
      expect(_inPreview(find.text('Bio of Alice A.')), findsNothing);
      expect(_inPreview(find.textContaining('Pune')), findsOneWidget);
    });

    testWidgets('an empty name cannot be saved: others keep the saved one', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 744, location: AppRouter.editProfilePath);
      await tester.enterText(_field('Display name'), '   ');
      await tester.pumpAndSettle();
      await _openPreview(tester);
      expect(
        tester
            .widget<ProfileHeader>(_inPreview(find.byType(ProfileHeader)))
            .profile
            .displayName,
        'Alice A',
      );
    });

    testWidgets('a removed banner is gone from the preview', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024, location: AppRouter.editProfilePath);
      await _openPreview(tester);
      expect(
        tester
            .widget<ProfileCoverBand>(_inPreview(find.byType(ProfileCoverBand)))
            .url,
        isNotEmpty,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Remove banner photo'));
      await tester.pumpAndSettle();
      await _openPreview(tester);
      // The hero draws a band only while there is a banner.
      expect(_inPreview(find.byType(ProfileCoverBand)), findsNothing);
      expect(find.text(kEditProfilePreviewUnsaved), findsOneWidget);
    });

    testWidgets('the real header: the navy hero with the name w800, the banner '
        'filling it and the phone-size avatar', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024, location: AppRouter.editProfilePath);
      await _openPreview(tester);
      final theme = Theme.of(tester.element(find.byType(EditProfilePreview)));

      final name = tester.widget<RichText>(
        _inPreview(
          find.byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText().startsWith('Alice A'),
          ),
        ),
      );
      final style = name.text.style!;
      expect(style.fontWeight, FontWeight.w800);
      // The preview is narrower than 600: the hero's phone look.
      expect(style.fontSize, AppProfileLayout.phoneNameSize);
      expect(style.fontFamily, theme.textTheme.titleLarge!.fontFamily);

      final band = tester.getRect(_inPreview(find.byType(ProfileCoverBand)));
      final frame = tester.getRect(find.byType(EditProfilePreview));
      expect(band.width, frame.width);
      expect(band.top, frame.top);

      final avatar = tester.getRect(_inPreview(find.byType(AppAvatar)));
      // Narrower than 600: the hero's 76 dp avatar.
      expect(avatar.width, AppProfileLayout.phoneAvatar);
      // It sits inside the hero the banner fills.
      expect(avatar.top, greaterThan(band.top));
      expect(avatar.bottom, lessThan(band.bottom));
    });

    testWidgets('inert: the counts and the website open nothing and are not '
        'buttons or links', (tester) async {
      final semantics = tester.ensureSemantics();
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024, location: AppRouter.editProfilePath);
      await _openPreview(tester);

      final followers = _inPreview(find.bySemanticsLabel('12 Followers'));
      expect(followers, findsOneWidget);
      final node = tester.getSemantics(followers);
      expect(node.flagsCollection.isButton, isFalse);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      final website = tester.getSemantics(
        _inPreview(find.bySemanticsLabel('Website: example.com')),
      );
      expect(website.flagsCollection.isLink, isFalse);
      expect(
        website.getSemanticsData().hasAction(SemanticsAction.tap),
        isFalse,
      );

      await tester.tap(followers, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.editProfilePath);
      expect(find.text(kEditProfilePreviewTitle), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('Escape closes it and focus returns to Preview; the header '
        'reads Cancel, Preview, Save', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024, location: AppRouter.editProfilePath);
      await tester.enterText(_field('Display name'), 'Alice B');
      await tester.pumpAndSettle();

      FocusNode nodeOf(String text) => Focus.of(
        tester.element(
          find.descendant(
            of: find.byType(EditProfileScreen),
            matching: find.text(text),
          ),
        ),
      );
      final cancel = nodeOf('Cancel');
      final preview = nodeOf(kEditProfilePreviewAction);
      final save = nodeOf('Save');
      cancel.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, cancel);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, preview);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, save);

      // Back to Preview, and open it from the keyboard.
      preview.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(kEditProfilePreviewTitle), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text(kEditProfilePreviewTitle), findsNothing);
      expect(FocusManager.instance.primaryFocus, preview);
    });

    for (final (w, h) in [(600.0, 960.0), (840.0, 1194.0), (1024.0, 768.0)]) {
      for (final brightness in Brightness.values) {
        testWidgets('text scale 2.0 at $w x $h (${brightness.name}): the '
            'header and the dialog have no overflow and 48 dp targets', (
          tester,
        ) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: w,
            height: h,
            textScale: 2,
            brightness: brightness,
            location: AppRouter.editProfilePath,
          );
          expect(tester.takeException(), isNull);
          // Above 1.3 the action is the form's first row, not the header's.
          expect(_previewAction(), findsNothing);
          expect(
            tester.getSize(_previewRow()).height,
            greaterThanOrEqualTo(48),
          );
          await tester.tap(_previewRow());
          await tester.pumpAndSettle();
          expect(find.text(kEditProfilePreviewTitle), findsOneWidget);
          expect(tester.takeException(), isNull);
          final dialog = openDialogRect(tester);
          expect(dialog.bottom, lessThanOrEqualTo(h));
          final close = find.widgetWithText(TextButton, 'Close');
          await tester.ensureVisible(close);
          expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
        });
      }
    }

    for (final scale in <double>[1, 1.3, 1.5, 2, 3]) {
      testWidgets('text scale $scale at 840: Preview '
          '${scale > 1.3 ? 'the first row of the form' : 'is in the header'}', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: 840,
          height: 1194,
          textScale: scale,
          location: AppRouter.editProfilePath,
        );
        expect(tester.takeException(), isNull);
        if (scale <= 1.3) {
          expect(_previewAction(), findsOneWidget);
          expect(_previewRow(), findsNothing);
          return;
        }
        expect(_previewAction(), findsNothing);
        expect(_previewRow(), findsOneWidget);
        // The first item of the form's list, full width, 48 dp or more.
        final list = tester.widget<ListView>(
          find.descendant(
            of: find.byType(EditProfileScreen),
            matching: find.byType(ListView),
          ),
        );
        final first =
            (list.childrenDelegate as SliverChildListDelegate).children.first;
        expect(
          find.descendant(
            of: find.byWidget(first),
            matching: find.byType(OutlinedButton),
            matchRoot: true,
          ),
          findsOneWidget,
        );
        final row = tester.getRect(_previewRow());
        final banner = tester.getRect(
          find.descendant(
            of: find.byType(EditProfileScreen),
            matching: find.byType(ProfileCoverBand),
          ),
        );
        expect(row.width, banner.width);
        expect(row.height, greaterThanOrEqualTo(48));
        expect(row.bottom, lessThanOrEqualTo(banner.top));
        expect(
          find.descendant(
            of: _previewRow(),
            matching: find.byIcon(Icons.visibility_outlined),
          ),
          findsOneWidget,
        );
        await tester.tap(_previewRow());
        await tester.pumpAndSettle();
        expect(find.text(kEditProfilePreviewTitle), findsOneWidget);
      });
    }

    testWidgets('at 2.0 Preview is the first row of the form at every width', (
      tester,
    ) async {
      for (final w in <double>[400, 1024, 1300]) {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: w,
          textScale: 2,
          location: AppRouter.editProfilePath,
        );
        expect(_previewRow(), findsOneWidget, reason: '$w');
        expect(_previewAction(), findsNothing, reason: '$w');
      }
    });

    testWidgets('RTL at 1024: the dialog is centred on the content area', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        width: 1024,
        textDirection: TextDirection.rtl,
        location: AppRouter.editProfilePath,
      );
      await _openPreview(tester);
      final content = tabletContentRect(
        const Size(1024, 900),
        textDirection: TextDirection.rtl,
      );
      expect(openDialogRect(tester).center.dx, closeTo(content.center.dx, 1));
      // The avatar sits at the start (right) edge of the preview.
      final frame = tester.getRect(find.byType(EditProfilePreview));
      final avatar = tester.getRect(_inPreview(find.byType(AppAvatar)));
      expect(frame.right - avatar.right, lessThan(frame.width / 3));
    });

    testWidgets('pushed from the profile at 1024: no pane and no Settings '
        'list beside it, the Preview action, back to the profile', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024);
      await tester.tap(find.widgetWithText(FilledButton, 'Edit profile'));
      await tester.pumpAndSettle();
      expect(find.byType(EditProfileScreen), findsOneWidget);
      expect(findContextPane(), findsNothing);
      expect(find.byType(SettingsCategoriesPane), findsNothing);
      expect(_previewAction(), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.profilePath(kRigOwnHandle));
      expect(findContextPane(), findsNothing);
    });

    testWidgets('the own profile pushed over Home, then Edit profile: no '
        'pane, not the Home one', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 1024, location: AppRouter.homePath);
      unawaited(rig.router.push(AppRouter.profileByIdPath(kRigOwnId)));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(findContextPane(), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Edit profile'));
      await tester.pumpAndSettle();
      expect(find.byType(EditProfileScreen), findsOneWidget);
      expect(findContextPane(), findsNothing);
      expect(find.byType(AppSearchField), findsNothing);
      expect(find.text("What's happening"), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(findContextPane(), findsNothing);
    });
  });

  group('Edit profile: state across resizes', () {
    testWidgets('the same field and text across 839/840/1199/1200/599/600/'
        '1024; Preview stays in the header', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 839, location: AppRouter.editProfilePath);
      await tester.enterText(_field('Display name'), 'Alice B');
      await tester.pumpAndSettle();
      EditableTextState field() => tester.state<EditableTextState>(
        find.descendant(
          of: _field('Display name'),
          matching: find.byType(EditableText),
        ),
      );
      final before = field();
      for (final w in <double>[840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(field(), same(before), reason: '$w');
        expect(field().textEditingValue.text, 'Alice B', reason: '$w');
        expect(_previewAction(), findsOneWidget, reason: '$w');
      }
    });

    testWidgets('an open preview stays open across 744/1024/1199 and follows '
        'the form', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: 744, location: AppRouter.editProfilePath);
      await tester.enterText(_field('Display name'), 'Alice B');
      await tester.pumpAndSettle();
      await _openPreview(tester);
      for (final w in <double>[1024, 1199, 744]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(find.text(kEditProfilePreviewTitle), findsOneWidget);
        final content = tabletContentRect(Size(w, 900));
        expect(
          openDialogRect(tester).center.dx,
          closeTo(content.center.dx, 1),
          reason: '$w',
        );
        expect(
          tester
              .widget<ProfileHeader>(_inPreview(find.byType(ProfileHeader)))
              .profile
              .displayName,
          'Alice B',
        );
      }
    });
  });

  group('Edit profile: the discard confirm (D 280-400)', () {
    for (final w in <double>[700, 1024]) {
      testWidgets('at $w: 280-400 wide on the content area; Escape keeps '
          'editing', (tester) async {
        final rig = ProfileTabletRig();
        await rig.pump(tester, width: w, location: AppRouter.editProfilePath);
        await tester.enterText(_field('Display name'), 'Alice B');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Discard changes?'), findsOneWidget);
        final dialog = openDialogRect(tester);
        expect(dialog.width, inInclusiveRange(280, 400));
        final content = tabletContentRect(Size(w, 900));
        expect(dialog.center.dx, closeTo(content.center.dx, 1));

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Discard changes?'), findsNothing);
        expect(find.byType(EditProfileScreen), findsOneWidget);
        expect(find.text('Alice B'), findsOneWidget);
      });
    }
  });
}
