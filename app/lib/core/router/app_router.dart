import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/account/domain/account_feature_flag.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_state.dart';
import '../../features/communities/domain/communities_feature_flag.dart';
import '../../features/beacons/domain/beacons_feature_flag.dart';
import '../../features/lists/domain/lists_feature_flag.dart';
import '../../features/graph/domain/follow_requests_entry.dart';
import '../../features/graph/domain/graph_feature_flag.dart';
import '../../features/messages/domain/conversation_id.dart'
    show kConversationIdPattern;
import '../../features/messages/domain/messaging_feature_flag.dart';
import '../../features/messages/domain/messaging_feature_gate.dart';
import '../../features/search/domain/search_feature_flags.dart';
import '../../features/media/domain/media_feature_flag.dart';
import '../../features/notifications/domain/notification_prefs.dart';
import '../../features/notifications/domain/notifications_feature_flag.dart';
import '../../features/location/domain/location_feature_flag.dart';
import '../feature_flags/ui_shell_feature_flag.dart';
import 'routes/location_routes.dart';
import '../../features/onboarding/domain/handle_rules.dart' show kHandlePattern;
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/onboarding/presentation/bloc/onboarding_state.dart';
import '../../features/posts/domain/composer_draft.dart' show kFeatureDrafts;
import '../../features/posts/domain/posts_feature_flag.dart';
import '../../features/profile/domain/profile_edit_feature_flag.dart';
import 'shell_entries.dart';
import '../feature_flags/shells_feature_flag.dart';
import '../../features/settings/data/own_privacy_store.dart';
import '../../features/settings/domain/message_privacy.dart';
import 'go_router_refresh_stream.dart';
import 'routes/article_routes.dart';
import 'routes/auth_routes.dart';
import 'routes/compose_routes.dart';
import 'routes/messaging_routes.dart';
import 'routes/premium_route.dart';
import 'routes/shell_routes.dart';

/// Builds the app's `go_router`. Redirects branch purely on cached
/// [AuthBloc]/[OnboardingBloc] state — never on a fresh network call — so
/// navigation is instant and never burns an extra `GetMe` (cost-first
/// directive: the client is our cheapest cache).
class AppRouter {
  AppRouter({
    required AuthBloc authBloc,
    required OnboardingBloc onboardingBloc,
    MessagingFeatureGate? messagingGate,
    OwnPrivacyStore? ownPrivacy,
  }) : _authBloc = authBloc,
       _onboardingBloc = onboardingBloc,
       _messagingGate = messagingGate,
       _ownPrivacy = ownPrivacy {
    // Pushed post overlays must be addressable on web and survive reload.
    GoRouter.optionURLReflectsImperativeAPIs = true;
  }

  final AuthBloc _authBloc;
  final OnboardingBloc _onboardingBloc;

  /// The caller's read receipts and DM policy as the server answered (the
  /// Message settings redirect's undo rule); null in tests.
  final OwnPrivacyStore? _ownPrivacy;

  /// Decides the read-only Messages routes and re-runs the redirects
  /// when the probe answers or messaging turns out to be globally off. Null
  /// (a test) means the flag alone decides.
  final MessagingFeatureGate? _messagingGate;

  /// Where a signed-out visitor lands: Google, Apple, or on to email.
  static const welcomePath = '/welcome';
  static const signInPath = '/sign-in';
  static const signUpPath = '/sign-up';
  static const onboardingPath = '/onboarding';

  /// The optional "Add a profile photo" step right after this session's
  /// CreateProfile (`media` on); see [OnboardingState.photoStepPending].
  static const onboardingPhotoPath = '/onboarding/photo';

  /// Full-screen recoverable error for a session whose `GetMe` failed with
  /// nothing usable to show (`OnboardingStatus.error`). Outside the shell, so
  /// no navigation chrome renders with an empty flag set.
  static const sessionErrorPath = '/session-error';
  static const homePath = '/home';
  static const composePath = '/compose';
  static const articlesPath = '/compose/articles';
  static String articlePath(String id) =>
      '/articles/${Uri.encodeComponent(id)}';
  static String articleEditPath(String id) =>
      '$articlesPath/edit/${Uri.encodeComponent(id)}';
  static const settingsPath = '/settings';
  // The Notifications tab, behind the `notifications` flag.
  static const notificationsPath = '/notifications';
  // Explore, a ShellRoute child (a root destination). Needs `search`
  // and `ui_shell`; redirects Home without them.
  static const explorePath = '/explore';
  // Explore's "See all" pages (ShellRoute children): the whole Trending list
  // (`search` + `trends`) and the Media grid (`search` + `media` + `trends`).
  static const exploreTrendingPath = '/explore/trending';
  static const exploreMediaPath = '/explore/media';
  // The inbox and its Requests folder, behind the `messaging` flag
  // (both redirect Home without it). ShellRoute children.:
  // `/messages/:id` is one conversation, full-screen outside the shell (like
  // `/compose`) and declared AFTER the ShellRoute, so `/messages/requests`
  // match first.: `/messages/new` (the people picker, a dialog on the
  // root navigator) is declared BEFORE `:id`, so "new" is never read as a
  // conversation id; `/messages/new/draft` is the first-message thread with
  // someone the cache has no conversation with (it needs the person as the
  // route `extra`, so a reload goes back to the picker). Any `:id` that is not
  // 32 lower-case hex shows "This conversation isn't available".
  static const messagesPath = '/messages';
  static const messageRequestsPath = '/messages/requests';
  static const messageNewPath = '/messages/new';
  static const messageDraftPath = '/messages/new/draft';
  static String messagePath(String conversationId) =>
      '/messages/$conversationId';
  // The Settings routes land later; the constants live here so
  // ProfileHeader and SettingsScreen share one source of truth.
  static const blockedAccountsPath = '/settings/blocked';
  static const mutedAccountsPath = '/settings/muted';
  static const deleteAccountPath = '/settings/delete-account';
  // Delete account for callers without a profile or with an unverified
  // email (L-5): reachable while the profile-required redirect is active.
  static const onboardingDeletePath = '/onboarding/delete-account';
  // Final page after DeleteAccount: reachable signed out.
  static const accountDeletedPath = '/account-deleted';
  static const exportDataPath = '/settings/export';
  // Edit profile and Change handle, behind the `profile_snapshot` flag.
  static const editProfilePath = '/settings/profile';
  static const changeHandlePath = '/settings/handle';

  /// Push preferences (F6); Settings unless `notifications` and
  /// `notification_prefs` are on for the caller.
  static const notificationSettingsPath = '/settings/notifications';

  /// Who can message you and read receipts (F9, F3). Settings when both
  /// flags are off for the caller, unless one of the two is set (the undo
  /// rule: it can always be turned back).
  static const messageSettingsPath = '/settings/messages';
  static const dataUsagePath = '/settings/data-usage';

  /// Settings > Location (the chosen area). Reachable in every flag mode so a
  /// stored area can always be cleared; its consent leaf and the picker need
  /// `location`.
  static const locationSettingsPath = '/settings/location';
  static const locationConsentPath = '/settings/location/consent';

  /// The area picker (root, full screen; pops an `AreaRef`). Needs `location`.
  static const areaPickerPath = '/area-picker';

  /// Explore settings (F8): the "Your area" row. A ShellRoute child; needs
  /// `search`, `ui_shell` and `location`.
  static const exploreSettingsPath = '/explore/settings';
  // The Scheduled posts list, behind the `posts` and
  // `scheduled_posts` flags. A root-level full-screen route like /compose, NOT
  // a ShellRoute child: the composer pushes it over itself (dialog link, toast
  // View), and a second page of the same ShellRoute under the composer breaks
  // the Navigator (duplicate page key).
  static const scheduledPostsPath = '/scheduled';
  // Drafts (Unsent posts | Scheduled), behind `posts` + `drafts`.
  // Root-level and full-screen like /compose and /scheduled. `/scheduled`
  // redirects to its Scheduled tab while `drafts` is on. Push it from the
  // composer with `extra: true` (pick mode): choosing a draft pops its id.
  static const draftsPath = '/drafts';
  static const scheduledTabPath = '/drafts?tab=scheduled';
  // The Bookmarks list, titled "History" since then (`?tab=likes` opens
  // its Likes tab). A ShellRoute child (the rail marks it), needing only the
  // `posts` flag; the entry points need `bookmarks` as well.
  static const bookmarksPath = '/bookmarks';

  // The caller's Lists. `/lists/:id` (the detail) is under the
  // same `lists` flag redirect.
  static const listsPath = '/lists';
  // Discover public Lists (needs `list_follows`); declared before `/lists/:id`.
  static const discoverListsPath = '/lists/discover';
  static String listPath(String listId) =>
      '/lists/${Uri.encodeComponent(listId)}';
  static String listMembersPath(String listId) => '${listPath(listId)}/members';
  // Communities (behind the `communities` flag redirect).
  // `/communities/new` is matched before `/communities/:id`.
  static const communitiesPath = '/communities';
  static const communityNewPath = '/communities/new';
  static String communityPath(String communityId) =>
      '/communities/${Uri.encodeComponent(communityId)}';
  static String communityModerationLogPath(String communityId) =>
      '${communityPath(communityId)}/moderation-log';
  static String communityMembersPath(String communityId) =>
      '${communityPath(communityId)}/members';
  // Plans (beacons). With `beacons` off, `/plans` shows the paused state in
  // the new shell and the pages under it redirect there (ADR-0034 section 4);
  // the legacy chrome redirects all of them Home. `/plans/new` is matched
  // before `/plans/:id`.
  static const plansPath = '/plans';
  static const planNewPath = '/plans/new';
  static String planPath(String beaconId) =>
      '/plans/${Uri.encodeComponent(beaconId)}';
  // `/plans/mine` is matched before `/plans/:id` too.
  static const plansMinePath = '/plans/mine';
  static String planPeoplePath(String beaconId) =>
      '${planPath(beaconId)}/people';
  static String planEditPath(String beaconId) => '${planPath(beaconId)}/edit';
  // Manage pinned (the Home tabs); needs `lists` and `ui_shell`.
  static const pinnedPath = '/home/pinned';
  // The search results, behind the `search` flag; build links with
  // `searchResultsLocation` (domain/search_routes.dart).
  static const searchRoute = '/search';
  // The Follow requests list of a protected account, a ShellRoute child.
  // Needs `graph`, and `private_accounts` or a protected caller (the undo rule).
  static const followRequestsPath = '/follow-requests';
  // The read-only shells, behind the `shells` flag (every path redirects
  // Home without it). The first three are ShellRoute children, built only when
  // their kind is in `kVisibleShells`. `/premium` is a dialog on the root
  // navigator, reachable only by `push` (see `kShellPushExtra`).
  static const creatorStudioPath = '/creator-studio';
  static const premiumPath = '/premium';
  static const advertisePath = '/advertise';
  static const callsPath = '/calls';
  static String profilePath(String handle) => '/profile/$handle';

  /// The composer opened on the saved draft [draftId]:
  /// `/compose?draft=<id>`.
  static String composeDraftPath(String draftId) =>
      '$composePath?draft=${Uri.encodeQueryComponent(draftId)}';

  /// The composer with the community [communityId] preselected as the
  /// audience: `/compose?community=<id>`. Used only while the caller is
  /// in that community; otherwise it opens on Everyone and says so.
  static String composeCommunityPath(String communityId) =>
      '$composePath?community=${Uri.encodeQueryComponent(communityId)}';

  /// The quote composer for [postId]: `/compose?quote=<id>`. Pass the
  /// quoted post's `EmbeddedPost` as `extra` for the preview.
  static String composeQuotePath(String postId) =>
      '$composePath?quote=${Uri.encodeQueryComponent(postId)}';

  /// The composer with the caller's plan [beaconId] attached:
  /// `/compose?plan=<id>` (a post that shares the plan, behind
  /// `post_beacon_embed`). Pass the plan's `BeaconPreview` as `extra` for the
  /// card in the composer.
  static String composePlanPath(String beaconId) =>
      '$composePath?plan=${Uri.encodeQueryComponent(beaconId)}';

  /// Profile by user id: what post cards and mentions use, since handles can
  /// be changed and re-claimed.
  static String profileByIdPath(String userId) =>
      '/u/${Uri.encodeComponent(userId)}';

  /// Another person's public Lists (behind the `lists` flag). Pass the
  /// handle, if known, as `extra` for the header.
  static String userListsPath(String userId) =>
      '/u/${Uri.encodeComponent(userId)}/lists';

  /// One post (`GetPost`): what a post card opens.
  static String postPath(String postId) =>
      '/post/${Uri.encodeComponent(postId)}';

  static String composeReplyPath(String postId) =>
      '/compose/reply/${Uri.encodeComponent(postId)}';

  static String postPhotoPath(String postId, int index) =>
      '${postPath(postId)}/photo/$index';

  static String followersPath(String handle) => '/profile/$handle/followers';
  static String followingPath(String handle) => '/profile/$handle/following';

  late final GoRouter router = GoRouter(
    initialLocation: '/',
    refreshListenable: Listenable.merge([
      GoRouterRefreshStream([_authBloc.stream, _onboardingBloc.stream]),
      ?_messagingGate,
    ]),
    redirect: _redirect,
    routes: [
      ...articleRoutes(),
      ...authRoutes(),
      buildComposeReplyRoute(),
      postPhotoRoute(),
      buildComposeRoute(),
      ...draftRoutes(),
      accountDeletedRoute(),
      ...premiumRoutes(premiumPushAllowed: _premiumPushAllowed),
      shellRoute(onboardingBloc: _onboardingBloc),
      ...messagingRootRoutes(),
      ...locationRootRoutes(),
    ],
  );

  // The shared link a visitor cold-opened, kept in memory (never in a
  // visible URL) while the redirects send them through the splash, welcome,
  // sign-in and onboarding. Web sign-in is popup-only, so the page does not reload in
  // between. Only ever a value [deepLinkTarget] returned.
  String? _pendingTarget;

  // True once a signed-in visitor has settled on a page: from then on a link
  // is never stashed again, so signing out and in (maybe as someone else)
  // goes Home instead of replaying the old location.
  bool _landed = false;

  static final _deepLinkPatterns = [
    RegExp(r'^/articles/[A-Za-z0-9_-]{16,64}(?:/focus)?$'),
    RegExp(r'^/post/\d{19}$'),
    RegExp(r'^/post/\d{19}/photo/[1-4]$'),
    RegExp(r'^/compose/reply/\d{19}$'),
    // A uid is Firebase's alphanumeric id. No `%`: `%2F` and `%0D%0A` never
    // become part of a target (I-1).
    RegExp(r'^/u/[A-Za-z0-9-]{1,128}$'),
  ];

  static final _profilePath = RegExp(r'^/profile/([^/]+)$');
  static final _messageThreadPath = RegExp(r'^/messages/[^/]+$');

  /// A conversation link: fixed-length lower-case hex, the
  /// shape of a conversation id. Deliberately tighter than `/u/...` and
  /// `/profile/...`: a query or a fragment disqualifies the whole link instead
  /// of being dropped. `/messages`, `/messages/requests` and `/messages/new`
  /// are not targets.
  static final _messageTargetPattern = RegExp(
    '^/messages/$kConversationIdPattern\$',
  );

  /// The path of [uri] when it is a link worth keeping through the splash,
  /// sign-in and onboarding (`/post/<19 digits>`, `/u/<id>`,
  /// `/profile/<handle>`, `/messages/<32 hex>`), else null. Only a relative
  /// URI is kept: an absolute URL, `//host` or any other route never becomes a
  /// target (no open redirect). A query or fragment is never carried along: the
  /// post and profile shapes drop it and keep the bare path, the conversation
  /// shape is refused outright. The returned value is the bare path. `Uri`
  /// normalises percent-encoded unreserved characters when it parses, so a
  /// typed `/messages/%61...` link reaches this check as the bare path (the same
  /// link) and is accepted as that id.
  static String? deepLinkTarget(Uri uri) {
    if (uri.hasScheme || uri.hasAuthority) return null;
    final path = uri.path;
    for (final pattern in _deepLinkPatterns) {
      if (pattern.hasMatch(path)) return path;
    }
    if (!uri.hasQuery &&
        !uri.hasFragment &&
        _messageTargetPattern.hasMatch(path)) {
      return path;
    }
    // A handle follows the identity grammar (`kHandlePattern`; typed links may
    // use any case, callers lowercase before validating).
    final handle = _profilePath.firstMatch(path)?.group(1);
    if (handle != null && kHandlePattern.hasMatch(handle.toLowerCase())) {
      return path;
    }
    return null;
  }

  /// The routes a visitor passes through on the way to their target: the
  /// pending target survives them and is dropped on arrival anywhere else.
  static bool _isHopPath(String path) =>
      path == '/' ||
      path == welcomePath ||
      path == signInPath ||
      path == signUpPath ||
      path == onboardingPath ||
      path == onboardingPhotoPath ||
      path == sessionErrorPath;

  String get _landingPath => _pendingTarget ?? homePath;

  String? _redirect(BuildContext context, GoRouterState state) {
    final result = _resolve(state);
    // Bookkeeping that is safe to repeat: go_router can call a redirect more
    // than once for the same location (one auth change and one onboarding
    // change each refresh it), so landing never consumes the target. Leaving
    // a shareable location stashes it until the visitor has landed; settling
    // on any other non-hop page forgets it.
    final from = state.uri.path;
    final hop = _isHopPath(from);
    if (result != null) {
      final target = deepLinkTarget(state.uri);
      if (target != null && !_landed) {
        _pendingTarget = target;
      } else if (!hop) {
        _pendingTarget = null;
      }
    } else if (!hop) {
      // Only a settled, ready session counts: while GetMe is loading the
      // visitor may still be bounced to onboarding and must keep the target.
      if (_authBloc.state.status == AuthStatus.authenticated &&
          _onboardingBloc.state.status == OnboardingStatus.ready) {
        _landed = true;
      }
      if (from != _pendingTarget) _pendingTarget = null;
    }
    return result;
  }

  String? _resolve(GoRouterState state) {
    final authState = _authBloc.state;
    final loc = state.matchedLocation;
    final isAuthRoute =
        loc == welcomePath || loc == signInPath || loc == signUpPath;
    if (loc == accountDeletedPath) return null;

    if (authState.status == AuthStatus.unknown) {
      return loc == '/' ? null : '/';
    }
    if (authState.status == AuthStatus.unauthenticated) {
      return isAuthRoute ? null : welcomePath;
    }

    // Signed in (authenticated or needsEmailVerification).
    if (isAuthRoute || loc == '/') {
      return _landingPath;
    }
    if (authState.status == AuthStatus.needsEmailVerification) {
      // AuthGate renders the verification prompt in place; no URL change.
      return null;
    }

    final onboardingStatus = _onboardingBloc.state.status;
    switch (onboardingStatus) {
      case OnboardingStatus.profileRequired:
        // The delete-account page must not be trapped by this redirect.
        return (loc == onboardingPath || loc == onboardingDeletePath)
            ? null
            : onboardingPath;
      case OnboardingStatus.ready:
        // Right after this session's CreateProfile (media on): the optional
        // photo step, then Home. Skipping or finishing clears the flag, which
        // refreshes this redirect. A later visit to the path goes Home.
        if (_onboardingBloc.state.photoStepPending) {
          return loc == onboardingPhotoPath ? null : onboardingPhotoPath;
        }
        if (loc == onboardingPhotoPath) return _landingPath;
        if (loc == onboardingPath || loc == sessionErrorPath) {
          return _landingPath;
        }
        // Only meaningful without a profile; Settings has the real entry.
        if (loc == onboardingDeletePath) return settingsPath;
        return _shellsFlagRedirect(loc, state.extra) ??
            _graphFlagRedirect(loc) ??
            _accountFlagRedirect(loc) ??
            _profileEditFlagRedirect(loc) ??
            _scheduledFlagRedirect(loc) ??
            _draftsFlagRedirect(loc) ??
            _bookmarksFlagRedirect(loc) ??
            _listsFlagRedirect(loc) ??
            _communitiesFlagRedirect(loc) ??
            _plansFlagRedirect(loc) ??
            _searchFlagRedirect(loc) ??
            _messagesFlagRedirect(loc) ??
            _followRequestsRedirect(loc) ??
            _exploreFlagRedirect(loc) ??
            _notificationsFlagRedirect(loc) ??
            _notificationPrefsFlagRedirect(loc) ??
            _messageSettingsFlagRedirect(loc) ??
            _locationFlagRedirect(loc);
      case OnboardingStatus.error:
        // GetMe failed with nothing usable (no cached profile, or right
        // after CreateProfile): a full-screen Retry, never Home with every
        // flag off.
        // The delete-account page stays reachable, as for profileRequired.
        return (loc == sessionErrorPath || loc == onboardingDeletePath)
            ? null
            : sessionErrorPath;
      case OnboardingStatus.emailVerificationRequired:
        // CreateProfileScreen renders VerifyEmailView in place for this
        // status; no URL change (same pattern as needsEmailVerification
        // above). From the error page (a retried GetMe said verify first)
        // that screen is where the prompt lives.
        return loc == sessionErrorPath ? onboardingPath : null;
      case OnboardingStatus.unknown:
      case OnboardingStatus.loading:
        // The error page shows a spinner while a retried GetMe runs.
        return null;
    }
  }

  /// `/compose/reply/:id`, the reply composer (also mounted by the tablet
  /// composer tests, so they drive this definition). Full screen below
  /// 600dp on the tablet layout (700 elsewhere), the content-area dialog at
  /// 600-1199dp on it, today's dialog from 700 elsewhere; one editor across
  /// every switch (tablet plan sections 4.1 and 5.2).
  static GoRoute composeReplyRoute() => buildComposeReplyRoute();

  /// `/compose`, the post and quote composer (also mounted by the tablet
  /// composer tests). Outside the shell: no nav chrome while writing. Full
  /// screen on phones and desktop; on the tablet layout (600-1199dp) a
  /// dialog over the page it was opened from, or full screen on a cold
  /// start (tablet plan 4.1, Composer row). The page is never opaque and is
  /// the same type at every width (`ComposerPage`).
  static GoRoute composeRoute() => buildComposeRoute();

  static final _graphOnlyRoutes = RegExp(r'^/settings/(?:blocked|muted)$');
  static final _accountOnlyRoutes = RegExp(
    r'^/settings/(?:export|delete-account)$',
  );

  /// Account-lifecycle routes (data export, delete account) redirect to
  /// Settings when the flag is off for this caller.
  String? _accountFlagRedirect(String loc) {
    if (_onboardingBloc.state.enabledFeatures.contains(
      kFeatureAccountLifecycle,
    )) {
      return null;
    }
    return _accountOnlyRoutes.hasMatch(loc) ? settingsPath : null;
  }

  /// The four shell paths redirect Home unless `shells` is on for this caller.
  /// `/premium` also redirects Home when it was not pushed from inside
  /// the app (no [kShellPushExtra]): a typed URL, a reload or a cold start
  /// never opens the dialog on its own. The routes do not need `ui_shell`.
  String? _shellsFlagRedirect(String loc, Object? extra) {
    if (loc != creatorStudioPath &&
        loc != premiumPath &&
        loc != advertisePath &&
        loc != callsPath) {
      return null;
    }
    if (!_onboardingBloc.state.enabledFeatures.contains(kFeatureShells)) {
      return homePath;
    }
    if (loc == premiumPath && !_premiumPushAllowed(extra)) return homePath;
    return null;
  }

  /// The Premium dialog shows only for an in-app push ([kShellPushExtra]) and
  /// with `shells` on for the caller.
  bool _premiumPushAllowed(Object? extra) =>
      extra is ShellPush &&
      _onboardingBloc.state.enabledFeatures.contains(kFeatureShells);

  /// `/messages`, `/messages/requests`, `/messages/new` (it matches the
  /// thread pattern), `/messages/new/draft` and `/messages/<id>` redirect Home
  /// unless `messaging` is on for this caller. `GetMe` lists
  /// the flag per caller, so a flag that is off for everyone is the same case.
  /// While the gate is `readOnly` (off for this caller only), all but
  /// `/messages/new` and `/messages/new/draft` open, and those two land on
  /// `/messages`.
  String? _messagesFlagRedirect(String loc) {
    if (loc != messagesPath &&
        loc != messageRequestsPath &&
        loc != messageDraftPath &&
        !_messageThreadPath.hasMatch(loc)) {
      return null;
    }
    if (_onboardingBloc.state.enabledFeatures.contains(kFeatureMessaging)) {
      return null;
    }
    // Messaging is off for this caller only (read-only access). The inbox, the
    // requests and a thread open; starting a message does not.
    if (_messagingGate?.access == MessagingAccess.readOnly) {
      return loc == messageNewPath || loc == messageDraftPath
          ? messagesPath
          : null;
    }
    return homePath;
  }

  /// `/follow-requests` redirects Home unless `graph` is on and the caller is
  /// protected or has `private_accounts`. A protected caller keeps the
  /// screen with `private_accounts` off everywhere: requests are never lost
  /// to a flag (the undo rule).
  String? _followRequestsRedirect(String loc) {
    if (loc != followRequestsPath) return null;
    final state = _onboardingBloc.state;
    final allowed = followRequestsAllowed(
      enabledFeatures: state.enabledFeatures,
      isProtected: state.profile?.isPrivate ?? false,
    );
    return allowed ? null : homePath;
  }

  /// `/explore` redirects Home unless `search` and `ui_shell` are both on for
  /// this caller (the legacy chrome gets no Explore).
  String? _exploreFlagRedirect(String loc) {
    final needs = switch (loc) {
      explorePath => const {kFeatureSearch, kFeatureUiShell},
      exploreTrendingPath => const {
        kFeatureSearch,
        kFeatureUiShell,
        kFeatureTrends,
      },
      exploreSettingsPath => const {
        kFeatureSearch,
        kFeatureUiShell,
        kFeatureLocation,
      },
      exploreMediaPath => const {
        kFeatureSearch,
        kFeatureUiShell,
        kFeatureTrends,
        kFeatureMedia,
      },
      _ => null,
    };
    if (needs == null) return null;
    final features = _onboardingBloc.state.enabledFeatures;
    return features.containsAll(needs) ? null : homePath;
  }

  /// `/notifications` redirects Home when the flag is off for this caller.
  String? _notificationsFlagRedirect(String loc) {
    if (loc != notificationsPath) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeatureNotifications)
        ? null
        : homePath;
  }

  /// The Scheduled posts list redirects to Settings unless `posts` is on for
  /// this caller. It does NOT need `scheduled_posts`: ListScheduledPosts
  /// and CancelScheduledPost only need the flag "not globally off",
  /// so a user dropped from the allowlist can still see and
  /// cancel what they already scheduled. A globally-off flag shows the list's
  /// own "not available" state.
  String? _scheduledFlagRedirect(String loc) {
    if (loc != scheduledPostsPath) return null;
    final features = _onboardingBloc.state.enabledFeatures;
    if (!features.contains(kFeaturePosts)) return settingsPath;
    // With `drafts` on the list is the Drafts screen's Scheduled tab;
    // with it off the old screen stays, so every link keeps working.
    return features.contains(kFeatureDrafts) ? scheduledTabPath : null;
  }

  /// `/drafts` redirects Home unless `posts` and `drafts` are on.
  String? _draftsFlagRedirect(String loc) {
    if (loc != draftsPath) return null;
    final features = _onboardingBloc.state.enabledFeatures;
    return features.contains(kFeaturePosts) && features.contains(kFeatureDrafts)
        ? null
        : homePath;
  }

  /// `/bookmarks` redirects Home unless `posts` is on for this caller.
  /// It does NOT need `bookmarks`: ListBookmarks and RemoveBookmark only need
  /// the flag "not globally off", so a user dropped from the
  /// allowlist still reaches what they saved. A flag that is off for everyone
  /// shows the list's own "not available" state.
  String? _bookmarksFlagRedirect(String loc) {
    if (loc != bookmarksPath &&
        !loc.startsWith('$articlesPath/') &&
        loc != articlesPath &&
        !loc.startsWith('/articles/')) {
      return null;
    }
    return _onboardingBloc.state.enabledFeatures.contains(kFeaturePosts)
        ? null
        : homePath;
  }

  static final _listsRoutes = RegExp(r'^(?:/lists(?:/|$)|/u/[^/]+/lists$)');

  /// `/lists`, `/lists/...` and `/u/:id/lists` redirect Home unless `lists` is on for this
  /// caller. The server stays authoritative.
  String? _listsFlagRedirect(String loc) {
    final features = _onboardingBloc.state.enabledFeatures;
    // Manage pinned also needs the new shell, the only chrome with
    // the Home tab bar.
    if (loc == pinnedPath) {
      return features.contains(kFeatureLists) &&
              features.contains(kFeatureUiShell)
          ? null
          : homePath;
    }
    if (!_listsRoutes.hasMatch(loc)) return null;
    if (loc == discoverListsPath && !features.contains(kFeatureListFollows)) {
      return homePath;
    }
    return features.contains(kFeatureLists) ? null : homePath;
  }

  static final _communitiesRoutes = RegExp(r'^/communities(?:/|$)');

  /// `/communities` and everything under it redirect Home unless `communities`
  /// is on for this caller. The server stays authoritative.
  String? _communitiesFlagRedirect(String loc) {
    if (!_communitiesRoutes.hasMatch(loc)) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeatureCommunities)
        ? null
        : homePath;
  }

  static final _plansRoutes = RegExp(r'^/plans(?:/|$)');

  /// `/plans...` with `beacons` off for this caller. In the new shell
  /// (`ui_shell` on) Plans is never turned off (ADR-0034 section 4): `/plans`
  /// opens and shows the paused state, and everything under it (`/plans/new`,
  /// `/plans/mine`, `/plans/:id`, `/plans/:id/edit`, `/plans/:id/people`)
  /// redirects to `/plans`, so a deep link to a plan lands on the paused
  /// state and nothing is a dead end. The legacy chrome has no Plans
  /// destination and keeps redirecting all of them Home. With `beacons` on
  /// nothing redirects. The server stays authoritative.
  String? _plansFlagRedirect(String loc) {
    if (!_plansRoutes.hasMatch(loc)) return null;
    final features = _onboardingBloc.state.enabledFeatures;
    if (features.contains(kFeatureBeacons)) return null;
    if (!features.contains(kFeatureUiShell)) return homePath;
    return loc == plansPath ? null : plansPath;
  }

  /// `/search` redirects Home unless `search` is on for this caller.
  String? _searchFlagRedirect(String loc) {
    if (loc != searchRoute) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeatureSearch)
        ? null
        : homePath;
  }

  /// Notification settings redirect to Settings unless `notifications` and
  /// `notification_prefs` are both on for this caller.
  String? _notificationPrefsFlagRedirect(String loc) {
    if (loc != notificationSettingsPath) return null;
    final features = _onboardingBloc.state.enabledFeatures;
    return features.contains(kFeatureNotifications) &&
            features.contains(kFeatureNotificationPrefs)
        ? null
        : settingsPath;
  }

  /// Message settings redirect to Settings with `read_receipts` and
  /// `dm_policy` both off, unless the signed-in account has one of them set
  /// (receipts on, or anything but Everyone): then the page is the way back.
  String? _messageSettingsFlagRedirect(String loc) {
    if (loc != messageSettingsPath) return null;
    final features = _onboardingBloc.state.enabledFeatures;
    if (features.contains(kFeatureReadReceipts) ||
        features.contains(kFeatureDmPolicy)) {
      return null;
    }
    final mine = _ownPrivacy?.value;
    final uid = _authBloc.state.user?.uid;
    if (mine != null && mine.userId == uid && ownPrivacyIsSet(mine)) {
      return null;
    }
    return settingsPath;
  }

  /// The consent and picker pages need `location`; Settings > Location itself
  /// stays reachable in every flag mode (withdrawal).
  String? _locationFlagRedirect(String loc) {
    if (loc != locationConsentPath && loc != areaPickerPath) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeatureLocation)
        ? null
        : settingsPath;
  }

  static final _profileEditRoutes = RegExp(r'^/settings/(?:profile|handle)$');

  /// Edit profile / Change handle redirect to Settings when the
  /// `profile_snapshot` flag is off for this caller.
  String? _profileEditFlagRedirect(String loc) {
    if (_onboardingBloc.state.enabledFeatures.contains(
      kFeatureProfileSnapshot,
    )) {
      return null;
    }
    return _profileEditRoutes.hasMatch(loc) ? settingsPath : null;
  }

  static final _followersOrFollowing = RegExp(
    r'^/profile/([^/]+)/(?:followers|following)$',
  );

  /// Graph-only routes redirect away when the graph feature flag is off for
  /// this caller — belt-and-suspenders alongside hiding the
  /// UI entry points that link to them.
  String? _graphFlagRedirect(String loc) {
    if (_onboardingBloc.state.enabledFeatures.contains(kFeatureGraph)) {
      return null;
    }
    if (_graphOnlyRoutes.hasMatch(loc)) return settingsPath;
    final match = _followersOrFollowing.firstMatch(loc);
    if (match != null) return profilePath(match.group(1)!);
    return null;
  }
}
