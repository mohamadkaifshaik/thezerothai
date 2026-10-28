import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../features/account/domain/account_feature_flag.dart';
import '../../features/account/presentation/data_export_screen.dart';
import '../../features/account/presentation/delete_account_screen.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/auth/presentation/bloc/auth_state.dart';
import '../../features/auth/presentation/sign_in_screen.dart';
import '../../features/auth/presentation/sign_up_screen.dart';
import '../../features/auth/presentation/widgets/auth_gate.dart';
import '../../features/engagement/presentation/bookmarks_screen.dart';
import '../../features/graph/domain/graph_feature_flag.dart';
import '../../features/graph/presentation/graph_list_screen.dart';
import '../../features/graph/presentation/managed_accounts_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/messages/domain/messaging_feature_flag.dart';
import '../../features/messages/presentation/conversations_screen.dart';
import '../../features/notifications/domain/notifications_feature_flag.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../gen/dzeroth/messaging/v1/messaging.pbenum.dart' show Folder;
import '../../features/onboarding/domain/handle_rules.dart' show kHandlePattern;
import '../../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../features/onboarding/presentation/bloc/onboarding_state.dart';
import '../../features/onboarding/presentation/create_profile_screen.dart';
import '../../features/posts/presentation/composer_screen.dart';
import '../../features/posts/domain/posts_feature_flag.dart';
import '../../features/posts/presentation/post_detail_screen.dart';
import '../../features/posts/presentation/scheduled_posts_screen.dart';
import '../../features/profile/domain/profile_edit_feature_flag.dart';
import '../../features/shells/domain/shell_entries.dart';
import '../../features/shells/domain/shells_feature_flag.dart';
import '../../features/shells/presentation/advertise_screen.dart';
import '../../features/shells/presentation/calls_screen.dart';
import '../../features/shells/presentation/creator_studio_screen.dart';
import '../../features/shells/presentation/premium_dialog.dart';
import '../../features/profile/presentation/change_handle_screen.dart';
import '../../features/profile/presentation/edit_profile_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import '../widgets/splash_screen.dart';
import 'go_router_refresh_stream.dart';
import 'main_shell.dart';

/// Builds the app's `go_router`. Redirects branch purely on cached
/// [AuthBloc]/[OnboardingBloc] state — never on a fresh network call — so
/// navigation is instant and never burns an extra `GetMe` (CLAUDE.md prime
/// directive: the client is our cheapest cache).
class AppRouter {
  AppRouter({
    required AuthBloc authBloc,
    required OnboardingBloc onboardingBloc,
  }) : _authBloc = authBloc,
       _onboardingBloc = onboardingBloc;

  final AuthBloc _authBloc;
  final OnboardingBloc _onboardingBloc;

  static const signInPath = '/sign-in';
  static const signUpPath = '/sign-up';
  static const onboardingPath = '/onboarding';
  static const homePath = '/home';
  static const composePath = '/compose';
  static const settingsPath = '/settings';
  // P6: the Notifications tab, behind the `notifications` flag.
  static const notificationsPath = '/notifications';
  // W7-14: the inbox and its Requests folder, behind the `messaging` flag
  // (both redirect Home without it). ShellRoute children. `/messages/new`
  // (W7-17) and `/messages/:id` (W7-15) are added by those tickets.
  static const messagesPath = '/messages';
  static const messageRequestsPath = '/messages/requests';
  // The Settings routes land with T15; the constants live here so
  // ProfileHeader and SettingsScreen share one source of truth.
  static const blockedAccountsPath = '/settings/blocked';
  static const mutedAccountsPath = '/settings/muted';
  static const deleteAccountPath = '/settings/delete-account';
  // Delete account for callers without a profile or with an unverified
  // email (P8 L-5): reachable while the profile-required redirect is active.
  static const onboardingDeletePath = '/onboarding/delete-account';
  // Final page after DeleteAccount: reachable signed out.
  static const accountDeletedPath = '/account-deleted';
  static const exportDataPath = '/settings/export';
  // P2-T5: Edit profile and Change handle, behind the `profile_snapshot` flag.
  static const editProfilePath = '/settings/profile';
  static const changeHandlePath = '/settings/handle';
  // CMP-D6: the Scheduled posts list, behind the `posts` and
  // `scheduled_posts` flags. A root-level full-screen route like /compose, NOT
  // a ShellRoute child: the composer pushes it over itself (dialog link, toast
  // View), and a second page of the same ShellRoute under the composer breaks
  // the Navigator (duplicate page key).
  static const scheduledPostsPath = '/scheduled';
  // W2-7: the Bookmarks list, titled "History" since W3-18 (`?tab=likes` opens
  // its Likes tab). A ShellRoute child (the rail marks it), needing only the
  // `posts` flag; the entry points need `bookmarks` as well.
  static const bookmarksPath = '/bookmarks';
  // W8-2: the read-only shells, behind the `shells` flag (every path redirects
  // Home without it). The first three are ShellRoute children, built only when
  // their kind is in `kVisibleShells`. `/premium` is a dialog on the root
  // navigator, reachable only by `push` (see `kShellPushExtra`).
  static const creatorStudioPath = '/creator-studio';
  static const premiumPath = '/premium';
  static const advertisePath = '/advertise';
  static const callsPath = '/calls';
  static String profilePath(String handle) => '/profile/$handle';

  /// The quote composer for [postId] (P5): `/compose?quote=<id>`. Pass the
  /// quoted post's `EmbeddedPost` as `extra` for the preview.
  static String composeQuotePath(String postId) =>
      '$composePath?quote=${Uri.encodeQueryComponent(postId)}';

  /// Profile by user id: what post cards and mentions use, since handles can
  /// be changed and re-claimed (ADR-0010 D7).
  static String profileByIdPath(String userId) =>
      '/u/${Uri.encodeComponent(userId)}';

  /// One post (`GetPost`): what a post card opens.
  static String postPath(String postId) =>
      '/post/${Uri.encodeComponent(postId)}';
  static String followersPath(String handle) => '/profile/$handle/followers';
  static String followingPath(String handle) => '/profile/$handle/following';

  late final GoRouter router = GoRouter(
    initialLocation: '/',
    refreshListenable: GoRouterRefreshStream([
      _authBloc.stream,
      _onboardingBloc.stream,
    ]),
    redirect: _redirect,
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
      GoRoute(
        path: signInPath,
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: signUpPath,
        builder: (context, state) => const SignUpScreen(),
      ),
      GoRoute(
        path: onboardingPath,
        builder: (context, state) =>
            const AuthGate(child: CreateProfileScreen()),
      ),
      // No AuthGate: unverified callers must reach it too (the gate would
      // swap in the verification prompt).
      GoRoute(
        path: onboardingDeletePath,
        builder: (context, state) => const DeleteAccountScreen(),
      ),
      // Full-screen, outside the shell: no nav chrome while writing.
      GoRoute(
        path: composePath,
        builder: (context, state) {
          final quote = state.uri.queryParameters['quote'] ?? '';
          return AuthGate(
            child: ComposerScreen(
              // Only a well-formed post id (19 digits) starts a quote.
              quoteOfPostId: _postIdPattern.hasMatch(quote) ? quote : '',
              quotePreview: state.extra is pb.EmbeddedPost
                  ? state.extra as pb.EmbeddedPost
                  : null,
            ),
          );
        },
      ),
      // Full-screen, outside the shell, so it can be pushed over the composer.
      GoRoute(
        path: scheduledPostsPath,
        builder: (context, state) =>
            const AuthGate(child: ScheduledPostsScreen()),
      ),
      GoRoute(
        path: accountDeletedPath,
        builder: (context, state) => const AccountDeletedScreen(),
      ),
      // A dialog over the current page, so it lives on the root navigator
      // outside the shell. Only `push` (with `kShellPushExtra`) opens it: a
      // typed URL, a reload or a cold start lands Home (`_shellsFlagRedirect`).
      if (kVisibleShells.contains(ShellKind.premium))
        GoRoute(
          path: premiumPath,
          // A push restored from web history skips the redirects (go_router
          // re-applies it as is) and loses its extra, so the builder checks
          // again and shows nothing then (security review W8-9 M-1).
          pageBuilder: (context, state) => _premiumPushAllowed(state.extra)
              ? PremiumDialogPage(key: state.pageKey)
              : NoTransitionPage<void>(
                  key: state.pageKey,
                  child: const _PopOnFirstFrame(),
                ),
        ),
      ShellRoute(
        builder: (context, state, child) =>
            MainShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: homePath,
            builder: (context, state) => const AuthGate(child: HomeScreen()),
          ),
          GoRoute(
            path: notificationsPath,
            builder: (context, state) =>
                const AuthGate(child: NotificationsScreen()),
          ),
          GoRoute(
            path: messagesPath,
            builder: (context, state) => const AuthGate(
              // TODO(W7-15): onOpenConversation opens `/messages/<id>`.
              // TODO(W7-17): onNewMessage opens `/messages/new`.
              child: ConversationsScreen(),
            ),
          ),
          GoRoute(
            path: messageRequestsPath,
            builder: (context, state) => const AuthGate(
              // TODO(W7-15): onOpenConversation opens `/messages/<id>`.
              child: ConversationsScreen(folder: Folder.FOLDER_REQUESTS),
            ),
          ),
          GoRoute(
            path: bookmarksPath,
            builder: (context, state) => AuthGate(
              // `?tab=likes` opens the Likes tab (W3-18); the screen ignores
              // it while the `likes_list` flag is off.
              child: BookmarksScreen(
                initialTab: HistoryTab.fromQuery(
                  state.uri.queryParameters['tab'],
                ),
              ),
            ),
          ),
          if (kVisibleShells.contains(ShellKind.creatorStudio))
            GoRoute(
              path: creatorStudioPath,
              builder: (context, state) =>
                  const AuthGate(child: CreatorStudioScreen()),
            ),
          if (kVisibleShells.contains(ShellKind.advertise))
            GoRoute(
              path: advertisePath,
              builder: (context, state) =>
                  const AuthGate(child: AdvertiseScreen()),
            ),
          if (kVisibleShells.contains(ShellKind.calls))
            GoRoute(
              path: callsPath,
              builder: (context, state) => const AuthGate(child: CallsScreen()),
            ),
          GoRoute(
            path: '/u/:userId',
            builder: (context, state) => AuthGate(
              child: ProfileScreen(userId: state.pathParameters['userId']!),
            ),
          ),
          GoRoute(
            path: '/post/:id',
            builder: (context, state) => AuthGate(
              child: PostDetailScreen(postId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: '/profile/:handle',
            builder: (context, state) => AuthGate(
              child: ProfileScreen(handle: state.pathParameters['handle']!),
            ),
          ),
          GoRoute(
            path: '/profile/:handle/followers',
            builder: (context, state) => AuthGate(
              child: GraphListScreen(
                handle: state.pathParameters['handle']!,
                userId: state.extra as String?,
                initialTab: GraphListTab.followers,
              ),
            ),
          ),
          GoRoute(
            path: '/profile/:handle/following',
            builder: (context, state) => AuthGate(
              child: GraphListScreen(
                handle: state.pathParameters['handle']!,
                userId: state.extra as String?,
                initialTab: GraphListTab.following,
              ),
            ),
          ),
          GoRoute(
            path: settingsPath,
            builder: (context, state) =>
                const AuthGate(child: SettingsScreen()),
          ),
          GoRoute(
            path: blockedAccountsPath,
            builder: (context, state) =>
                const AuthGate(child: BlockedAccountsScreen()),
          ),
          GoRoute(
            path: exportDataPath,
            builder: (context, state) =>
                const AuthGate(child: DataExportScreen()),
          ),
          GoRoute(
            path: mutedAccountsPath,
            builder: (context, state) =>
                const AuthGate(child: MutedAccountsScreen()),
          ),
          GoRoute(
            path: editProfilePath,
            builder: (context, state) =>
                const AuthGate(child: EditProfileScreen()),
          ),
          GoRoute(
            path: changeHandlePath,
            builder: (context, state) =>
                const AuthGate(child: ChangeHandleScreen()),
          ),
          GoRoute(
            path: deleteAccountPath,
            builder: (context, state) =>
                const AuthGate(child: DeleteAccountScreen()),
          ),
        ],
      ),
    ],
  );

  // W2-9: the shared link a visitor cold-opened, kept in memory (never in a
  // visible URL) while the redirects send them through the splash, sign-in and
  // onboarding. Web sign-in is popup-only, so the page does not reload in
  // between. Only ever a value [deepLinkTarget] returned.
  String? _pendingTarget;

  // True once a signed-in visitor has settled on a page: from then on a link
  // is never stashed again, so signing out and in (maybe as someone else)
  // goes Home instead of replaying the old location.
  bool _landed = false;

  static final _deepLinkPatterns = [
    RegExp(r'^/post/\d{19}$'),
    // A uid is Firebase's alphanumeric id. No `%`: `%2F` and `%0D%0A` never
    // become part of a target (W2-14 I-1).
    RegExp(r'^/u/[A-Za-z0-9-]{1,128}$'),
  ];

  static final _profilePath = RegExp(r'^/profile/([^/]+)$');

  /// The path of [uri] when it is a link worth keeping through the splash,
  /// sign-in and onboarding (`/post/<19 digits>`, `/u/<id>`,
  /// `/profile/<handle>`), else null. Only a relative, path-only URI is kept:
  /// an absolute URL, `//host`, any other route, a query or a fragment never
  /// becomes a target (no open redirect, no state smuggled in). The returned
  /// value is the bare path.
  static String? deepLinkTarget(Uri uri) {
    if (uri.hasScheme || uri.hasAuthority) return null;
    final path = uri.path;
    for (final pattern in _deepLinkPatterns) {
      if (pattern.hasMatch(path)) return path;
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
      path == signInPath ||
      path == signUpPath ||
      path == onboardingPath;

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
    final isAuthRoute = loc == signInPath || loc == signUpPath;
    if (loc == accountDeletedPath) return null;

    if (authState.status == AuthStatus.unknown) {
      return loc == '/' ? null : '/';
    }
    if (authState.status == AuthStatus.unauthenticated) {
      return isAuthRoute ? null : signInPath;
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
        if (loc == onboardingPath) return _landingPath;
        // Only meaningful without a profile; Settings has the real entry.
        if (loc == onboardingDeletePath) return settingsPath;
        return _shellsFlagRedirect(loc, state.extra) ??
            _graphFlagRedirect(loc) ??
            _accountFlagRedirect(loc) ??
            _profileEditFlagRedirect(loc) ??
            _scheduledFlagRedirect(loc) ??
            _bookmarksFlagRedirect(loc) ??
            _messagesFlagRedirect(loc) ??
            _notificationsFlagRedirect(loc);
      case OnboardingStatus.unknown:
      case OnboardingStatus.loading:
      case OnboardingStatus.error:
      case OnboardingStatus.emailVerificationRequired:
        // CreateProfileScreen renders VerifyEmailView in place for this
        // status; no URL change (same pattern as needsEmailVerification
        // above).
        return null;
    }
  }

  static final _postIdPattern = RegExp(r'^\d{19}$');
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

  /// The four shell paths redirect Home unless `shells` is on for this caller
  /// (W8-2). `/premium` also redirects Home when it was not pushed from inside
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

  /// `/messages` and `/messages/requests` redirect Home unless `messaging` is
  /// on for this caller (W7-14). `GetMe` lists the flag per caller, so a flag
  /// that is off for everyone is the same case.
  String? _messagesFlagRedirect(String loc) {
    if (loc != messagesPath && loc != messageRequestsPath) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeatureMessaging)
        ? null
        : homePath;
  }

  /// `/notifications` redirects Home when the flag is off for this caller.
  String? _notificationsFlagRedirect(String loc) {
    if (loc != notificationsPath) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeatureNotifications)
        ? null
        : homePath;
  }

  /// The Scheduled posts list redirects to Settings unless `posts` is on for
  /// this caller (CMP-D6). It does NOT need `scheduled_posts`: ListScheduledPosts
  /// and CancelScheduledPost only need the flag "not globally off" (ADR-0021
  /// L-A option b), so a user dropped from the allowlist can still see and
  /// cancel what they already scheduled. A globally-off flag shows the list's
  /// own "not available" state.
  String? _scheduledFlagRedirect(String loc) {
    if (loc != scheduledPostsPath) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeaturePosts)
        ? null
        : settingsPath;
  }

  /// `/bookmarks` redirects Home unless `posts` is on for this caller (W2-7).
  /// It does NOT need `bookmarks`: ListBookmarks and RemoveBookmark only need
  /// the flag "not globally off" (ADR-0023 D5), so a user dropped from the
  /// allowlist still reaches what they saved. A flag that is off for everyone
  /// shows the list's own "not available" state.
  String? _bookmarksFlagRedirect(String loc) {
    if (loc != bookmarksPath) return null;
    return _onboardingBloc.state.enabledFeatures.contains(kFeaturePosts)
        ? null
        : homePath;
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
  /// this caller (ADR-0008 D6) — belt-and-suspenders alongside hiding the
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

/// Pops itself after its first frame: what a `/premium` entry restored from
/// web history renders instead of the dialog, so Back / Forward never reopens
/// it without a tap.
class _PopOnFirstFrame extends StatefulWidget {
  const _PopOnFirstFrame();

  @override
  State<_PopOnFirstFrame> createState() => _PopOnFirstFrameState();
}

class _PopOnFirstFrameState extends State<_PopOnFirstFrame> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) GoRouter.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
