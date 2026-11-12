import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/widgets/responsive_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/communities_tablet_rig.dart';
import '../../support/lists_tablet_rig.dart';
import '../../support/plans_tablet_rig.dart';
import '../../support/profile_tablet_rig.dart';

// The phone's floating button follows the page (final polish 6a): Plans
// starts a plan, Lists creates a List, Communities creates a community, a
// community posts there; a profile, a community's members and the create
// form have none. Home's New post and Messages' New message are covered by
// main_shell_layout_test and conversations_screen_test. Each page runs
// through the real MainShell in its real ShellRoute, at 390 dp.

const _phone = 390.0;

String? _fabTooltip(WidgetTester tester) {
  final fab = find.descendant(
    of: find.byType(ResponsiveScaffold),
    matching: find.byType(FloatingActionButton),
  );
  if (fab.evaluate().isEmpty) return null;
  return tester.widget<FloatingActionButton>(fab.first).tooltip;
}

void main() {
  testWidgets('Plans: New plan, which opens the form', (tester) async {
    final rig = PlansTabletRig();
    await rig.pump(tester, width: _phone);

    expect(_fabTooltip(tester), 'New plan');
    // The header leaves its own New plan out on a phone.
    expect(find.byTooltip('New plan'), findsOneWidget);

    await tester.tap(find.byTooltip('New plan'));
    await tester.pumpAndSettle();
    expect(find.text('New plan stub'), findsOneWidget);
  });

  testWidgets('Lists: Create a new List', (tester) async {
    final rig = ListsTabletRig();
    await rig.pump(tester, width: _phone);

    expect(_fabTooltip(tester), 'Create a new List');
    expect(find.byTooltip('Create a new List'), findsOneWidget);
  });

  testWidgets('Communities: Create a community', (tester) async {
    final rig = CommunitiesTabletRig();
    await rig.pump(tester, width: _phone);

    expect(_fabTooltip(tester), 'Create a community');
    expect(find.byTooltip('Create a community'), findsOneWidget);
  });

  testWidgets('a community: Post in that community', (tester) async {
    final rig = CommunitiesTabletRig();
    await rig.pump(
      tester,
      location: AppRouter.communityPath(kRigCommunityId),
      width: _phone,
    );

    expect(_fabTooltip(tester), startsWith('Post in '));
  });

  for (final (name, location) in [
    ('members', AppRouter.communityMembersPath(kRigCommunityId)),
    ('create', AppRouter.communityNewPath),
  ]) {
    testWidgets('a community sub-page ($name): none', (tester) async {
      final rig = CommunitiesTabletRig();
      await rig.pump(tester, location: location, width: _phone);

      expect(_fabTooltip(tester), isNull);
    });
  }

  testWidgets('a profile: none', (tester) async {
    final rig = ProfileTabletRig();
    await rig.pump(tester, width: _phone);

    expect(_fabTooltip(tester), isNull);
  });

  testWidgets('from 600 dp there is no floating button (the rail posts)', (
    tester,
  ) async {
    final rig = PlansTabletRig();
    await rig.pump(tester, width: 1024);

    expect(_fabTooltip(tester), isNull);
  });
}
