import 'package:go_router/go_router.dart';

import '../telemetry/usage_reporter.dart';

/// The screen name for anything not in [kScreenNames] (ADR-0032 F4).
const kOtherScreen = 'other';

/// Route template -> screen name (ADR-0032 F4, TEL-6). The key is the
/// template (`/post/:id`), never a location, so no id, handle or query can
/// reach Analytics. A new route is `other` until it is added here; the table
/// test (`screen_names_test.dart`) reads every `AppRouter` route.
const Map<String, String> kScreenNames = {
  '/': 'splash',
  '/sign-in': 'sign_in',
  '/sign-up': 'sign_up',
  '/onboarding': 'onboarding',
  '/onboarding/delete-account': 'delete_account',
  '/account-deleted': 'account_deleted',
  '/home': 'home',
  '/home/pinned': 'pinned',
  '/follow-requests': 'follow_requests',
  '/explore': 'explore',
  '/search': 'search',
  '/notifications': 'notifications',
  '/compose': 'compose',
  '/scheduled': 'scheduled_posts',
  '/drafts': 'drafts',
  '/bookmarks': 'bookmarks',
  '/lists': 'lists',
  '/lists/:id': 'list_detail',
  '/lists/:id/members': 'list_members',
  '/messages': 'messages',
  '/messages/requests': 'message_requests',
  '/messages/new': 'message_new',
  '/messages/new/draft': 'message_new',
  '/messages/:id': 'message_thread',
  '/post/:id': 'post_detail',
  '/u/:userId': 'profile',
  '/u/:userId/lists': 'profile_lists',
  '/profile/:handle': 'profile',
  '/profile/:handle/followers': 'followers',
  '/profile/:handle/following': 'following',
  '/settings': 'settings',
  '/settings/profile': 'edit_profile',
  '/settings/handle': 'change_handle',
  '/settings/blocked': 'blocked_accounts',
  '/settings/muted': 'muted_accounts',
  '/settings/export': 'export_data',
  '/settings/delete-account': 'delete_account',
  '/creator-studio': 'creator_studio',
  '/advertise': 'advertise',
  '/calls': 'calls',
};

/// The screen name for a route template (a route path as declared).
String screenNameForTemplate(String? template) =>
    kScreenNames[template] ?? kOtherScreen;

/// The screen name for [state], from `state.fullPath` only: never `uri` or
/// `matchedLocation`, which hold the id, the handle and the query.
String screenNameFor(GoRouterState state) =>
    screenNameForTemplate(state.fullPath);

/// Reports one `screen_view` each time the page on top changes (TEL-6).
///
/// It reads the template of the top route (`GoRoute.path`; every route is
/// declared with an absolute path, so that is the full template, and it also
/// covers a page opened with `push`, which `fullPath` skips) and compares page
/// keys internally to skip repeats of the same page. Only the table's name
/// leaves this class.
class ScreenViewTracker {
  ScreenViewTracker(this._router, this._usage) {
    _router.routerDelegate.addListener(_onChange);
  }

  final GoRouter _router;
  final UsageReporter _usage;
  Object? _lastPage;

  void _onChange() {
    final top = _router.routerDelegate.currentConfiguration.lastOrNull;
    if (top == null || top.pageKey == _lastPage) return;
    _lastPage = top.pageKey;
    _usage.screen(screenNameForTemplate(top.route.path));
  }

  void dispose() => _router.routerDelegate.removeListener(_onChange);
}
