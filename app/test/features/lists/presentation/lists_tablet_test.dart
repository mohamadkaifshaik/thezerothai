import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
import 'package:dzeroth/features/lists/presentation/user_lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/widgets/home_tabs_preview.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_members_pane.dart';
import 'package:dzeroth/features/lists/presentation/widgets/lists_owner_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:dzeroth/shared/widgets/primitives/app_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/context_pane_rig.dart'
    show expectTabletPanes, findContextPane;
import '../../../support/lists_tablet_rig.dart';
import '../../../support/tablet_modal_harness.dart'
    show openDialogRect, tabletContentRect;
import '../../../support/theme_harness.dart';

const _widths = <double>[360, 599, 600, 839, 840, 1024, 1199, 1200];

bool _tabletFlags(Set<String> flags) =>
    flags.contains(kFeatureUiShell) && flags.contains(kFeatureUiTablet);

bool _bandA(double w) =>
    w >= AppBreakpoints.mobile && w < AppBreakpoints.expanded;

bool _bandB(double w) =>
    w >= AppBreakpoints.expanded && w < AppBreakpoints.tablet;

final _listPath = AppRouter.listPath(kRigListId);
final _membersPath = AppRouter.listMembersPath(kRigListId);
final _userListsPath = AppRouter.userListsPath(kRigOwnerId);

/// Opens the List as the app does: a row of Lists pushes it.
Future<void> _openList(
  WidgetTester tester,
  ListsTabletRig rig, {
  double width = 1024,
  double height = 900,
  Set<String> flags = kListsTabletFlags,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  TextDirection textDirection = TextDirection.ltr,
  bool settle = true,
}) => rig.pump(
  tester,
  location: AppRouter.listsPath,
  push: [_listPath],
  width: width,
  height: height,
  flags: flags,
  textScale: textScale,
  brightness: brightness,
  textDirection: textDirection,
  settle: settle,
);

/// Opens Manage pinned as the app does: Home's "+" pushes it.
Future<void> _openPinned(
  WidgetTester tester,
  ListsTabletRig rig, {
  double width = 1024,
  double height = 900,
  Set<String> flags = kListsTabletFlags,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool settle = true,
}) => rig.pump(
  tester,
  location: AppRouter.homePath,
  push: [AppRouter.pinnedPath],
  width: width,
  height: height,
  flags: flags,
  textScale: textScale,
  brightness: brightness,
  settle: settle,
);

/// Opens a person's Lists as the app does: their profile pushes it with the
/// handle.
Future<void> _openUserLists(
  WidgetTester tester,
  ListsTabletRig rig, {
  double width = 1024,
  double height = 900,
  Set<String> flags = kListsTabletFlags,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool settle = true,
}) => rig.pump(
  tester,
  location: AppRouter.profilePath('olivia'),
  push: [_userListsPath],
  pushExtra: 'olivia',
  width: width,
  height: height,
  flags: flags,
  textScale: textScale,
  brightness: brightness,
  settle: settle,
);

void main() {
  group('Lists (/lists)', () {
    for (final MapEntry(key: mode, value: flags) in kListsFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: no pane', (tester) async {
          final rig = ListsTabletRig();
          await rig.pump(tester, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(inListsPage(find.text('Your Lists')), findsOneWidget);
          expect(findContextPane(), findsNothing);
          // F10: no "Discover new Lists" and no Lists search, anywhere.
          expect(find.textContaining('Discover'), findsNothing);
          expect(find.textContaining('Search Lists'), findsNothing);
          expect(rig.server.count('ListUserLists'), 1);
          expect(
            find.byType(AppSideColumn),
            w >= AppBreakpoints.tablet ? findsOneWidget : findsNothing,
          );
        });
      }
    }
  });

  group('ListDetail (/lists/:id)', () {
    for (final MapEntry(key: mode, value: flags) in kListsFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: no pane, no members preview', (tester) async {
          final rig = ListsTabletRig();
          await _openList(tester, rig, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          // R-inline: the header's count stays in the page at every width.
          expect(inListsPage(find.text('3 members')), findsOneWidget);
          expect(findContextPane(), findsNothing);
          // The preview lived in the pane only; nothing draws or asks for it.
          expect(find.text(kListMembersPaneTitle), findsNothing);
          expect(find.byType(ListMembersPane), findsNothing);
          expect(rig.server.count('ListListMembers'), 0);
          expect(
            find.byType(AppSideColumn),
            w >= AppBreakpoints.tablet ? findsOneWidget : findsNothing,
          );
        });
      }
    }
  });

  group('ListMembers (/lists/:id/members)', () {
    for (final MapEntry(key: mode, value: flags) in kListsFlagModes.entries) {
      for (final w in _widths) {
        testWidgets('$mode at $w: no pane', (tester) async {
          final rig = ListsTabletRig();
          await rig.pump(
            tester,
            location: _membersPath,
            width: w,
            flags: flags,
          );
          expect(tester.takeException(), isNull);

          for (final (_, _, name) in kRigMembers) {
            expect(inListsPage(find.text(name)), findsOneWidget);
          }
          expect(findContextPane(), findsNothing);
          // F31 "Suggested for this List" stays hidden in every placement.
          expect(find.textContaining('Suggested'), findsNothing);
          expect(rig.server.count('ListListMembers'), 1);
        });
      }
    }
  });

  group('ManagePinned (/home/pinned)', () {
    for (final MapEntry(key: mode, value: flags) in kListsFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && (_bandA(w) || _bandB(w));
        testWidgets('$mode at $w: the Home tabs preview '
            '${tablet ? 'at the top of the page' : 'not shown'}', (
          tester,
        ) async {
          final rig = ListsTabletRig()..server.pinRigList();
          await _openPinned(tester, rig, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(inListsPage(find.text('Add from your Lists')), findsOneWidget);
          expect(findContextPane(), findsNothing);
          final preview = find.byType(HomeTabsPreviewCard);
          if (tablet) {
            expect(inListsPage(preview), findsOneWidget);
            // At the top: above the "Pinned" section.
            expect(
              tester.getRect(preview).bottom,
              lessThanOrEqualTo(tester.getRect(find.text('Pinned')).top),
            );
            expect(
              find.bySemanticsLabel('Home tabs preview: Following, Friends'),
              findsOneWidget,
            );
          } else {
            expect(preview, findsNothing);
          }
          // [L] The location project's "Nearby" tab is never previewed.
          expect(find.textContaining('Nearby'), findsNothing);
          expect(rig.server.count('SetHomeTabs'), 0);
        });
      }
    }
  });

  group('UserLists (/u/:id/lists)', () {
    for (final MapEntry(key: mode, value: flags) in kListsFlagModes.entries) {
      for (final w in _widths) {
        final tablet = _tabletFlags(flags) && (_bandA(w) || _bandB(w));
        testWidgets('$mode at $w: the owner card '
            '${tablet ? 'heading the Lists' : 'not shown'}', (tester) async {
          final rig = ListsTabletRig();
          await _openUserLists(tester, rig, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(inListsPage(find.textContaining('Chess')), findsOneWidget);
          expect(findContextPane(), findsNothing);
          final card = find.byType(ListsOwnerCard);
          if (tablet) {
            expect(inListsPage(card), findsOneWidget);
            expect(
              tester.getRect(card).bottom,
              lessThanOrEqualTo(
                tester.getRect(inListsPage(find.text('Lists')).last).top,
              ),
            );
            expect(
              find.descendant(of: card, matching: find.text('Olivia Owner')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: card, matching: find.text('@olivia')),
              findsOneWidget,
            );
          } else {
            expect(card, findsNothing);
          }
          expect(rig.server.count('ListUserLists'), 1);
        });
      }
    }
  });

  group('band B pushes no pane over any page', () {
    testWidgets('a List pushed over Lists, then back', (tester) async {
      final rig = ListsTabletRig();
      await _openList(tester, rig);
      expect(rig.uri.path, _listPath);
      expect(findContextPane(), findsNothing);
      expect(inListsPage(find.text('3 members')), findsOneWidget);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
      expect(inListsPage(find.text('Your Lists')), findsOneWidget);
    });

    testWidgets('Manage pinned pushed over Home, then back', (tester) async {
      final rig = ListsTabletRig()..server.pinRigList();
      await _openPinned(tester, rig);
      expect(findContextPane(), findsNothing);
      expect(inListsPage(find.byType(HomeTabsPreviewCard)), findsOneWidget);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
    });

    testWidgets("a person's Lists pushed over their profile, then back", (
      tester,
    ) async {
      final rig = ListsTabletRig();
      await _openUserLists(tester, rig);
      expect(findContextPane(), findsNothing);
      expect(inListsPage(find.byType(ListsOwnerCard)), findsOneWidget);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(findContextPane(), findsNothing);
    });
  });

  group('state across resizes', () {
    testWidgets('ListDetail: the same page, never a preview ask', (
      tester,
    ) async {
      final rig = ListsTabletRig();
      await _openList(tester, rig, width: 744);
      final state = tester.state(find.byType(ListDetailScreen));

      for (final w in <double>[1024, 839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(ListDetailScreen)),
          same(state),
          reason: '$w',
        );
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(inListsPage(find.text('3 members')), findsOneWidget);
        expect(rig.server.count('ListListMembers'), 0, reason: '$w');
      }
    });

    testWidgets('ManagePinned: the same page; the preview stays at the top '
        'of the page across the tablet bands', (tester) async {
      final rig = ListsTabletRig()..server.pinRigList();
      await _openPinned(tester, rig);
      final state = tester.state(find.byType(ManagePinnedScreen));
      for (final w in <double>[839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(ManagePinnedScreen)),
          same(state),
          reason: '$w',
        );
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(
          inListsPage(find.byType(HomeTabsPreviewCard)),
          _bandA(w) || _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      expect(rig.server.count('ListUserLists'), 1);
    });

    testWidgets('UserLists: the same page; the owner card stays in the page '
        'across the tablet bands', (tester) async {
      final rig = ListsTabletRig();
      await _openUserLists(tester, rig);
      final state = tester.state(find.byType(UserListsScreen));
      for (final w in <double>[839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(UserListsScreen)),
          same(state),
          reason: '$w',
        );
        expect(findContextPane(), findsNothing, reason: '$w');
        expect(
          inListsPage(find.byType(ListsOwnerCard)),
          _bandA(w) || _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      expect(rig.server.count('ListUserLists'), 1);
    });
  });

  group('the Home tabs preview follows the editor in both bands', () {
    for (final w in <double>[744, 1024]) {
      testWidgets('at $w: Unpin and Pin change the preview at once', (
        tester,
      ) async {
        final rig = ListsTabletRig()..server.pinRigList();
        await _openPinned(tester, rig, width: w);
        expect(
          find.bySemanticsLabel('Home tabs preview: Following, Friends'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Unpin Friends'));
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel('Home tabs preview: Following'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Pin Books to Home'));
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel('Home tabs preview: Following, Books'),
          findsOneWidget,
        );
        expect(rig.server.count('SetHomeTabs'), 2);
      });

      testWidgets('at $w: the preview is a picture: a tap on a tab does '
          'nothing and no tab takes focus', (tester) async {
        final rig = ListsTabletRig()..server.pinRigList();
        await _openPinned(tester, rig, width: w);
        final preview = inListsPage(find.byType(HomeTabsPreviewCard));
        final friends = find.descendant(
          of: preview,
          matching: find.text('Friends'),
        );
        await tester.tap(friends, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(rig.uri.path, AppRouter.pinnedPath);
        expect(
          find.descendant(of: preview, matching: find.byType(ExcludeFocus)),
          findsOneWidget,
        );
      });
    }
  });

  testWidgets("an unavailable List: the page's unavailable state, no Members "
      'card', (tester) async {
    final rig = ListsTabletRig()..server.listGone = true;
    await _openList(tester, rig);
    expect(find.text('This List is unavailable'), findsOneWidget);
    expect(find.text(kListMembersPaneTitle), findsNothing);
    expect(find.byType(ListMembersPanePlaceholder), findsNothing);
  });

  group('the owner card', () {
    for (final w in <double>[744, 1024]) {
      testWidgets('at $w: no card over "No public Lists"', (tester) async {
        final rig = ListsTabletRig()..server.ownerHasLists = false;
        await _openUserLists(tester, rig, width: w);
        expect(find.text('No public Lists'), findsOneWidget);
        expect(find.byType(ListsOwnerCard), findsNothing);
        expect(find.byType(ListsOwnerCardPlaceholder), findsNothing);
      });

      testWidgets(
        "at $w: it goes back to the owner's profile and is one 48 dp button",
        (tester) async {
          final rig = ListsTabletRig();
          await _openUserLists(tester, rig, width: w);
          final card = inListsPage(find.byType(ListsOwnerCard));
          expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
          expect(
            find.bySemanticsLabel(
              'Lists by Olivia Owner, @olivia. View profile',
            ),
            findsOneWidget,
          );
          await tester.tap(card);
          await tester.pumpAndSettle();
          // Opened from the profile: back to it (UX review item 3).
          expect(rig.uri.path, AppRouter.profilePath('olivia'));
        },
      );
    }
  });

  testWidgets('band B in RTL: no pane, the rail on the right', (tester) async {
    final rig = ListsTabletRig();
    await _openList(tester, rig, textDirection: TextDirection.rtl);
    expect(tester.takeException(), isNull);
    expect(findContextPane(), findsNothing);
    final rail = tester.getRect(find.byKey(const ValueKey('tablet-rail')));
    final page = tester.getRect(findListsPage());
    expect(rail.right, 1024);
    expect(page.right, rail.left);
    expect(inListsPage(find.text('3 members')), findsOneWidget);
  });

  group('lists off (no redirect in the rig): no pane, the inline copies', () {
    final flags = {...kListsTabletFlags}..remove('lists');
    for (final (name, open, preview, card)
        in <
          (
            String,
            Future<void> Function(WidgetTester, ListsTabletRig),
            Matcher,
            Matcher,
          )
        >[
          (
            'ListDetail',
            (t, r) => _openList(t, r, flags: flags),
            findsNothing,
            findsNothing,
          ),
          (
            'ManagePinned',
            (t, r) => _openPinned(t, r, flags: flags),
            findsOneWidget,
            findsNothing,
          ),
          (
            'UserLists',
            (t, r) => _openUserLists(t, r, flags: flags),
            findsNothing,
            findsOneWidget,
          ),
        ]) {
      testWidgets('$name at 1024', (tester) async {
        final rig = ListsTabletRig()..server.pinRigList();
        await open(tester, rig);
        expect(findContextPane(), findsNothing);
        expect(find.byType(ListMembersPane), findsNothing);
        expect(inListsPage(find.byType(HomeTabsPreviewCard)), preview);
        expect(inListsPage(find.byType(ListsOwnerCard)), card);
        expect(rig.server.count('ListListMembers'), 0);
      });
    }
  });

  group('section 4.2: menus and dialogs', () {
    for (final w in <double>[834, 1024]) {
      testWidgets('at $w "More options" on a List stays an anchored menu', (
        tester,
      ) async {
        final rig = ListsTabletRig();
        await _openList(tester, rig, width: w);
        final button = inListsPage(find.byTooltip('More options'));
        await tester.tap(button);
        await tester.pumpAndSettle();
        final item = find.text('Report List');
        expect(item, findsOneWidget);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        final itemRect = tester.getRect(item);
        expect(
          (itemRect.center - tester.getCenter(button)).distance,
          lessThan(300),
        );
        expect(
          itemRect.right,
          lessThanOrEqualTo(tester.getRect(findListsPage()).right),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(item, findsNothing);
      });
    }

    for (final w in <double>[700, 1024]) {
      final content = tabletContentRect(Size(w, 900));

      testWidgets('at $w the Remove confirm is a D 280-400 on the content '
          'area; Escape cancels', (tester) async {
        final rig = ListsTabletRig()..server.viewerOwnsList = true;
        await rig.pump(
          tester,
          location: AppRouter.listsPath,
          push: [_listPath, _membersPath],
          width: w,
        );
        await tester.tap(find.bySemanticsLabel('Remove @mia from this List'));
        await tester.pumpAndSettle();
        expect(find.text('Remove @mia?'), findsOneWidget);
        final rect = openDialogRect(tester);
        expect(rect.width, inInclusiveRange(280, 400));
        expect(rect.center.dx, closeTo(content.center.dx, 1));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Remove @mia?'), findsNothing);
        expect(rig.server.count('RemoveListMember'), 0);
      });

      testWidgets('at $w the List editor is a dialog on the content area, '
          'and its Delete confirm a D 280-400; Escape cancels', (tester) async {
        final rig = ListsTabletRig();
        await rig.pump(tester, width: w);
        await tester.tap(find.byTooltip('Edit Books'));
        await tester.pumpAndSettle();
        expect(find.text('Edit List'), findsOneWidget);
        final editor = openDialogRect(tester);
        expect(editor.width, lessThanOrEqualTo(480));
        expect(editor.width, lessThanOrEqualTo(content.width - 48));
        expect(editor.center.dx, closeTo(content.center.dx, 1));

        await tester.ensureVisible(find.text('Delete List'));
        await tester.tap(find.text('Delete List'));
        await tester.pumpAndSettle();
        expect(find.text('Delete this List?'), findsOneWidget);
        final confirm = tester.getRect(
          find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(confirm.width, inInclusiveRange(280, 400));
        expect(confirm.center.dx, closeTo(content.center.dx, 1));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Delete this List?'), findsNothing);
        expect(find.text('Edit List'), findsOneWidget);
      });
    }
  });

  group('tablet matrix (plan section 5.5)', () {
    final screens =
        <
          String,
          Future<void> Function(WidgetTester, ListsTabletRig, MatrixEnv)
        >{
          'Lists': (t, r, e) => r.pump(
            t,
            width: e.size.width,
            height: e.size.height,
            textScale: e.textScale,
            brightness: e.brightness,
          ),
          'ListDetail': (t, r, e) => _openList(
            t,
            r,
            width: e.size.width,
            height: e.size.height,
            textScale: e.textScale,
            brightness: e.brightness,
          ),
          'ListMembers': (t, r, e) => r.pump(
            t,
            location: AppRouter.listsPath,
            push: [_listPath, _membersPath],
            width: e.size.width,
            height: e.size.height,
            textScale: e.textScale,
            brightness: e.brightness,
          ),
          'ManagePinned': (t, r, e) => _openPinned(
            t,
            r,
            width: e.size.width,
            height: e.size.height,
            textScale: e.textScale,
            brightness: e.brightness,
          ),
          'UserLists': (t, r, e) => _openUserLists(
            t,
            r,
            width: e.size.width,
            height: e.size.height,
            textScale: e.textScale,
            brightness: e.brightness,
          ),
        };
    for (final MapEntry(key: name, value: open) in screens.entries) {
      forEachThemeAndWidth(
        '$name: no overflow, the rail pinned at 0, the panes of section 3',
        (tester, env) async {
          final rig = ListsTabletRig()
            ..server.viewerOwnsList = true
            ..server.pinRigList();
          await open(tester, rig, env);
          expect(tester.takeException(), isNull);
          expect(
            tester.getRect(find.byKey(const ValueKey('tablet-rail'))).left,
            0,
          );
          // No side column on the tablet layout: the page takes the whole
          // content in both bands.
          expectTabletPanes(
            tester,
            findListsPage(),
            env.size.width,
            hasPane: false,
          );
          expect(
            ShellGeometry.maybeOf(tester.element(findListsPage()))?.tablet,
            isTrue,
          );
        },
        widths: kTabletMatrixWidths,
        textScales: kTabletTextScales,
        heights: kTabletHeights,
      );
    }
  });

  for (final w in <double>[744, 1024]) {
    testWidgets('at $w with `location` on: still no "Nearby" tab in the '
        'Home tabs preview', (tester) async {
      final rig = ListsTabletRig()..server.pinRigList();
      await _openPinned(
        tester,
        rig,
        width: w,
        flags: {...kListsTabletFlags, 'location'},
      );
      expect(
        find.bySemanticsLabel('Home tabs preview: Following, Friends'),
        findsOneWidget,
      );
      expect(find.textContaining('Nearby'), findsNothing);
    });
  }

  group('UX review (T8b)', () {
    testWidgets('item 3: the owner card goes back to the profile it came '
        'from, not a second copy of it', (tester) async {
      final rig = ListsTabletRig();
      await _openUserLists(tester, rig);
      await tester.tap(inListsPage(find.byType(ListsOwnerCard)));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.profilePath('olivia'));
      expect(rig.router.canPop(), isFalse);
    });

    testWidgets('item 3: opened cold (nothing to pop), the owner card goes '
        'to the profile', (tester) async {
      final rig = ListsTabletRig();
      await rig.pump(tester, location: _userListsPath, width: 744);
      await tester.tap(inListsPage(find.byType(ListsOwnerCard)));
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.profileByIdPath(kRigOwnerId));
    });

    for (final w in <double>[744, 1024]) {
      testWidgets('item 4: at $w, the owner card and the Home tabs preview '
          'leave the same gap above the first section', (tester) async {
        double gapBelow(Type card) {
          final box = tester.getRect(
            find
                .descendant(
                  of: inListsPage(find.byType(card)),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          final section = tester.getRect(
            inListsPage(find.byType(AppSectionHeader)).first,
          );
          return section.top - box.bottom;
        }

        final owner = ListsTabletRig();
        await _openUserLists(tester, owner, width: w);
        final ownerGap = gapBelow(ListsOwnerCard);

        final pinned = ListsTabletRig()..server.pinRigList();
        await _openPinned(tester, pinned, width: w);
        final previewGap = gapBelow(HomeTabsPreviewCard);

        expect(ownerGap, previewGap);
        expect(ownerGap, AppSpacing.md);
      });
    }
  });
}
