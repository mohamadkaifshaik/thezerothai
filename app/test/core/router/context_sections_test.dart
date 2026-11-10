import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/context_sections.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tablet plan T3: which context pane every shell location gets in band B
/// (section 4.1, codes P / F / LD). A pure function of the matched location,
/// never of data, so the primary pane's width cannot jump when a section
/// loads.
void main() {
  // Every ShellRoute child of `app_router.dart`, with a sample id.
  const cases = <String, ContextFamily>{
    // P with the global set (search pill, profile card, What's happening,
    // Who to follow, footer).
    '/home': ContextFamily.global,
    AppRouter.pinnedPath: ContextFamily.global,
    AppRouter.bookmarksPath: ContextFamily.global,
    AppRouter.listsPath: ContextFamily.global,
    '/lists/l1': ContextFamily.global,
    '/lists/l1/members': ContextFamily.global,
    AppRouter.communitiesPath: ContextFamily.global,
    AppRouter.communityNewPath: ContextFamily.global,
    '/communities/c1': ContextFamily.global,
    '/communities/c1/members': ContextFamily.global,
    '/communities/c1/moderation-log': ContextFamily.global,
    AppRouter.planNewPath: ContextFamily.global,
    AppRouter.plansMinePath: ContextFamily.global,
    '/plans/b1/edit': ContextFamily.global,
    '/post/p1': ContextFamily.global,
    '/u/u1/lists': ContextFamily.global,
    // P with the family's own list.
    AppRouter.explorePath: ContextFamily.explore,
    AppRouter.notificationsPath: ContextFamily.notifications,
    AppRouter.searchRoute: ContextFamily.search,
    AppRouter.followRequestsPath: ContextFamily.people,
    '/profile/alice/followers': ContextFamily.people,
    '/profile/alice/following': ContextFamily.people,
    '/profile/alice': ContextFamily.profile,
    '/u/u1': ContextFamily.profile,
    // No pane: list-detail families (T4-T6) and the F rows of section 4.1.
    AppRouter.settingsPath: ContextFamily.none,
    AppRouter.blockedAccountsPath: ContextFamily.none,
    AppRouter.mutedAccountsPath: ContextFamily.none,
    AppRouter.exportDataPath: ContextFamily.none,
    AppRouter.editProfilePath: ContextFamily.none,
    AppRouter.changeHandlePath: ContextFamily.none,
    AppRouter.deleteAccountPath: ContextFamily.none,
    AppRouter.messagesPath: ContextFamily.none,
    AppRouter.messageRequestsPath: ContextFamily.none,
    AppRouter.plansPath: ContextFamily.none,
    '/plans/b1': ContextFamily.none,
    '/plans/b1/people': ContextFamily.none,
    AppRouter.creatorStudioPath: ContextFamily.none,
    AppRouter.advertisePath: ContextFamily.none,
    AppRouter.callsPath: ContextFamily.none,
  };

  for (final MapEntry(key: location, value: family) in cases.entries) {
    test('$location -> ${family.name}', () {
      expect(contextFamilyFor(location), family);
    });
  }

  test('a query or a trailing slash does not change the family', () {
    expect(contextFamilyFor('/search?q=go'), ContextFamily.search);
    expect(contextFamilyFor('/explore/'), ContextFamily.explore);
    expect(contextFamilyFor('/plans/b1/'), ContextFamily.none);
  });

  test('"new" and "mine" are pages of their own, not a plan id', () {
    expect(contextFamilyFor('/plans/new'), ContextFamily.global);
    expect(contextFamilyFor('/plans/mine'), ContextFamily.global);
    expect(contextFamilyFor('/plans/news'), ContextFamily.none);
  });

  test('an unknown shell path gets the global set (the plan default)', () {
    expect(contextFamilyFor('/'), ContextFamily.global);
    expect(contextFamilyFor('/something-new'), ContextFamily.global);
  });
}
