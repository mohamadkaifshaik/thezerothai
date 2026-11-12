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
    // The tablet PostDetail and PostThread designs: no pane.
    '/post/p1': ContextFamily.none,
    '/post/p1/photo/0': ContextFamily.none,
    // P with the family's own list.
    AppRouter.explorePath: ContextFamily.explore,
    AppRouter.notificationsPath: ContextFamily.notifications,
    AppRouter.searchRoute: ContextFamily.search,
    AppRouter.followRequestsPath: ContextFamily.people,
    '/profile/alice/followers': ContextFamily.people,
    '/profile/alice/following': ContextFamily.people,
    '/profile/alice': ContextFamily.profile,
    '/u/u1': ContextFamily.profile,
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

  group('pane location', () {
    const cases = <(String, String?), String>{
      // The communities pages have no pane of their own.
      ('/communities', '/plans/mine'): '/communities',
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
      // A person's Lists over their profile (T8b's owner card), and a post
      // over the own profile (the global set): their own family.
      ('/profile/alice', '/u/u1/lists'): '/u/u1/lists',
      ('/profile/alice', '/post/p1'): '/post/p1',
      // A post pushed from a feed decides its own (no) pane.
      ('/explore', '/post/p1'): '/post/p1',
      ('/home', '/post/p1'): '/post/p1',
      // A page pushed over a post: its own family.
      ('/post/p1', '/plans/mine'): '/plans/mine',
      // Not a prefix match: `/profiles` and `/user` are not profile pages.
      ('/home', '/profiles'): '/home',
      ('/home', '/user/u1'): '/home',
      // No top page known (no router): the base route.
      ('/communities', null): '/communities',
      ('/home', null): '/home',
      // The communities pages have no pane of their own: the base route.
      ('/home', '/communities/77'): '/home',
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
      // A profile over Home follows T8c's profile rule (the top page
      // decides; this row read `/home` in T8b).
      ('/home', '/u/o1'): '/u/o1',
    };
    for (final MapEntry(key: (base, top), value: expected) in cases.entries) {
      test('pane location: base $base, top $top -> $expected', () {
        expect(contextPaneLocationFor(base, top), expected);
      });
    }
  });
}
