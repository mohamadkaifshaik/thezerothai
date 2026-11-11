import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/widgets/context_pane.dart';
import 'package:dzeroth/core/widgets/context_pane_slots.dart';
import 'package:dzeroth/features/lists/presentation/bloc/list_members_preview_cubit.dart';
import 'package:dzeroth/core/widgets/shell_geometry.dart';
import 'package:dzeroth/features/lists/presentation/list_detail_screen.dart';
import 'package:dzeroth/features/lists/presentation/manage_pinned_screen.dart';
import 'package:dzeroth/features/lists/presentation/user_lists_screen.dart';
import 'package:dzeroth/features/lists/presentation/widgets/home_tabs_preview.dart';
import 'package:dzeroth/features/lists/presentation/widgets/list_members_pane.dart';
import 'package:dzeroth/features/lists/presentation/widgets/lists_owner_card.dart';
import 'package:dzeroth/shared/widgets/primitives/app_side_column.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/context_pane_rig.dart'
    show expectTabletPanes, findContextPane, inContextPane;
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

/// The kinds of the context pane's sections, top to bottom (empty: no pane).
List<ContextSectionKind> _paneKinds(WidgetTester tester) {
  final pane = findContextPane();
  if (pane.evaluate().isEmpty) return const [];
  return [for (final s in tester.widget<ContextPane>(pane).sections) s.kind];
}

const _global = [
  ContextSectionKind.search,
  ContextSectionKind.profile,
  ContextSectionKind.trends,
  ContextSectionKind.whoToFollow,
  ContextSectionKind.links,
];

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
        final pane = _tabletFlags(flags) && _bandB(w);
        testWidgets('$mode at $w: ${pane ? 'the global set' : 'no pane'}', (
          tester,
        ) async {
          final rig = ListsTabletRig();
          await rig.pump(tester, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(inListsPage(find.text('Your Lists')), findsOneWidget);
          expect(_paneKinds(tester), pane ? _global : isEmpty);
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
        final pane = _tabletFlags(flags) && _bandB(w);
        testWidgets('$mode at $w: '
            '${pane ? 'the members preview in the pane' : 'no pane'}', (
          tester,
        ) async {
          final rig = ListsTabletRig();
          await _openList(tester, rig, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          // R-inline: the header's count stays in the page at every width.
          expect(inListsPage(find.text('3 members')), findsOneWidget);
          if (pane) {
            expect(_paneKinds(tester), [
              ContextSectionKind.listMembers,
              ContextSectionKind.links,
            ]);
            expect(
              inContextPane(find.text(kListMembersPaneTitle)),
              findsOneWidget,
            );
            for (final (_, _, name) in kRigMembers) {
              expect(inContextPane(find.text(name)), findsOneWidget);
            }
            expect(
              inContextPane(find.text(kSeeAllMembersLabel)),
              findsOneWidget,
            );
          } else {
            expect(findContextPane(), findsNothing);
            expect(find.text(kListMembersPaneTitle), findsNothing);
          }
          // The preview is asked for only where it shows.
          expect(rig.server.count('ListListMembers'), pane ? 1 : 0);
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
        final pane = _tabletFlags(flags) && _bandB(w);
        testWidgets('$mode at $w: ${pane ? 'the global set' : 'no pane'}', (
          tester,
        ) async {
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
          expect(_paneKinds(tester), pane ? _global : isEmpty);
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
        final pane = tablet && _bandB(w);
        testWidgets('$mode at $w: the Home tabs preview '
            '${pane
                ? 'in the pane'
                : tablet
                ? 'at the top of the page'
                : 'not shown'}', (tester) async {
          final rig = ListsTabletRig()..server.pinRigList();
          await _openPinned(tester, rig, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(inListsPage(find.text('Add from your Lists')), findsOneWidget);
          final preview = find.byType(HomeTabsPreviewCard);
          if (pane) {
            expect(_paneKinds(tester), [
              ContextSectionKind.homeTabsPreview,
              ContextSectionKind.links,
            ]);
            expect(inContextPane(preview), findsOneWidget);
            expect(inListsPage(preview), findsNothing);
          } else if (tablet) {
            expect(findContextPane(), findsNothing);
            expect(inListsPage(preview), findsOneWidget);
            // At the top: above the "Pinned" section.
            expect(
              tester.getRect(preview).bottom,
              lessThanOrEqualTo(tester.getRect(find.text('Pinned')).top),
            );
          } else {
            expect(findContextPane(), findsNothing);
            expect(preview, findsNothing);
          }
          if (tablet) {
            expect(
              find.bySemanticsLabel('Home tabs preview: Following, Friends'),
              findsOneWidget,
            );
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
        final pane = tablet && _bandB(w);
        testWidgets('$mode at $w: the owner card '
            '${pane
                ? 'in the pane'
                : tablet
                ? 'heading the Lists'
                : 'not shown'}', (tester) async {
          final rig = ListsTabletRig();
          await _openUserLists(tester, rig, width: w, flags: flags);
          expect(tester.takeException(), isNull);

          expect(inListsPage(find.textContaining('Chess')), findsOneWidget);
          final card = find.byType(ListsOwnerCard);
          if (pane) {
            expect(_paneKinds(tester), [
              ContextSectionKind.listsOwner,
              ContextSectionKind.links,
            ]);
            expect(inContextPane(card), findsOneWidget);
            expect(inListsPage(card), findsNothing);
          } else if (tablet) {
            expect(findContextPane(), findsNothing);
            expect(inListsPage(card), findsOneWidget);
            expect(
              tester.getRect(card).bottom,
              lessThanOrEqualTo(
                tester.getRect(inListsPage(find.text('Lists')).last).top,
              ),
            );
          } else {
            expect(card, findsNothing);
          }
          if (tablet) {
            expect(
              find.descendant(of: card, matching: find.text('Olivia Owner')),
              findsOneWidget,
            );
            expect(
              find.descendant(of: card, matching: find.text('@olivia')),
              findsOneWidget,
            );
          }
          expect(rig.server.count('ListUserLists'), 1);
        });
      }
    }
  });

  group('the pane follows the pushed page', () {
    testWidgets('band B: a List pushed over Lists gets its members; back '
        'restores the global set', (tester) async {
      final rig = ListsTabletRig();
      await _openList(tester, rig);
      expect(rig.uri.path, _listPath);
      expect(_paneKinds(tester), [
        ContextSectionKind.listMembers,
        ContextSectionKind.links,
      ]);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(_paneKinds(tester), _global);
      expect(find.text(kListMembersPaneTitle), findsNothing);
    });

    testWidgets('band B: Manage pinned pushed over Home gets its preview; '
        "back restores Home's pane", (tester) async {
      final rig = ListsTabletRig();
      await _openPinned(tester, rig);
      expect(_paneKinds(tester), [
        ContextSectionKind.homeTabsPreview,
        ContextSectionKind.links,
      ]);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(_paneKinds(tester), _global);
    });

    testWidgets("band B: a person's Lists pushed over their profile gets "
        "the owner card; back restores the profile's pane", (tester) async {
      final rig = ListsTabletRig();
      await _openUserLists(tester, rig);
      expect(_paneKinds(tester), [
        ContextSectionKind.listsOwner,
        ContextSectionKind.links,
      ]);
      rig.router.pop();
      await tester.pumpAndSettle();
      expect(_paneKinds(tester), [
        ContextSectionKind.whoToFollow,
        ContextSectionKind.links,
      ]);
    });

    testWidgets('band B: "See all members" opens Members (the global set); '
        'back brings the preview with no second preview call', (tester) async {
      final rig = ListsTabletRig();
      await _openList(tester, rig);
      await tester.tap(inContextPane(find.text(kSeeAllMembersLabel)));
      await tester.pumpAndSettle();
      expect(rig.uri.path, _membersPath);
      expect(_paneKinds(tester), _global);
      expect(rig.server.count('ListListMembers'), 2, reason: 'preview + page');

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(_paneKinds(tester), [
        ContextSectionKind.listMembers,
        ContextSectionKind.links,
      ]);
      expect(inContextPane(find.text('Mia')), findsOneWidget);
      expect(rig.server.count('ListListMembers'), 2);
    });
  });

  group('placeholders, one pump after the push', () {
    testWidgets('ListDetail: the Members card over a skeleton while the '
        'members load, then the rows', (tester) async {
      final rig = ListsTabletRig();
      rig.server.holdMembers = Completer<void>();
      await _openList(tester, rig, settle: false);
      expect(inContextPane(find.text(kListMembersPaneTitle)), findsOneWidget);
      expect(
        inContextPane(find.byType(ListMembersPanePlaceholder)),
        findsOneWidget,
      );
      expect(inContextPane(find.text('Mia')), findsNothing);

      rig.server.holdMembers!.complete();
      await tester.pumpAndSettle();
      expect(
        inContextPane(find.byType(ListMembersPanePlaceholder)),
        findsNothing,
      );
      expect(inContextPane(find.text('Mia')), findsOneWidget);
    });

    testWidgets('ManagePinned: the Preview card', (tester) async {
      final rig = ListsTabletRig()..server.pinRigList();
      await _openPinned(tester, rig, settle: false);
      expect(inContextPane(find.text(kHomeTabsPreviewTitle)), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets("UserLists: the owner card's skeleton while the Lists load, "
        'then the card', (tester) async {
      final rig = ListsTabletRig();
      rig.server.holdUserLists = Completer<void>();
      await _openUserLists(tester, rig, settle: false);
      expect(
        inContextPane(find.byType(ListsOwnerCardPlaceholder)),
        findsOneWidget,
      );
      rig.server.holdUserLists!.complete();
      await tester.pumpAndSettle();
      expect(
        inContextPane(find.byType(ListsOwnerCardPlaceholder)),
        findsNothing,
      );
      expect(inContextPane(find.byType(ListsOwnerCard)), findsOneWidget);
    });

    final placeholders = <String, (ContextSectionKind, Type)>{
      _listPath: (ContextSectionKind.listMembers, ListMembersPanePlaceholder),
      AppRouter.pinnedPath: (
        ContextSectionKind.homeTabsPreview,
        HomeTabsPreviewPlaceholder,
      ),
      _userListsPath: (
        ContextSectionKind.listsOwner,
        ListsOwnerCardPlaceholder,
      ),
    };
    for (final MapEntry(key: path, value: (kind, type))
        in placeholders.entries) {
      testWidgets("$path: the slot's placeholder is a $type", (tester) async {
        final rig = ListsTabletRig();
        await rig.pump(tester, location: path);
        final slot = tester.widget<ContextPaneSlot>(
          inContextPane(find.byType(ContextPaneSlot)),
        );
        expect(slot.kind, kind);
        expect(slot.placeholder.runtimeType, type);
      });
    }
  });

  group('state across resizes', () {
    testWidgets('ListDetail: the same page, the preview asked once (only '
        'once band B shows it)', (tester) async {
      final rig = ListsTabletRig();
      await _openList(tester, rig, width: 744);
      final state = tester.state(find.byType(ListDetailScreen));
      expect(rig.server.count('ListListMembers'), 0, reason: 'band A');

      for (final w in <double>[1024, 839, 840, 1199, 1200, 599, 600, 1024]) {
        await rig.resize(tester, w);
        expect(tester.takeException(), isNull, reason: '$w');
        expect(
          tester.state(find.byType(ListDetailScreen)),
          same(state),
          reason: '$w',
        );
        expect(
          inContextPane(find.text('Mia')),
          _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
        expect(inListsPage(find.text('3 members')), findsOneWidget);
        expect(rig.server.count('ListListMembers'), 1, reason: '$w');
      }
    });

    testWidgets('ManagePinned: the same page; the preview moves between the '
        'top of the page (A) and the pane (B)', (tester) async {
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
        final preview = find.byType(HomeTabsPreviewCard);
        expect(
          inContextPane(preview),
          _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
        expect(
          inListsPage(preview),
          _bandA(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
      }
      expect(rig.server.count('ListUserLists'), 1);
    });

    testWidgets('UserLists: the same page; the owner card moves between the '
        'page (A) and the pane (B)', (tester) async {
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
        final card = find.byType(ListsOwnerCard);
        expect(
          inContextPane(card),
          _bandB(w) ? findsOneWidget : findsNothing,
          reason: '$w',
        );
        expect(
          inListsPage(card),
          _bandA(w) ? findsOneWidget : findsNothing,
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
    }

    testWidgets('the preview is a picture: a tap on a tab does nothing and '
        'no tab takes focus', (tester) async {
      final rig = ListsTabletRig()..server.pinRigList();
      await _openPinned(tester, rig);
      final preview = inContextPane(find.byType(HomeTabsPreviewCard));
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
  });

  group('the members preview', () {
    testWidgets('owner: "Manage members"; a Remove on Members updates the '
        'preview on the way back', (tester) async {
      final rig = ListsTabletRig()..server.viewerOwnsList = true;
      await _openList(tester, rig);
      expect(inContextPane(find.text(kManageMembersLabel)), findsOneWidget);
      expect(find.text(kSeeAllMembersLabel), findsNothing);

      await tester.tap(inContextPane(find.text(kManageMembersLabel)));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Remove @mia from this List'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(rig.server.count('RemoveListMember'), 1);

      rig.router.pop();
      await tester.pumpAndSettle();
      expect(inListsPage(find.text('2 members')), findsOneWidget);
      expect(inContextPane(find.text('Mia')), findsNothing);
      expect(inContextPane(find.text('Noah')), findsOneWidget);
      // The preview, the members page, then the preview again.
      expect(rig.server.count('ListListMembers'), 3);
    });

    testWidgets('at most five rows, then the link', (tester) async {
      final rig = ListsTabletRig();
      rig.server.members = [
        for (var i = 1; i <= 8; i++) ('p$i', 'person$i', 'Person $i'),
      ];
      await _openList(tester, rig);
      for (var i = 1; i <= 8; i++) {
        expect(
          inContextPane(find.text('Person $i')),
          i <= kListMembersPreviewLimit ? findsOneWidget : findsNothing,
        );
      }
      expect(inContextPane(find.text(kSeeAllMembersLabel)), findsOneWidget);
    });

    testWidgets("an empty List: the members page's empty line, no link", (
      tester,
    ) async {
      final rig = ListsTabletRig()..server.members = [];
      await _openList(tester, rig);
      expect(
        inContextPane(find.text('No one is on this List yet')),
        findsOneWidget,
      );
      expect(inContextPane(find.byType(OutlinedButton)), findsNothing);
    });

    testWidgets('a failed preview offers a 48 dp Retry that asks again', (
      tester,
    ) async {
      final rig = ListsTabletRig()
        ..server.membersError = connect.Code.unavailable;
      await _openList(tester, rig);
      expect(
        inContextPane(find.text("Couldn't load members.")),
        findsOneWidget,
      );
      final retry = inContextPane(find.widgetWithText(TextButton, 'Retry'));
      expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
      // The link to the page stays.
      expect(inContextPane(find.text(kSeeAllMembersLabel)), findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(inContextPane(find.text('Mia')), findsOneWidget);
      expect(inContextPane(find.text("Couldn't load members.")), findsNothing);
      expect(rig.server.count('ListListMembers'), 2);
    });

    testWidgets("an unavailable List: no Members card over the page's "
        'unavailable state', (tester) async {
      final rig = ListsTabletRig()..server.listGone = true;
      await _openList(tester, rig);
      expect(find.text('This List is unavailable'), findsOneWidget);
      expect(find.text(kListMembersPaneTitle), findsNothing);
      expect(find.byType(ListMembersPanePlaceholder), findsNothing);
    });
  });

  group('the owner card', () {
    testWidgets('no card over "No public Lists" (A and B)', (tester) async {
      final rig = ListsTabletRig()..server.ownerHasLists = false;
      await _openUserLists(tester, rig);
      expect(find.text('No public Lists'), findsOneWidget);
      expect(find.byType(ListsOwnerCard), findsNothing);
      expect(find.byType(ListsOwnerCardPlaceholder), findsNothing);
      await rig.resize(tester, 744);
      expect(find.byType(ListsOwnerCard), findsNothing);
    });

    testWidgets("it opens the owner's profile and is one 48 dp button", (
      tester,
    ) async {
      final rig = ListsTabletRig();
      await _openUserLists(tester, rig);
      final card = inContextPane(find.byType(ListsOwnerCard));
      expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
      expect(
        find.bySemanticsLabel('Lists by Olivia Owner, @olivia. View profile'),
        findsOneWidget,
      );
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(rig.uri.path, AppRouter.profileByIdPath(kRigOwnerId));
    });
  });

  group('focus order (plan section 2.1): rail, page, then the pane', () {
    for (final direction in TextDirection.values) {
      testWidgets('${direction.name}: ListDetail at 1024', (tester) async {
        final rig = ListsTabletRig();
        await _openList(tester, rig, textDirection: direction);
        final rail = tester.getRect(find.byKey(const ValueKey('tablet-rail')));
        final page = tester.getRect(findListsPage());
        final pane = tester.getRect(findContextPane());
        String regionOf(Rect r) {
          final c = r.center;
          if (rail.contains(c)) return 'rail';
          if (page.contains(c)) return 'page';
          if (pane.contains(c)) return 'pane';
          return 'other';
        }

        // Start on the page's first stop (its Back button).
        Focus.of(
          tester.element(
            find.descendant(
              of: inListsPage(find.byTooltip('Back')),
              matching: find.byType(Icon),
            ),
          ),
        ).requestFocus();
        await tester.pump();
        final regions = <String>['page'];
        for (var i = 0; i < 40 && regions.length < 3; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final region = regionOf(FocusManager.instance.primaryFocus!.rect);
          if (region != regions.last) regions.add(region);
        }
        // After the page's stops come the pane's, then the walk wraps to
        // the rail.
        expect(regions, ['page', 'pane', 'rail']);
      });
    }
  });

  group('text scale 2.0 in the 320 dp pane (840 x 1194)', () {
    Future<void> expectFits(
      WidgetTester tester,
      Finder target, {
      bool tap48 = true,
    }) async {
      expect(tester.takeException(), isNull);
      expect(tester.getSize(findContextPane()).width, 320);
      await tester.scrollUntilVisible(
        target,
        100,
        scrollable: find
            .descendant(
              of: findContextPane(),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(target);
      final paneRect = tester.getRect(findContextPane());
      expect(rect.left, greaterThanOrEqualTo(paneRect.left));
      expect(rect.right, lessThanOrEqualTo(paneRect.right));
      if (tap48) {
        expect(rect.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      }
    }

    for (final brightness in Brightness.values) {
      for (final owner in [false, true]) {
        testWidgets('ListDetail (${owner ? 'owner' : 'member'}), '
            '${brightness.name}: the rows and the link fit', (tester) async {
          final rig = ListsTabletRig()..server.viewerOwnsList = owner;
          await _openList(
            tester,
            rig,
            width: 840,
            height: 1194,
            textScale: 2,
            brightness: brightness,
          );
          for (final (_, _, name) in kRigMembers) {
            await expectFits(
              tester,
              inContextPane(find.text(name)),
              tap48: false,
            );
          }
          await expectFits(
            tester,
            inContextPane(
              find.widgetWithText(
                OutlinedButton,
                owner ? kManageMembersLabel : kSeeAllMembersLabel,
              ),
            ),
          );
        });
      }

      testWidgets('ManagePinned, ${brightness.name}: the preview fits', (
        tester,
      ) async {
        final rig = ListsTabletRig()..server.pinRigList();
        await _openPinned(
          tester,
          rig,
          width: 840,
          height: 1194,
          textScale: 2,
          brightness: brightness,
        );
        await expectFits(
          tester,
          inContextPane(find.byType(HomeTabsPreviewCard)),
          tap48: false,
        );
      });

      testWidgets('UserLists, ${brightness.name}: the owner card fits', (
        tester,
      ) async {
        final rig = ListsTabletRig();
        await _openUserLists(
          tester,
          rig,
          width: 840,
          height: 1194,
          textScale: 2,
          brightness: brightness,
        );
        await expectFits(tester, inContextPane(find.byType(ListsOwnerCard)));
      });
    }
  });

  testWidgets('band B in RTL: the pane on the left, the page beside the rail '
      'on the right', (tester) async {
    final rig = ListsTabletRig();
    await _openList(tester, rig, textDirection: TextDirection.rtl);
    expect(tester.takeException(), isNull);
    final pane = tester.getRect(findContextPane());
    final page = tester.getRect(findListsPage());
    final rail = tester.getRect(find.byKey(const ValueKey('tablet-rail')));
    expect(pane.left, 0);
    expect(page.left, pane.right + 1);
    expect(rail.right, 1024);
    expect(inContextPane(find.text('Mia')), findsOneWidget);
  });

  group('lists off (no redirect in the rig): the global set', () {
    final flags = {...kListsTabletFlags}..remove('lists');
    for (final (name, open)
        in <(String, Future<void> Function(WidgetTester, ListsTabletRig))>[
          ('ListDetail', (t, r) => _openList(t, r, flags: flags)),
          ('ManagePinned', (t, r) => _openPinned(t, r, flags: flags)),
          ('UserLists', (t, r) => _openUserLists(t, r, flags: flags)),
        ]) {
      testWidgets('$name at 1024', (tester) async {
        final rig = ListsTabletRig();
        await open(tester, rig);
        expect(_paneKinds(tester), _global);
        expect(find.byType(ListMembersPane), findsNothing);
        expect(inContextPane(find.byType(HomeTabsPreviewCard)), findsNothing);
        expect(inContextPane(find.byType(ListsOwnerCard)), findsNothing);
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
          expectTabletPanes(tester, findListsPage(), env.size.width);
          if (_bandB(env.size.width)) {
            expect(_paneKinds(tester).last, ContextSectionKind.links);
            final paneRect = tester.getRect(findContextPane());
            for (final kind in _paneKinds(tester)) {
              final section = tester.getRect(find.byKey(ValueKey(kind)).first);
              expect(section.left, greaterThanOrEqualTo(paneRect.left));
              expect(section.right, lessThanOrEqualTo(paneRect.right));
            }
          }
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

  testWidgets('band B: the Follow buttons of the preview rows are real 48 dp '
      'targets', (tester) async {
    final rig = ListsTabletRig();
    await _openList(tester, rig);
    final follows = inContextPane(find.widgetWithText(FilledButton, 'Follow'));
    expect(follows, findsNWidgets(kRigMembers.length));
    for (final button in follows.evaluate()) {
      final size = (button.renderObject! as RenderBox).size;
      expect(size.height, greaterThanOrEqualTo(AppSpacing.minTapTarget));
      expect(size.width, greaterThanOrEqualTo(AppSpacing.minTapTarget));
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
}
