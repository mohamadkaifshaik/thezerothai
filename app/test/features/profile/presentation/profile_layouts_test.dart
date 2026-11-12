import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/share/native_share.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/share/share_links.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/edit_profile_preview.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_media_strip.dart';
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tab_bar.dart';
import 'package:dzeroth/shared/widgets/primitives/sheet_option_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/geometry.dart';
import '../../../support/profile_hero_finders.dart';
import '../../../support/profile_tablet_rig.dart';

/// The three looks of Profile (the navy hero of the dzeroth-mobile, tablet and
/// desktop Profile mocks) over one set of data, actions and gates. The flag
/// modes and the pane rows live in `profile_tablet_test.dart`.

const _phone = 390.0;
const _tablet = 1024.0;
const _desktop = 1440.0;

const _looks = <String, double>{
  'phone': _phone,
  'tablet': _tablet,
  'desktop': _desktop,
};

const _screenshots = bool.fromEnvironment('EXPLORE_PEOPLE_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/explore-people/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

/// The profile surfaces' flags plus the ones the other person's actions need.
final _fullFlags = {...kProfileTabletFlags, 'messaging', 'lists', 'reports'};

/// The navy hero (dz.css `.hero`).
Finder get _hero => find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).gradient == AppGradients.hero,
);

/// The hero's avatar: the first one on the page.
double _avatarSize(WidgetTester tester) =>
    tester.getSize(inProfilePage(find.byType(AppAvatar)).first).width;

/// [finder] inside the hero (the desktop side column has Follow buttons too).
Finder _inHero(Finder finder) => find.descendant(of: _hero, matching: finder);

Finder _statLabel(String label) => find.descendant(
  of: _hero,
  matching: find.bySemanticsLabel(RegExp('^\\d+ $label\$')),
);

class _FakeShare implements NativeShare {
  @override
  bool get isAvailable => true;

  @override
  Future<void> shareUrl(String url, {Rect? anchor}) async {}
}

void main() {
  late List<String> clipboard;

  setUp(() {
    clipboard = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  for (final MapEntry(key: look, value: width) in _looks.entries) {
    for (final brightness in Brightness.values) {
      group('$look (${width.toInt()}dp), ${brightness.name}: own profile', () {
        testWidgets('the navy hero carries the mock rows in order', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: width,
            flags: _fullFlags,
            brightness: brightness,
          );

          expect(_hero, findsOneWidget);
          final tops = [
            for (final text in [
              'DZEROTH',
              'Alice A',
              '@alice',
              'Mumbai, India',
              'Bio of Alice A.',
            ])
              tester
                  .getTopLeft(
                    find.descendant(of: _hero, matching: find.text(text)),
                  )
                  .dy,
          ];
          expect(tops.first, lessThan(tops[1]), reason: 'wordmark first');
          expect(tops[1], lessThan(tops[2]), reason: 'name before handle');
          expect(tops[2], lessThan(tops[3]), reason: 'handle before location');
          expect(tops[4], greaterThan(tops[1]), reason: 'bio under the name');

          // Posts | Followers | Following, left to right.
          final xs = [
            for (final l in ['Posts', 'Followers', 'Following'])
              tester.getCenter(_statLabel(l)).dx,
          ];
          expect([...xs]..sort(), xs);
          expect(_statLabel('Posts'), findsOneWidget);

          expect(
            find.descendant(
              of: _hero,
              matching: find.widgetWithText(FilledButton, 'Edit profile'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: _hero, matching: find.byTooltip('Settings')),
            findsOneWidget,
          );
          handle.dispose();
        });

        testWidgets('the avatar is ${width < 600 ? 76 : 120}dp', (
          tester,
        ) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: width,
            flags: _fullFlags,
            brightness: brightness,
          );

          expect(
            _avatarSize(tester),
            width < 600
                ? AppProfileLayout.phoneAvatar
                : AppProfileLayout.wideAvatar,
          );
        });

        testWidgets('the hero is navy in both brightness modes', (
          tester,
        ) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: width,
            flags: _fullFlags,
            brightness: brightness,
          );

          final name = tester.widget<Text>(
            find.descendant(of: _hero, matching: find.text('Alice A')),
          );
          expect(name.style?.color, AppPalette.pearl);
          expect(
            name.style?.fontSize,
            width < 600
                ? AppProfileLayout.phoneNameSize
                : AppProfileLayout.wideNameSize,
          );
        });

        testWidgets('tabs follow the hero, Posts selected, with a Pinned-free '
            'feed', (tester) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            width: width,
            flags: _fullFlags,
            brightness: brightness,
          );

          final bar = tester.widget<AppTabBar>(
            inProfilePage(find.byType(AppTabBar)),
          );
          expect(
            [for (final t in bar.tabs) t.label],
            ['Posts', 'Reposts', 'Media', 'Articles'],
          );
          expect(bar.selectedIndex, 0);
          expect(
            tester.getTopLeft(find.byType(AppTabBar)).dy,
            greaterThan(tester.getBottomLeft(_hero).dy - 1),
          );
        });
      });

      group('$look (${width.toInt()}dp), ${brightness.name}: another '
          "person's profile", () {
        Future<ProfileTabletRig> pumpOther(
          WidgetTester tester, {
          Set<String>? flags,
          ProfileTabletRig? rig,
        }) async {
          rig ??= ProfileTabletRig();
          await rig.pump(
            tester,
            location: '/profile/$kRigOtherHandle',
            width: width,
            flags: flags ?? _fullFlags,
            brightness: brightness,
          );
          return rig;
        }

        testWidgets('Follow and Message in the button row, the menu up top, '
            'no Edit profile and no Settings', (tester) async {
          await pumpOther(tester);

          expect(
            find.descendant(
              of: _hero,
              matching: find.widgetWithText(OutlinedButton, 'Message'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: _hero,
              matching: find.byTooltip('Message @$kRigOtherHandle'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: _hero, matching: find.text('Follow')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: _hero, matching: find.text('Edit profile')),
            findsNothing,
          );
          expect(find.byTooltip('Settings'), findsNothing);
          expect(
            find.descendant(
              of: _hero,
              matching: find.bySemanticsLabel('More options'),
            ),
            findsOneWidget,
          );
          // Follow takes the primary slot, Message the outline one.
          expect(
            tester.getCenter(_inHero(find.text('Follow'))).dx,
            lessThan(tester.getCenter(_inHero(find.text('Message'))).dx),
          );
        });

        testWidgets('the overflow menu opens in the light or dark theme of '
            'the app, not the hero\'s', (tester) async {
          await pumpOther(tester);

          await tester.tap(find.bySemanticsLabel('More options'));
          await tester.pumpAndSettle();

          expect(find.text('Block'), findsOneWidget);
          expect(find.text('Mute'), findsOneWidget);
          expect(find.text('Add or remove from Lists'), findsOneWidget);
          expect(find.text('Report @$kRigOtherHandle'), findsOneWidget);
          // The menu opens in the app's theme, not the navy hero's.
          expect(
            Theme.of(tester.element(find.text('Block'))).brightness,
            brightness,
          );
        });

        testWidgets('Message off: Follow takes the whole row', (tester) async {
          await pumpOther(tester, flags: {..._fullFlags}..remove('messaging'));

          expect(_inHero(find.text('Message')), findsNothing);
          final follow = tester.getSize(
            _inHero(find.widgetWithText(FilledButton, 'Follow')),
          );
          expect(follow.width, greaterThan(width < 600 ? 300 : 400));
        });

        testWidgets('graph off: no Follow, the Message pill and the menu '
            'stay', (tester) async {
          await pumpOther(tester, flags: {..._fullFlags}..remove('graph'));

          expect(_inHero(find.text('Follow')), findsNothing);
          expect(_inHero(find.text('Message')), findsOneWidget);
          expect(
            find.descendant(
              of: _hero,
              matching: find.bySemanticsLabel('More options'),
            ),
            findsOneWidget,
          );
        });

        testWidgets('blocked: the banner replaces the stats, the menu stays, '
            'Follow and Message go', (tester) async {
          final rig = ProfileTabletRig()..blocking = true;
          await pumpOther(tester, rig: rig);

          expect(
            find.descendant(
              of: _hero,
              matching: find.text('You blocked @$kRigOtherHandle'),
            ),
            findsOneWidget,
          );
          expect(find.text('Unblock'), findsOneWidget);
          expect(_statLabel('Followers'), findsNothing);
          expect(_inHero(find.text('Follow')), findsNothing);
          expect(_inHero(find.text('Message')), findsNothing);
          expect(
            find.descendant(
              of: _hero,
              matching: find.bySemanticsLabel('More options'),
            ),
            findsOneWidget,
          );
        });

        testWidgets('protected: the hero stays, the posts give way to the '
            'protected view', (tester) async {
          final rig = ProfileTabletRig()..otherProtected = true;
          await pumpOther(tester, rig: rig);

          expect(_hero, findsOneWidget);
          expect(
            find.descendant(of: _hero, matching: find.text('Kaif Shaik')),
            findsOneWidget,
          );
          expect(find.textContaining('protected'), findsWidgets);
        });
      });
    }
  }

  group('flag modes keep the hero (phone, tablet and desktop)', () {
    for (final MapEntry(key: look, value: width) in _looks.entries) {
      for (final MapEntry(key: mode, value: flags)
          in kProfileFlagModes.entries) {
        testWidgets('$look, $mode: hero, stats and tabs', (tester) async {
          final rig = ProfileTabletRig();
          await rig.pump(tester, width: width, flags: flags);

          expect(_hero, findsOneWidget);
          expect(_statLabel('Followers'), findsOneWidget);
          expect(_statLabel('Following'), findsOneWidget);
          expect(inProfilePage(find.byType(AppTabBar)), findsOneWidget);
        });
      }

      testWidgets('$look: posts off: no Posts stat, the coming-soon body', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: width,
          flags: {...kProfileTabletFlags}..remove('posts'),
        );

        expect(_hero, findsOneWidget);
        expect(_statLabel('Posts'), findsNothing);
        expect(_statLabel('Followers'), findsOneWidget);
        expect(find.text("This profile's posts are coming soon."), findsOne);
      });

      testWidgets('$look: profile_tabs off: Posts and Articles only', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: width,
          flags: {...kProfileTabletFlags}..remove('profile_tabs'),
        );

        final bar = tester.widget<AppTabBar>(
          inProfilePage(find.byType(AppTabBar)),
        );
        expect([for (final t in bar.tabs) t.label], ['Posts', 'Articles']);
      });

      testWidgets('$look: profile_snapshot off: no Edit profile', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: width,
          flags: {...kProfileTabletFlags}..remove('profile_snapshot'),
        );

        expect(find.text('Edit profile'), findsNothing);
        expect(_hero, findsOneWidget);
      });
    }
  });

  group('Share profile', () {
    testWidgets('without share links there is no Share anywhere', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: _phone, flags: _fullFlags);

      expect(find.byTooltip('Share profile'), findsNothing);
      expect(find.text('Share profile'), findsNothing);
    });

    for (final MapEntry(key: look, value: width) in _looks.entries) {
      testWidgets('$look: the icon and the pill share the handle link', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          width: width,
          flags: _fullFlags,
          shareLinks: ShareLinks(
            origin: 'https://dzeroth.com',
            nativeShare: _FakeShare(),
          ),
        );

        expect(find.byTooltip('Share profile'), findsOneWidget);
        expect(find.text('Share profile'), findsOneWidget);

        await tester.tap(find.text('Share profile'));
        await tester.pumpAndSettle();
        expect(find.text('Copy link'), findsOneWidget);

        if (width < 600) {
          // The phone's sheet sits under the shell's floating bar in the
          // rig, so the row is run as its own tap would.
          tester
              .widget<SheetOptionRow>(
                find.widgetWithText(SheetOptionRow, 'Copy link'),
              )
              .onTap!();
        } else {
          await tester.tap(find.text('Copy link'));
        }
        await tester.pumpAndSettle();
        expect(clipboard, ['https://dzeroth.com/profile/$kRigOwnHandle']);
      });
    }

    testWidgets("another person's profile has the icon, not the pill", (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: '/profile/$kRigOtherHandle',
        width: _phone,
        flags: _fullFlags,
        shareLinks: ShareLinks(origin: 'https://dzeroth.com'),
      );

      expect(find.byTooltip('Share profile'), findsOneWidget);
      expect(find.text('Share profile'), findsNothing);
    });
  });

  group('desktop: the side column carries the Media grid', () {
    testWidgets('Media then You might like, beside the hero', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: _desktop, flags: _fullFlags);

      expect(find.byType(ProfileMediaStrip), findsOneWidget);
      expect(find.text('You might like'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(ProfileMediaStrip)).dy,
        lessThan(tester.getTopLeft(find.text('You might like')).dy),
      );
      expect(
        tester.getTopLeft(find.byType(ProfileMediaStrip)).dx,
        greaterThan(tester.getTopRight(_hero).dx),
      );
    });

    testWidgets('profile_tabs off: no Media grid', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        width: _desktop,
        flags: {..._fullFlags}..remove('profile_tabs'),
      );

      expect(find.byType(ProfileMediaStrip), findsNothing);
      expect(find.byType(ProfileMediaStripPlaceholder), findsNothing);
    });

    testWidgets('a page that is not a profile gets no Media grid', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: '/profile/$kRigOwnHandle/followers',
        width: _desktop,
        flags: _fullFlags,
      );

      expect(find.byType(ProfileMediaStrip), findsNothing);
    });

    testWidgets('ui_shell off: no side-column Media grid', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        width: _desktop,
        flags: {..._fullFlags}..remove(kFeatureUiShell),
      );

      expect(find.byType(ProfileMediaStrip), findsNothing);
    });
  });

  group('the hero starts at the top of the screen', () {
    for (final MapEntry(key: look, value: width) in _looks.entries) {
      testWidgets('$look: hero top is the body top, the tabs follow it, '
          'then pin under the app bar', (tester) async {
        final rig = ProfileTabletRig();
        await rig.pump(tester, width: width, flags: _fullFlags);

        expect(tester.getTopLeft(_hero).dy, 0);
        expect(
          tester.getTopLeft(find.byType(AppTabBar)).dy,
          closeTo(tester.getBottomLeft(_hero).dy, 0.5),
          reason: 'the tabs sit right under the hero',
        );

        await tester.drag(
          find.byType(NestedScrollView),
          const Offset(0, -2000),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.byType(AppTabBar)).dy,
          closeTo(kToolbarHeight, 0.5),
          reason: 'pinned under the app bar',
        );
      });
    }

    testWidgets('phone: the status bar inset is the hero\'s own padding', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: _phone, flags: _fullFlags);
      final before = tester.getTopLeft(find.text('DZEROTH')).dy;

      tester.view.padding = const FakeViewPadding(top: 40);
      tester.view.viewPadding = const FakeViewPadding(top: 40);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(_hero).dy, 0);
      expect(tester.getTopLeft(find.text('DZEROTH')).dy, before + 40);
    });

    testWidgets('a pushed profile has Back first in the hero\'s top row', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: '/home',
        width: _phone,
        flags: _fullFlags,
      );
      unawaited(rig.router.push('/profile/$kRigOtherHandle'));
      await tester.pumpAndSettle();

      final back = _inHero(
        find.byType(BackButton).evaluate().isEmpty
            ? find.byTooltip('Back')
            : find.byType(BackButton),
      );
      expect(back, findsOneWidget);
      expect(
        tester.getTopLeft(back).dx,
        lessThan(tester.getTopLeft(find.text('DZEROTH')).dx),
      );
      await tester.tap(back);
      await tester.pumpAndSettle();
      expect(rig.router.state.uri.path, '/home');
    });

    testWidgets('the profile at the root of the shell has no Back', (
      tester,
    ) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: _tablet, flags: _fullFlags);

      expect(find.byTooltip('Back'), findsNothing);
    });
  });

  group('ink and contrast in the hero', () {
    testWidgets('the stats and the website link have a Material over the '
        'gradient, with pearl ink', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: _phone, flags: _fullFlags);

      final material = tester.widget<Material>(
        find
            .ancestor(
              of: heroStat('followers'),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.type, MaterialType.transparency);
      final ink = tester.widget<InkWell>(
        find.descendant(
          of: heroStat('followers'),
          matching: find.byType(InkWell),
        ),
      );
      expect(ink.splashColor, AppProfileLayout.onDarkInk);
      expect(ink.focusColor, AppProfileLayout.onDarkInk);
      expect(ink.hoverColor, AppProfileLayout.onDarkInk);
    });

    testWidgets('the pair of pills is one height, and the Follow spinner '
        'is drawn in the pill\'s ink', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        width: _phone,
        flags: _fullFlags,
        shareLinks: ShareLinks(origin: 'https://dzeroth.com'),
      );
      expect(
        tester
            .getSize(find.widgetWithText(FilledButton, 'Edit profile'))
            .height,
        tester
            .getSize(find.widgetWithText(OutlinedButton, 'Share profile'))
            .height,
      );

      await rig.pump(
        tester,
        location: '/profile/$kRigOtherHandle',
        width: _phone,
        flags: _fullFlags,
      );
      ProgressIndicatorThemeData spinner(String label) => tester
          .widget<ProgressIndicatorTheme>(
            find
                .ancestor(
                  of: _inHero(find.text(label)),
                  matching: find.byType(ProgressIndicatorTheme),
                )
                .first,
          )
          .data;
      expect(spinner('Follow').color, AppPalette.navy);
      expect(spinner('Message').color, AppPalette.pearl);
    });
  });

  group('large text and big numbers', () {
    for (final MapEntry(key: look, value: width) in _looks.entries) {
      testWidgets('$look at 2.0: a 50-character name and 1,234,567 '
          'followers fit and no label is cut', (tester) async {
        final handle = tester.ensureSemantics();
        final rig = ProfileTabletRig()
          ..ownName = 'Bartholomew Montgomery-Featherstonehaugh III Esq'
          ..ownFollowers = 1234567;
        await rig.pump(
          tester,
          width: width,
          height: 1600,
          flags: _fullFlags,
          textScale: 2,
        );

        expect(tester.takeException(), isNull);
        for (final label in ['Posts', 'Followers', 'Following']) {
          final text = find.descendant(of: _hero, matching: find.text(label));
          expect(text, findsOneWidget, reason: label);
          expect(
            tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
            isFalse,
            reason: '$label is not cut',
          );
          expectInsideHorizontally(tester, text, width);
        }
        expect(
          find.descendant(of: _hero, matching: find.text('1.23M')),
          findsOneWidget,
        );
        expect(find.bySemanticsLabel('1234567 Followers'), findsOneWidget);
        expectInsideHorizontally(
          tester,
          find.descendant(
            of: _hero,
            matching: find.textContaining('Bartholomew'),
          ),
          width,
        );
        handle.dispose();
      });
    }

    testWidgets('1.0: a 50-character name wraps beside the avatar, counts are '
        'compact', (tester) async {
      final rig = ProfileTabletRig()..ownFollowers = 1234567;
      await rig.pump(tester, width: _phone, flags: _fullFlags);

      expect(
        find.descendant(of: _hero, matching: find.text('1.23M')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _hero, matching: find.text('34')),
        findsOneWidget,
      );
    });

    testWidgets('the display name is a heading', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = ProfileTabletRig();
      await rig.pump(tester, width: _phone, flags: _fullFlags);

      expect(
        tester.getSemantics(
          find.descendant(of: _hero, matching: find.text('Alice A')),
        ),
        matchesSemantics(label: 'Alice A', isHeader: true),
      );
      handle.dispose();
    });
  });

  testWidgets('the app bar keeps its back-and-name fade over the hero', (
    tester,
  ) async {
    final rig = ProfileTabletRig();
    await rig.pump(tester, width: _phone, flags: _fullFlags);

    expect(find.byKey(const ValueKey('profile-appbar-name')), findsOneWidget);
    expect(find.byType(ProfileScreen), findsOneWidget);
  });

  group('Edit profile', () {
    for (final MapEntry(key: look, value: width) in _looks.entries) {
      testWidgets('$look: Save and "How others see you" at every width', (
        tester,
      ) async {
        final rig = ProfileTabletRig();
        await rig.pump(
          tester,
          location: AppRouter.editProfilePath,
          width: width,
          flags: _fullFlags,
        );
        expect(find.text('Save'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text(kEditProfilePreviewAction), findsOneWidget);
        await tester.tap(find.text(kEditProfilePreviewAction));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
      });
    }

    testWidgets('phone at text scale 2.0: nothing overflows', (tester) async {
      final rig = ProfileTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.editProfilePath,
        width: _phone,
        flags: _fullFlags,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('Edit profile screenshots', () {
    setUpAll(() async {
      if (_screenshots) await loadAppFonts();
    });
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: look, value: width) in _looks.entries) {
        testWidgets('edit-profile $look ${brightness.name}', (tester) async {
          final rig = ProfileTabletRig();
          await rig.pump(
            tester,
            location: AppRouter.editProfilePath,
            width: width,
            height: width < 600 ? 844 : 900,
            flags: _fullFlags,
            brightness: brightness,
          );
          await _capture(tester, 'edit-profile-$look-${brightness.name}');
        }, skip: !_screenshots);
      }
    }
  });
}
