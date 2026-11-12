import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_cover_band.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_hero.dart';
import 'package:dzeroth/features/communities/presentation/widgets/moderation_log_about.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_tile_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/communities_tablet_rig.dart';

// Communities, Community, CommunityMembers, ModLog and CreateCommunity from
// the dzeroth-mobile, tablet and desktop mocks: one feature, the same rows
// and actions, three looks. The phone keeps the cover band, a Back button and
// the 52 dp tiles; from 600 dp the page has the bar and the navy hero, no
// Back on the directory (the rail is the way out) and the 64 dp tiles; the
// desktop's log leads with "About this log" (its mock's side box).

const _screenshots = bool.fromEnvironment('COMMUNITIES_SCREENSHOTS');

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_screenshots) return;
  await tester.runAsync(() async {
    final image = await captureImage(tester.element(find.byType(MaterialApp)));
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/artifacts/communities/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _sizes = <String, Size>{
  'phone': Size(390, 844),
  'tablet': Size(1024, 768),
  'desktop': Size(1440, 900),
};

final _pages = <String, String>{
  'communities': AppRouter.communitiesPath,
  'community': AppRouter.communityPath(kRigCommunityId),
  'members': AppRouter.communityMembersPath(kRigCommunityId),
  'log': AppRouter.communityModerationLogPath(kRigCommunityId),
  'create': AppRouter.communityNewPath,
};

/// A rig on [location] as a moderator, so every page shows all it has.
Future<CommunitiesTabletRig> _open(
  WidgetTester tester,
  String location,
  Size size, {
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final rig = CommunitiesTabletRig();
  rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
  await rig.pump(
    tester,
    location: location,
    width: size.width,
    height: size.height,
    textScale: textScale,
    brightness: brightness,
  );
  return rig;
}

Future<void> _tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).first);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    if (_screenshots) await loadAppFonts();
  });

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    final phone = size.width < 600;
    final desktop = size.width >= 1200;

    group('$name (${size.width.toInt()} dp)', () {
      group('Communities', () {
        testWidgets('the look: Back and 52 dp tiles on a phone, neither from '
            '600 dp (64 dp tiles); the Joined pill on every row', (
          tester,
        ) async {
          await _open(tester, _pages['communities']!, size);
          expect(find.byTooltip('Back'), phone ? findsOneWidget : findsNothing);
          final row = find.byKey(const ValueKey('mine-$kRigCommunityId'));
          final tile = tester.getSize(
            find.descendant(of: row, matching: find.byType(AppTileIcon)),
          );
          expect(tile, Size.square(phone ? 52 : 64));
          expect(
            find.descendant(of: row, matching: find.byType(AppPillButton)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.text('Joined')),
            findsOneWidget,
          );
        });

        testWidgets('Create opens the form; a row opens the community; '
            'Explore lists the directory', (tester) async {
          final rig = await _open(tester, _pages['communities']!, size);
          await tester.tap(find.byTooltip('Create a community'));
          await tester.pumpAndSettle();
          expect(rig.uri.path, AppRouter.communityNewPath);
          rig.router.pop();
          await tester.pumpAndSettle();
          await tester.tap(find.text('Chess club'));
          await tester.pumpAndSettle();
          expect(rig.uri.path, AppRouter.communityPath(kRigCommunityId));
          rig.router.pop();
          await tester.pumpAndSettle();
          await showExploreTab(tester);
          expect(find.byKey(const ValueKey('explore-78')), findsOneWidget);
        });
      });

      group('Community', () {
        testWidgets('the look: the cover band on a phone; from 600 dp the '
            'bar and the navy hero', (tester) async {
          await _open(tester, _pages['community']!, size);
          expect(
            find.byType(CommunityCoverBand),
            phone ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(CommunityTopBar),
            phone ? findsNothing : findsOneWidget,
          );
          expect(
            find.byType(CommunityHero),
            phone ? findsNothing : findsOneWidget,
          );
          expect(find.text('COMMUNITY'), phone ? findsNothing : findsOneWidget);
          final name = tester.widget<Text>(find.text('Chess club'));
          expect(name.style?.fontSize, phone ? 32 : 48);
          expect(find.byTooltip('Back'), findsOneWidget);
        });

        testWidgets('the members count opens the members; Joined asks before '
            'leaving; Pin to Home pins; About has the rules', (tester) async {
          final rig = await _open(tester, _pages['community']!, size);
          await tester.tap(find.text('Joined'));
          await tester.pumpAndSettle();
          expect(find.text('Leave Chess club?'), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Pin to Home'));
          await tester.pumpAndSettle();
          expect(rig.pinCalls, 1);
          await _tapTab(tester, 'About');
          expect(find.text('Be kind'), findsOneWidget);
          await _tapTab(tester, 'Posts');
          await tester.tap(find.text('5 members'));
          await tester.pumpAndSettle();
          expect(rig.uri.path, AppRouter.communityMembersPath(kRigCommunityId));
        });
      });

      group('CommunityMembers', () {
        testWidgets('a moderator has the three tabs and "View moderation '
            'log", which opens the log', (tester) async {
          final rig = await _open(tester, _pages['members']!, size);
          for (final tab in ['Members', 'Moderators', 'Banned']) {
            expect(find.text(tab), findsWidgets);
          }
          expect(find.text('Olivia'), findsOneWidget);
          await tester.tap(find.text('View moderation log'));
          await tester.pumpAndSettle();
          expect(
            rig.uri.path,
            AppRouter.communityModerationLogPath(kRigCommunityId),
          );
        });

        testWidgets('a member has no log link', (tester) async {
          final rig = CommunitiesTabletRig();
          await rig.pump(
            tester,
            location: _pages['members']!,
            width: size.width,
            height: size.height,
          );
          expect(find.text('View moderation log'), findsNothing);
        });
      });

      group('ModLog', () {
        testWidgets('About this log leads the log on desktop only', (
          tester,
        ) async {
          await _open(tester, _pages['log']!, size);
          expect(find.text('Moderation log'), findsOneWidget);
          expect(find.textContaining('@member1'), findsWidgets);
          expect(
            find.byType(ModerationLogAbout),
            desktop ? findsOneWidget : findsNothing,
          );
        });
      });

      group('CreateCommunity', () {
        testWidgets('Preview from 600 dp; Add a rule adds a rule at every '
            'width', (tester) async {
          await _open(tester, _pages['create']!, size);
          expect(
            find.widgetWithText(TextButton, 'Preview'),
            phone ? findsNothing : findsOneWidget,
          );
          final add = find.widgetWithText(AppPillButton, 'Add a rule');
          expect(tester.widget<AppPillButton>(add).compact, !phone);
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(createFormField('Rule 1 title'), findsOneWidget);
          if (!phone) {
            await tester.enterText(createFormField('Name'), 'Go club');
            await tester.tap(find.widgetWithText(TextButton, 'Preview'));
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(Dialog),
                matching: find.text('Go club'),
              ),
              findsOneWidget,
            );
          }
        });
      });

      if (phone) {
        for (final MapEntry(key: page, value: path) in _pages.entries) {
          testWidgets('$page at text scale 2.0: nothing overflows', (
            tester,
          ) async {
            await _open(tester, path, size, textScale: 2);
            expect(tester.takeException(), isNull);
          });
        }
      }
    });
  }

  group('screenshots', () {
    for (final brightness in Brightness.values) {
      for (final MapEntry(key: name, value: size) in _sizes.entries) {
        for (final MapEntry(key: page, value: path) in _pages.entries) {
          testWidgets('$page $name ${brightness.name}', (tester) async {
            await _open(tester, path, size, brightness: brightness);
            await _capture(tester, '$page-$name-${brightness.name}');
          }, skip: !_screenshots);
        }
      }
    }
  });
}
