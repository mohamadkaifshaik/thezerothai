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
    // CommunityMembers: members beside the global set (T8a; F36's "Search
    // members" waits).
    '/communities/c1/members': ContextFamily.global,
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
    // The communities pages (T8a): sections lent by the page, or static.
    AppRouter.communitiesPath: ContextFamily.communities,
    AppRouter.communityNewPath: ContextFamily.communityCreate,
    '/communities/c1': ContextFamily.community,
    '/communities/c1/moderation-log': ContextFamily.moderationLog,
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

  group('communities (T8a)', () {
    test('"new" is the create form, not a community id', () {
      expect(
        contextFamilyFor('/communities/new'),
        ContextFamily.communityCreate,
      );
      expect(
        contextFamilyFor('/communities/new/'),
        ContextFamily.communityCreate,
      );
      expect(contextFamilyFor('/communities/news'), ContextFamily.community);
    });

    test('a query or a trailing slash does not change the family', () {
      expect(contextFamilyFor('/communities/'), ContextFamily.communities);
      expect(contextFamilyFor('/communities/7?x=1'), ContextFamily.community);
      expect(
        contextFamilyFor('/communities/7/moderation-log/'),
        ContextFamily.moderationLog,
      );
      expect(
        contextFamilyFor('/communities/7/members?tab=1'),
        ContextFamily.global,
      );
    });

    // The communities pages are pushed (directory rows, Members, the log,
    // Create, a post's community label from any feed), so their pane
    // follows the shell navigator's top page, as Plans' list pane does (T5).
    const cases = <(String, String?), String>{
      // Pushed over Home, a feed or Explore: the community's own pane.
      ('/home', '/communities/77'): '/communities/77',
      ('/explore', '/communities/77/moderation-log'):
          '/communities/77/moderation-log',
      // Pushed over the directory, and further.
      ('/communities', '/communities/77'): '/communities/77',
      ('/communities', '/communities/new'): '/communities/new',
      ('/communities', '/communities/77/members'): '/communities/77/members',
      // Something else pushed over a communities page: that page's family,
      // never the communities page's lent sections.
      ('/communities', '/plans/mine'): '/plans/mine',
      ('/communities/77', '/profile/alice'): '/profile/alice',
      // The profile pages are pushed too (T8c): a profile over Explore, Home
      // or a post gets its own pane (this row read `/explore` before T8c).
      ('/explore', '/profile/alice'): '/profile/alice',
      ('/home', '/u/u1'): '/u/u1',
      ('/post/p1', '/profile/alice'): '/profile/alice',
      // Over a plan (no pane of its own, T5): the profile's pane.
      ('/plans/b1', '/u/u1'): '/u/u1',
      // Followers, Following and Edit profile over a profile: their own
      // family (Who to follow; no pane), never the profile's media strip.
      ('/profile/alice', '/profile/alice/followers'):
          '/profile/alice/followers',
      ('/u/u1', '/profile/alice/following'): '/profile/alice/following',
      ('/profile/alice', AppRouter.editProfilePath): AppRouter.editProfilePath,
      // A Settings page pushed over anything decides its own (no) pane: the
      // own profile pushed over Home, then Edit profile from it.
      ('/home', AppRouter.editProfilePath): AppRouter.editProfilePath,
      ('/explore', AppRouter.changeHandlePath): AppRouter.changeHandlePath,
      // A plan's detail over Home keeps T5's base-route rule.
      ('/home', '/plans/b1'): '/home',
      // A person's Lists over their profile, and a post over the own
      // profile: their own family (the global set).
      ('/profile/alice', '/u/u1/lists'): '/u/u1/lists',
      ('/profile/alice', '/post/p1'): '/post/p1',
      // Neither side is a communities or profile page: T3's base-route rule,
      // unchanged.
      ('/explore', '/post/p1'): '/explore',
      ('/home', '/post/p1'): '/home',
      // Not a prefix match: `/profiles` and `/user` are not profile pages.
      ('/home', '/profiles'): '/home',
      ('/home', '/user/u1'): '/home',
      // No top page known (no router): the base route.
      ('/communities', null): '/communities',
      ('/home', null): '/home',
      // Not a prefix match: `/communitiesx` is not a communities page.
      ('/home', '/communitiesx'): '/home',
    };
    for (final MapEntry(key: (base, top), value: expected) in cases.entries) {
      test('pane location: base $base, top $top -> $expected', () {
        expect(contextPaneLocationFor(base, top), expected);
      });
    }
  });
}
