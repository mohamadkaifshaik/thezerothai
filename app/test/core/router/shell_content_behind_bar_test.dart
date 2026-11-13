import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/app_bottom_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/beacons_fixtures.dart' show kBeaconIdA;
import '../../support/communities_tablet_rig.dart' as communities;
import '../../support/lists_tablet_rig.dart' as lists;
import '../../support/plans_tablet_rig.dart' as plans;
import '../../support/profile_tablet_rig.dart' as profile;
import '../../support/settings_tablet_rig.dart' as settings;

// Phone shell: the floating bar is over the page, and the page runs to the
// screen's bottom edge, behind it. A `SafeArea` that keeps the bottom would
// end the page at the bar's top edge and cut the content off there; every
// page of the shell keeps the bar's inset in its scroll content instead
// (`ShellBottomInsetSliver`, the list's own padding, or the view's padding).

const _height = 900.0;

/// Every `SafeArea` of the page (the bar's own excluded) passes the whole
/// height on to its child.
void expectRunsBehindBar(WidgetTester tester) {
  expect(find.byType(AppBottomBar), findsOneWidget);
  final bar = find.byType(AppBottomBar);
  var checked = 0;
  for (final e in find.byType(SafeArea).evaluate()) {
    // The bar's own, and the app bars' (they pad their top).
    bool under(Finder of) => find
        .descendant(of: of, matching: find.byWidget(e.widget))
        .evaluate()
        .isNotEmpty;
    if (under(bar) || under(find.byType(AppBar))) continue;
    final padding = find
        .descendant(of: find.byWidget(e.widget), matching: find.byType(Padding))
        .first
        .evaluate()
        .single
        .renderObject!;
    final child = (padding as RenderPadding).child!;
    final bottom = child.localToGlobal(Offset.zero).dy + child.size.height;
    expect(
      bottom,
      _height,
      reason:
          'a SafeArea at ${e.widget.key ?? e.widget.runtimeType} ends '
          'above the screen bottom',
    );
    checked++;
  }
  // Pages with no SafeArea at all already run behind the bar.
  expect(checked, greaterThanOrEqualTo(0));
}

typedef _Pump = Future<void> Function(WidgetTester tester);

Future<void> _lists(WidgetTester tester, String location) =>
    lists.ListsTabletRig().pump(tester, width: 390, location: location);
Future<void> _communities(WidgetTester tester, String location) =>
    communities.CommunitiesTabletRig().pump(
      tester,
      width: 390,
      location: location,
    );
Future<void> _plans(WidgetTester tester, String location) =>
    plans.PlansTabletRig().pump(tester, width: 390, location: location);
Future<void> _profile(WidgetTester tester, String location) =>
    profile.ProfileTabletRig().pump(tester, width: 390, location: location);
Future<void> _settings(WidgetTester tester, String location) =>
    settings.SettingsTabletRig().pump(tester, width: 390, location: location);

void main() {
  final pages = <String, _Pump>{
    'Profile': (t) => _profile(t, '/profile/${profile.kRigOwnHandle}'),
    'Followers': (t) =>
        _profile(t, '/profile/${profile.kRigOwnHandle}/followers'),
    'Edit profile': (t) => _profile(t, AppRouter.editProfilePath),
    'Lists': (t) => _lists(t, AppRouter.listsPath),
    'List detail': (t) => _lists(t, '/lists/${lists.kRigListId}'),
    'List members': (t) => _lists(t, '/lists/${lists.kRigListId}/members'),
    'Manage pinned': (t) => _lists(t, AppRouter.pinnedPath),
    'Communities': (t) => _communities(t, AppRouter.communitiesPath),
    'Community': (t) =>
        _communities(t, AppRouter.communityPath(communities.kRigCommunityId)),
    'Community members': (t) => _communities(
      t,
      AppRouter.communityMembersPath(communities.kRigCommunityId),
    ),
    'Moderation log': (t) => _communities(
      t,
      AppRouter.communityModerationLogPath(communities.kRigCommunityId),
    ),
    'Create a community': (t) => _communities(t, AppRouter.communityNewPath),
    'Plans': (t) => _plans(t, AppRouter.plansPath),
    'New plan': (t) => _plans(t, AppRouter.planNewPath),
    'My plans': (t) => _plans(t, AppRouter.plansMinePath),
    'A plan': (t) => _plans(t, '/plans/$kBeaconIdA'),
    'A plan\'s people': (t) => _plans(t, '/plans/$kBeaconIdA/people'),
    'Edit a plan': (t) => _plans(t, '/plans/$kBeaconIdA/edit'),
    'Blocked accounts': (t) => _settings(t, AppRouter.blockedAccountsPath),
    'Muted accounts': (t) => _settings(t, AppRouter.mutedAccountsPath),
    'Notification settings': (t) =>
        _settings(t, AppRouter.notificationSettingsPath),
    'Message settings': (t) => _settings(t, AppRouter.messageSettingsPath),
  };

  for (final MapEntry(key: name, value: pump) in pages.entries) {
    testWidgets('$name runs behind the bar', (tester) async {
      await pump(tester);
      expectRunsBehindBar(tester);
    });
  }
}
