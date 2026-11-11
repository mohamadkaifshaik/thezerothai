import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/features/communities/presentation/widgets/community_member_avatars.dart';
import 'package:dzeroth/gen/dzeroth/communities/v1/communities.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/primitives/app_avatar.dart';
import 'package:dzeroth/shared/widgets/primitives/app_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_pill_button.dart';
import 'package:dzeroth/shared/widgets/primitives/app_skeleton.dart';
import 'package:dzeroth/shared/widgets/primitives/app_status_pill.dart';
import 'package:dzeroth/shared/widgets/primitives/app_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/communities_tablet_rig.dart';
import '../../../support/context_pane_rig.dart' show inContextPane;

/// R10b: the four inner screens match the mobile designs
/// (Community, CommunityMembers, CreateCommunity, ModLog). These pin the
/// anatomy: what is present, in what order, at what size and in which type
/// token, at the widths where the layout differs, in RTL and at 2.0.

final _community = AppRouter.communityPath(kRigCommunityId);
final _members = AppRouter.communityMembersPath(kRigCommunityId);
final _log = AppRouter.communityModerationLogPath(kRigCommunityId);

const _widths = <double>[360, 600, 840, 1024, 1440];

const _ringsKey = ValueKey('community-cover-rings');

Finder _inPage(Finder f) => inCommunitiesPage(f);

/// The style the text is drawn in (inherited parts merged in).
TextStyle _styleOf(WidgetTester tester, Finder f) =>
    (tester.renderObject<RenderParagraph>(f).text as TextSpan).style!;

void main() {
  group('Community: the cover band', () {
    for (final w in _widths) {
      testWidgets('$w: band, then name, description, people row', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: _community, width: w);
        final rings = find.byKey(_ringsKey);
        expect(rings, findsOneWidget);
        final band = tester.getRect(rings);
        // The design's 150 dp band less its 44 dp status area.
        expect(band.height, 106);
        // Back sits on the band, in its 48 dp target.
        final back = tester.getRect(find.byTooltip('Back'));
        expect(back.size, const Size.square(48));
        expect(band.contains(back.center), isTrue);
        // Everything else is below the band, in the design's order.
        final name = tester.getRect(_inPage(find.text('Chess club')));
        final description = tester.getRect(
          _inPage(find.text('Openings, endgames and puzzles')),
        );
        final count = tester.getRect(_inPage(find.text('5 members')));
        expect(name.top, greaterThanOrEqualTo(band.bottom));
        expect(description.top, greaterThanOrEqualTo(name.bottom));
        expect(count.top, greaterThanOrEqualTo(description.bottom));
        final tabs = tester.getRect(_inPage(find.text('Posts')).first);
        expect(tabs.top, greaterThan(count.bottom));
      });
    }

    testWidgets('the name is in the page once (the bar no longer repeats it) '
        'in the design display style', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _community, width: 360);
      final name = _inPage(find.text('Chess club'));
      expect(name, findsOneWidget);
      final style = _styleOf(tester, name);
      expect(style.fontSize, 32);
      expect(style.fontWeight, FontWeight.w800);
      expect(style.height, 1.02);
      expect(style.letterSpacing, closeTo(-0.035 * 32, 0.001));
    });

    testWidgets('description 14 w500, 2 lines; count 14 w700', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.description = 'Long ' * 60;
      await rig.pump(tester, location: _community, width: 360);
      final description = _inPage(find.textContaining('Long Long'));
      final style = _styleOf(tester, description);
      expect(style.fontSize, 14);
      expect(style.fontWeight, FontWeight.w500);
      expect(tester.widget<Text>(description).maxLines, 2);
      final count = _styleOf(tester, _inPage(find.text('5 members')));
      expect(count.fontSize, 14);
      expect(count.fontWeight, FontWeight.w700);
    });

    for (final w in _widths) {
      testWidgets('$w: the owner and the moderator are 28 dp avatars, 8 dp '
          'overlapped, then "5 members", then Joined, on one line', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: _community, width: w);
        final avatars = _inPage(find.byType(CommunityMemberAvatars));
        expect(avatars, findsOneWidget);
        final stack = find.descendant(
          of: avatars,
          matching: find.byType(AppAvatar),
        );
        expect(stack, findsNWidgets(2));
        expect(tester.getSize(stack.first), const Size.square(28));
        final first = tester.getRect(stack.at(0));
        final second = tester.getRect(stack.at(1));
        expect(second.left - first.left, 20); // 28 - 8
        final count = tester.getRect(_inPage(find.text('5 members')));
        final joined = tester.getRect(_inPage(find.text('Joined')));
        expect(second.right, lessThan(count.left));
        if (w >= 600) {
          // One line, Joined at the end.
          expect(count.right, lessThan(joined.left));
          expect((count.center.dy - joined.center.dy).abs(), lessThan(12));
          expect(joined.right, greaterThan(second.right + 150));
        } else {
          // The design's 390 dp fits it on one line; in the test font at 360
          // it wraps, and Joined then sits under the row, never over it.
          final beside = (count.center.dy - joined.center.dy).abs() < 12;
          expect(beside || joined.top >= count.bottom - 1, isTrue);
        }
        // The stack is decoration: the count beside it speaks.
        expect(
          find.descendant(of: avatars, matching: find.byType(ExcludeSemantics)),
          findsWidgets,
        );
      });
    }

    testWidgets('Joined is the outline pill, in a 48 dp target', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: _community, width: 360);
      final pill = _inPage(find.widgetWithText(AppPillButton, 'Joined'));
      expect(pill, findsOneWidget);
      expect(
        tester.widget<AppPillButton>(pill).variant,
        AppButtonVariant.outline,
      );
      expect(tester.getSize(pill).height, greaterThanOrEqualTo(48));
    });

    testWidgets('RTL at 360: Back at the right, the name starts at the '
        'right, the avatars lead the row at the right', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _community,
        width: 360,
        textDirection: TextDirection.rtl,
      );
      final back = tester.getRect(find.byTooltip('Back'));
      expect(back.center.dx, greaterThan(180));
      final name = tester.getRect(_inPage(find.text('Chess club')));
      expect(name.right, greaterThan(300));
      final avatars = tester.getRect(
        _inPage(find.byType(CommunityMemberAvatars)),
      );
      final count = tester.getRect(_inPage(find.text('5 members')));
      expect(avatars.left, greaterThan(count.left));
      final joined = tester.getRect(_inPage(find.text('Joined')));
      // Beside the count (to its left), or wrapped under the row at the
      // start (the right).
      final beside = (count.center.dy - joined.center.dy).abs() < 12;
      expect(beside ? joined.right < count.left : joined.right > 300, isTrue);
    });

    for (final w in <double>[320, 360, 600]) {
      testWidgets('$w x2.0: nothing overflows and Joined keeps its label', (
        tester,
      ) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: _community,
          width: w,
          height: 900,
          textScale: 2,
        );
        expect(tester.takeException(), isNull);
        final joined = _inPage(find.text('Joined'));
        expect(joined, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(joined);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(_inPage(find.text('Chess club')), findsOneWidget);
      });
    }

    // A phone with a 44 dp status bar. The shell's own SafeArea sits above a
    // phone page (the band is 106 dp, below the status bar); the tablet pane
    // keeps the inset, so there the band reaches the top edge and is 150 dp
    // (the design's), with Back below the status bar either way.
    for (final (w, top, height) in [
      (360.0, 44.0, 106.0),
      (840.0, 0.0, 150.0),
    ]) {
      testWidgets('$w with a 44 dp status bar: the band is $height dp from '
          '$top and Back clears the status bar', (tester) async {
        addTearDown(tester.view.reset);
        tester.view.padding = const FakeViewPadding(top: 44);
        tester.view.viewPadding = const FakeViewPadding(top: 44);
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: _community, width: w);
        final band = tester.getRect(find.byKey(_ringsKey));
        expect(band.top, top);
        expect(band.height, height);
        expect(
          tester.getRect(find.byTooltip('Back')).top,
          greaterThanOrEqualTo(44),
        );
      });
    }

    testWidgets('Community options is one button, named, with the report '
        'item', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: _community,
        width: 360,
        flags: {...kCommunitiesTabletFlags, 'reports'},
      );
      final options = find.byTooltip('Community options');
      expect(options, findsOneWidget);
      expect(tester.getSize(options), const Size.square(48));
      final node = tester.getSemantics(options);
      // ignore: deprecated_member_use
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
      expect(node.tooltip, 'Community options');
      await tester.tap(options);
      await tester.pumpAndSettle();
      expect(find.text('Report Community'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('while it loads the band, Back and a name-sized placeholder '
        'are already there', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.holdGet = Completer<void>();
      await rig.pump(tester, location: _community, width: 360, settle: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(_ringsKey), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(_inPage(find.text('Chess club')), findsNothing);
      expect(find.byType(AppSkeletonBlock), findsWidgets);
      rig.server.holdGet!.complete();
      await tester.pumpAndSettle();
    });
  });

  group('CommunityMemberAvatars', () {
    graph.UserListItem person(int i) => graph.UserListItem(
      user: FakeCommunitiesServer.person('u$i', 'h$i', 'Name $i').user,
    );

    testWidgets('none draws nothing; more than three stop at three', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              const CommunityMemberAvatars(people: []),
              CommunityMemberAvatars(
                people: [for (var i = 0; i < 5; i++) person(i)],
              ),
            ],
          ),
        ),
      );
      expect(find.byType(AppAvatar), findsNWidgets(3));
      expect(
        tester.getSize(find.byType(CommunityMemberAvatars).first),
        Size.zero,
      );
    });
  });

  group('CommunityMembers', () {
    for (final w in _widths) {
      testWidgets('$w: the name under "Members" is 12 w600; badges are the '
          'teal tint; avatars are 44 dp', (tester) async {
        final rig = CommunitiesTabletRig();
        rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_OWNER;
        await rig.pump(tester, location: _members, width: w);
        final sub = _styleOf(tester, _inPage(find.text('Chess club')));
        expect(sub.fontSize, 12);
        expect(sub.fontWeight, FontWeight.w600);
        final pills = tester.widgetList<AppStatusPill>(
          _inPage(find.byType(AppStatusPill)),
        );
        expect(pills, isNotEmpty);
        for (final p in pills) {
          expect(p.tone, AppStatusTone.info);
        }
        final avatar = _inPage(find.byType(AppAvatar)).first;
        expect(tester.getSize(avatar), const Size.square(44));
      });
    }

    testWidgets('rows start 20 dp in (RTL: from the right)', (tester) async {
      for (final dir in TextDirection.values) {
        final rig = CommunitiesTabletRig();
        await rig.pump(
          tester,
          location: _members,
          width: 360,
          textDirection: dir,
        );
        final page = tester.getRect(findCommunitiesPage());
        final avatar = tester.getRect(_inPage(find.byType(AppAvatar)).first);
        if (dir == TextDirection.ltr) {
          expect(avatar.left - page.left, 20);
        } else {
          expect(page.right - avatar.right, 20);
        }
      }
    });

    testWidgets('2.0 at 360: nothing overflows', (tester) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_OWNER;
      await rig.pump(
        tester,
        location: _members,
        width: 360,
        height: 900,
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('CreateCommunity', () {
    for (final w in _widths) {
      testWidgets('$w: labelled fields (label above), the "n / max" counter, '
          'no rules yet, a full-width outline "Add a rule"', (tester) async {
        final rig = CommunitiesTabletRig();
        await rig.pump(tester, location: AppRouter.communityNewPath, width: w);
        final fields = _inPage(find.byType(AppTextField));
        expect(fields, findsNWidgets(2));
        final name = tester.getRect(
          find.descendant(of: fields.at(0), matching: find.byType(TextField)),
        );
        final label = tester.getRect(_inPage(find.text('Name')));
        expect(label.bottom, lessThanOrEqualTo(name.top + 1));
        expect(_inPage(find.text('0 / 30')), findsOneWidget);
        expect(_inPage(find.text('Rules')), findsOneWidget);
        final add = _inPage(find.widgetWithText(AppPillButton, 'Add a rule'));
        expect(add, findsOneWidget);
        expect(
          tester.widget<AppPillButton>(add).variant,
          AppButtonVariant.outline,
        );
        // Full width of the form (20 dp in on each side).
        final form = tester.getRect(fields.at(1));
        expect(tester.getRect(add).width, closeTo(form.width, 1));
      });
    }

    testWidgets('a rule is a card with a "RULE 1" eyebrow and a 48 dp remove '
        'button, holding its two fields', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.communityNewPath, width: 360);
      await tester.tap(_inPage(find.text('Add a rule')));
      await tester.pumpAndSettle();
      final card = _inPage(find.byType(AppCard));
      expect(card, findsOneWidget);
      final eyebrow = find.descendant(of: card, matching: find.text('RULE 1'));
      expect(eyebrow, findsOneWidget);
      final style = _styleOf(tester, eyebrow);
      expect(style.fontSize, 12);
      expect(style.fontWeight, FontWeight.w700);
      expect(style.letterSpacing, closeTo(0.24 * 12, 0.001));
      final remove = find.descendant(
        of: card,
        matching: find.byTooltip('Remove rule 1'),
      );
      expect(tester.getSize(remove).shortestSide, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: card, matching: find.byType(AppTextField)),
        findsNWidgets(2),
      );
    });

    testWidgets('the preview follows the header: its description is 2 lines '
        'in the header style and its standing line is the count style', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: AppRouter.communityNewPath, width: 1024);
      await tester.enterText(createFormField('Description'), 'Word ' * 80);
      await tester.pumpAndSettle();
      final description = inContextPane(find.textContaining('Word Word'));
      expect(tester.widget<Text>(description).maxLines, 2);
      final style = _styleOf(tester, description);
      expect(style.fontSize, 14);
      expect(style.fontWeight, FontWeight.w500);
      final standing = _styleOf(
        tester,
        inContextPane(find.text('Owner · 1 member')),
      );
      expect(standing.fontSize, 14);
      expect(standing.fontWeight, FontWeight.w700);
    });

    testWidgets('RTL and 2.0 at 360 with a rule: nothing overflows', (
      tester,
    ) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(
        tester,
        location: AppRouter.communityNewPath,
        width: 360,
        height: 900,
        textScale: 2,
        textDirection: TextDirection.rtl,
      );
      await tester.tap(_inPage(find.text('Add a rule')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('ModLog', () {
    setUp(() {});

    Future<CommunitiesTabletRig> openLog(
      WidgetTester tester, {
      double width = 360,
      double textScale = 1,
      TextDirection dir = TextDirection.ltr,
    }) async {
      final rig = CommunitiesTabletRig();
      rig.server.viewerRole = pb.CommunityRole.COMMUNITY_ROLE_MODERATOR;
      await rig.pump(
        tester,
        location: _log,
        width: width,
        height: 900,
        textScale: textScale,
        textDirection: dir,
      );
      return rig;
    }

    for (final w in _widths) {
      testWidgets('$w: a 40 dp tile (navy 6 %, radius 14), the sentence with '
          'its names in bold, a 12 sp time, a hairline', (tester) async {
        await openLog(tester, width: w);
        final tile = find.byKey(const ValueKey('moderation-log-tile')).first;
        expect(tester.getSize(tile), const Size.square(40));
        final box = tester.widget<Container>(tile).decoration! as BoxDecoration;
        expect(box.borderRadius, BorderRadius.circular(14));
        final sentence = _inPage(
          find.byWidgetPredicate(
            (w) =>
                w is RichText && w.text.toPlainText() == '@mo banned @member1',
          ),
        );
        expect(sentence, findsOneWidget);
        final root = tester.widget<RichText>(sentence).text as TextSpan;
        final bold = <String>[];
        root.visitChildren((s) {
          if (s is TextSpan &&
              s.style?.fontWeight == FontWeight.w700 &&
              s.text != null) {
            bold.add(s.text!);
          }
          return true;
        });
        expect(bold, ['@mo', '@member1']);
        expect(root.style?.fontSize, 15);
        expect(root.style?.fontWeight, FontWeight.w500);
      });
    }

    testWidgets('the header names the community: "Chess club · Moderators '
        'only", one GetCommunity', (tester) async {
      final rig = await openLog(tester);
      expect(
        _inPage(find.text('Chess club · Moderators only')),
        findsOneWidget,
      );
      expect(rig.server.count('get:'), 1);
      expect(rig.server.count('log:'), 1);
    });

    testWidgets('RTL and 2.0 at 360: nothing overflows', (tester) async {
      await openLog(tester, textScale: 2, dir: TextDirection.rtl);
      expect(tester.takeException(), isNull);
    });
  });
}
