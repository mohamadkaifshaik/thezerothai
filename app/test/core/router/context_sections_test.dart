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
    AppRouter.bookmarksPath: ContextFamily.global,
    // Lists and ListMembers: the global set (T8b; F10 keeps "Discover new
    // Lists" out, F31's suggestions wait).
    AppRouter.listsPath: ContextFamily.global,
    '/lists/l1/members': ContextFamily.global,
    AppRouter.plansMinePath: ContextFamily.global,
    '/post/p1': ContextFamily.global,
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
    // The Lists pages (T8b): sections lent by the page.
    '/lists/l1': ContextFamily.listDetail,
    AppRouter.pinnedPath: ContextFamily.managePinned,
    '/u/u1/lists': ContextFamily.userLists,
    // The plan forms (T8d): the preview and the tips, lent by the page.
    AppRouter.planNewPath: ContextFamily.planCreate,
    '/plans/b1/edit': ContextFamily.planEdit,
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
    expect(contextFamilyFor('/plans/new'), ContextFamily.planCreate);
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
        ContextFamily.communityMembers,
      );
    });

    // R10 (F36): CommunityMembers has its own family; [contextSectionsFor]
    // gives it "Search members" with `community_member_search` on and the
    // global set without it (T8a ruling 11).
    test('/communities/c1/members -> communityMembers', () {
      expect(
        contextFamilyFor('/communities/c1/members'),
        ContextFamily.communityMembers,
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
      // Neither side is a communities page: T3's base-route rule, unchanged.
      ('/explore', '/profile/alice'): '/explore',
      ('/home', '/post/p1'): '/home',
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

  group('plan forms (T8d)', () {
    test('"new" is the create form; "edit" under a plan id the edit form', () {
      expect(contextFamilyFor('/plans/new/'), ContextFamily.planCreate);
      expect(contextFamilyFor('/plans/new?x=1'), ContextFamily.planCreate);
      expect(contextFamilyFor('/plans/7/edit/'), ContextFamily.planEdit);
      expect(contextFamilyFor('/plans/7/edits'), ContextFamily.global);
      expect(contextFamilyFor('/plans/new/edit'), ContextFamily.planEdit);
    });

    // The forms are pushed (the list header, the placeholder's New plan,
    // My plans, a plan's Edit), so when one is the shell navigator's top
    // page it decides; everything else keeps its rule.
    const cases = <(String, String?), String>{
      ('/plans', '/plans/new'): '/plans/new',
      ('/plans/7', '/plans/7/edit'): '/plans/7/edit',
      ('/plans/mine', '/plans/new'): '/plans/new',
      ('/home', '/plans/new'): '/plans/new',
      // A plan form as the base, with no top known: the base.
      ('/plans/new', null): '/plans/new',
      // Other Plans pages pushed over the list keep T5's base-route rule.
      ('/plans', '/plans/mine'): '/plans',
      ('/plans/7', '/plans/7/people'): '/plans/7',
    };
    for (final MapEntry(key: (base, top), value: expected) in cases.entries) {
      test('pane location: base $base, top $top -> $expected', () {
        expect(contextPaneLocationFor(base, top), expected);
      });
    }
  });

  group('lists (T8b)', () {
    test('a query or a trailing slash does not change the family', () {
      expect(contextFamilyFor('/lists/'), ContextFamily.global);
      expect(contextFamilyFor('/lists/7?x=1'), ContextFamily.listDetail);
      expect(contextFamilyFor('/lists/7/'), ContextFamily.listDetail);
      expect(contextFamilyFor('/lists/7/members/'), ContextFamily.global);
      expect(contextFamilyFor('/home/pinned/'), ContextFamily.managePinned);
      expect(contextFamilyFor('/u/u1/lists?x=1'), ContextFamily.userLists);
    });

    test('near misses keep their own family', () {
      expect(contextFamilyFor('/home/pinnedx'), ContextFamily.global);
      expect(contextFamilyFor('/u/u1/listsx'), ContextFamily.global);
      expect(contextFamilyFor('/u/u1'), ContextFamily.profile);
    });

    // The Lists pages are pushed (a List from Lists, Manage pinned or a
    // person's Lists; Members from a List; Manage pinned from Home's "+"; a
    // person's Lists from their profile), so their pane follows the top page.
    const cases = <(String, String?), String>{
      ('/lists', '/lists/77'): '/lists/77',
      ('/lists', '/lists/77/members'): '/lists/77/members',
      ('/home', '/home/pinned'): '/home/pinned',
      ('/home', '/lists/77'): '/lists/77',
      ('/profile/olivia', '/u/o1/lists'): '/u/o1/lists',
      ('/u/o1', '/u/o1/lists'): '/u/o1/lists',
      ('/profile/olivia', '/lists/77'): '/lists/77',
      // Something else pushed over a Lists page: that page's family.
      ('/lists', '/profile/olivia'): '/profile/olivia',
      ('/home/pinned', '/plans/mine'): '/plans/mine',
      // No top page known: the base route.
      ('/lists', null): '/lists',
      // Not a Lists page: T3's base-route rule, unchanged.
      ('/home', '/home'): '/home',
      ('/home', '/listsx'): '/home',
      ('/home', '/u/o1'): '/home',
    };
    for (final MapEntry(key: (base, top), value: expected) in cases.entries) {
      test('pane location: base $base, top $top -> $expected', () {
        expect(contextPaneLocationFor(base, top), expected);
      });
    }
  });
}
