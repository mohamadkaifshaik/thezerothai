import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/network/service_paused_cubit.dart';
import '../core/router/app_router.dart';
import '../core/share/share_links.dart';
import '../core/storage/app_database.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_mode_cubit.dart';
import '../core/widgets/service_paused_view.dart';
import '../features/account/data/account_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/bloc/auth_bloc.dart';
import '../features/auth/presentation/bloc/auth_state.dart';
import '../features/engagement/data/bookmarks_repository.dart';
import '../features/engagement/data/engagement_repository.dart';
import '../features/engagement/data/likes_repository.dart';
import '../features/engagement/data/poll_repository.dart';
import '../features/engagement/presentation/bloc/bookmarks_cubit.dart';
import '../features/engagement/presentation/bloc/engagement_cubit.dart';
import '../features/engagement/presentation/bloc/poll_cubit.dart';
import '../features/graph/data/graph_repository.dart';
import '../features/graph/data/suggestions_repository.dart';
import '../features/graph/presentation/bloc/suggestions_cubit.dart';
import '../features/media/data/gif_source.dart';
import '../features/media/data/image_picker_service.dart';
import '../features/media/data/media_repository.dart';
import '../features/media/domain/image_processor.dart';
import '../features/messages/data/messaging_repository.dart';
import '../features/messages/domain/messaging_feature_flag.dart';
import '../features/search/data/recent_searches_store.dart';
import '../features/search/data/search_repository.dart';
import '../features/search/presentation/bloc/trends_cubit.dart';
import '../features/messages/presentation/bloc/messages_badge_cubit.dart';
import '../features/moderation/data/moderation_repository.dart';
import '../features/notifications/data/notifications_repository.dart';
import '../features/notifications/data/push_opt_in_store.dart';
import '../features/notifications/domain/notifications_feature_flag.dart';
import '../features/notifications/presentation/bloc/push_cubit.dart';
import '../features/notifications/presentation/bloc/push_opt_in_cubit.dart';
import '../features/notifications/presentation/bloc/unread_badge_cubit.dart';
import '../features/onboarding/data/identity_repository.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/onboarding/presentation/bloc/onboarding_state.dart';
import '../features/posts/data/drafts_repository.dart';
import '../features/posts/data/posts_repository.dart';
import '../features/posts/domain/posts_feature_flag.dart';
import '../features/posts/presentation/bloc/pending_posts_cubit.dart';
import '../features/timeline/data/timeline_repository.dart';
import '../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../gen/dzeroth/messaging/v1/messaging.pbenum.dart' show Folder;
import 'session_wiring.dart';

/// Root widget: theme + `go_router`. All dependency wiring happens in
/// `bootstrap.dart`; this widget only assembles what it's given.
class AppWidget extends StatefulWidget {
  const AppWidget({
    super.key,
    required this.authBloc,
    required this.onboardingBloc,
    required this.identityRepository,
    required this.graphRepository,
    required this.suggestionsRepository,
    required this.accountRepository,
    required this.authRepository,
    required this.database,
    required this.postsRepository,
    required this.timelineRepository,
    required this.postsGate,
    required this.mediaRepository,
    this.imagePicker,
    this.imageProcessor = const IsolateImageProcessor(),
    this.gifSource,
    this.gifPreparer = const IsolateGifPreparer(),
    required this.notificationsRepository,
    required this.messagingRepository,
    required this.moderationRepository,
    required this.engagementRepository,
    required this.bookmarksRepository,
    this.searchRepository,
    this.pollRepository,
    required this.likesRepository,
    required this.pushCubit,
    required this.unreadBadgeCubit,
    this.servicePausedCubit,
    this.shareLinks,
  });

  final AuthBloc authBloc;
  final OnboardingBloc onboardingBloc;
  final IdentityRepository identityRepository;
  final GraphRepository graphRepository;

  /// The 48 h "Who to follow" list (W3-19, ADR-0024 Amendment 2) behind the
  /// Home card and the desktop right column.
  final SuggestionsRepository suggestionsRepository;
  final AccountRepository accountRepository;
  final AuthRepository authRepository;
  final AppDatabase database;
  final PostsRepository postsRepository;
  final TimelineRepository timelineRepository;
  final PostsFeatureGate postsGate;
  final NotificationsRepository notificationsRepository;

  /// Direct messages (ADR-0027): the inbox (W7-14) and the screens after it.
  final MessagingRepository messagingRepository;
  final ModerationRepository moderationRepository;

  /// Likes, reposts and quotes (P5, `FEATURE_ENGAGEMENT`).
  final EngagementRepository engagementRepository;

  /// Bookmarks (W2-6, `FEATURE_BOOKMARKS`): the session overlay and
  /// Add / RemoveBookmark.
  final BookmarksRepository bookmarksRepository;

  /// Search (W4-13, `FEATURE_SEARCH`); null in tests that do not search.
  final SearchRepository? searchRepository;

  /// Poll votes (W6-13, ADR-0029): `VotePoll` behind the `engagement` flag;
  /// null in tests that do not vote (cards then show polls read-only).
  final PollRepository? pollRepository;

  /// The Likes tab of History (W3-18, `FEATURE_LIKES_LIST`): `ListLikedPosts`
  /// in session memory; sign-out forgets it.
  final LikesRepository likesRepository;

  /// Push registration and tap handling (P6); built in bootstrap so the
  /// sign-out hook can unregister the device before the token is dropped.
  final PushCubit pushCubit;

  /// The unread badge, seeded from `GetMe` (P6).
  final UnreadBadgeCubit unreadBadgeCubit;

  /// Drives the full-screen "service paused" state (ADR-0022); bootstrap
  /// shares it with the API client. Null (tests) means never paused.
  final ServicePausedCubit? servicePausedCubit;

  /// The share origin and native share sheet for the post Share action (W2-8),
  /// from `AppConfig.shareOrigin`. Null (tests) means no Share action.
  final ShareLinks? shareLinks;

  /// P4 media (`FEATURE_MEDIA`): CreateUpload / PUT / FinalizeUpload.
  final MediaRepository mediaRepository;

  /// Photo picker and on-device resize/compress; injectable for tests.
  /// Defaults to the platform picker.
  final ImagePickerService? imagePicker;
  final ImageProcessor imageProcessor;

  /// Where the composer's GIF comes from (W6-16); defaults to the device
  /// gallery. [gifPreparer] checks it and makes its still thumbnail.
  final GifSource? gifSource;
  final GifPreparer gifPreparer;

  @override
  State<AppWidget> createState() => _AppWidgetState();
}

class _AppWidgetState extends State<AppWidget> {
  // Optimistic posts live for the session only (T16); sign-out drops them.
  final PendingPostsCubit _pendingPosts = PendingPostsCubit();
  // The session's like/repost overlay (P5); sign-out forgets it.
  late final EngagementCubit _engagement = EngagementCubit(
    repository: widget.engagementRepository,
    onUnexpectedError: reportUnexpectedError,
  );
  // The session's poll overlay (W6-13): optimistic vote, fresh counts; sign-out
  // forgets it. Null without a repository (tests).
  late final PollCubit? _polls = widget.pollRepository == null
      ? null
      : PollCubit(
          repository: widget.pollRepository!,
          onUnexpectedError: reportUnexpectedError,
        );
  // The session's bookmark overlay (W2-6); sign-out forgets it. The toast's
  // "View" opens the Bookmarks screen (W2-7).
  late final BookmarksCubit _bookmarks = BookmarksCubit(
    repository: widget.bookmarksRepository,
    viewRoute: AppRouter.bookmarksPath,
  );
  // The session's "Who to follow" rows (W3-19): one list for the Home card and
  // the desktop right column; sign-out forgets it.
  late final SuggestionsCubit _suggestions = SuggestionsCubit(
    repository: widget.suggestionsRepository,
  );
  // The session's trends list (W4-17/18, ADR-0028): one app-level cubit, one
  // GetTrends per 5 minutes for Explore and the side column; null without a
  // search repository (tests). Sign-out forgets it.
  late final TrendsCubit? _trends = widget.searchRepository == null
      ? null
      : TrendsCubit(repository: widget.searchRepository!);
  // The "Turn on notifications" card's memory (W2-12): one "Not now" per
  // account for Home and Notifications; keyed by the signed-in uid.
  // The store is also provided to the tree: Delete account forgets the
  // Unsent posts on this device (W6-14); Delete account wipes the deleted uid's.
  late final DraftsRepository _drafts = DraftsRepository(widget.database);
  // deleted uid's record there (W2-14 L-6).
  late final PushOptInStore _pushOptInStore = DatabasePushOptInStore(
    widget.database,
  );
  late final PushOptInCubit _pushOptIn = PushOptInCubit(
    store: _pushOptInStore,
    push: widget.pushCubit,
  );
  // The Messages badge (W7-19): conversations with unread messages, seeded
  // from `GetMe`; its own cubit, a message push never moves the notifications
  // badge. Sign-out resets it.
  final MessagesBadgeCubit _messagesBadge = MessagesBadgeCubit();
  late final ServicePausedCubit _servicePaused =
      widget.servicePausedCubit ?? ServicePausedCubit();
  late final StreamSubscription<AuthState> _authSub;
  // The one messenger of the app: sign-out clears its snackbars, so an Undo or
  // Retry of the previous account never lives into the next session (W2-14
  // L-5).
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  // The appearance choice (System / Light / Dark), saved on the device.
  late final ThemeModeCubit _themeMode = ThemeModeCubit(
    DatabaseThemeModeStore(widget.database),
  );
  late final ImagePickerService _imagePicker =
      widget.imagePicker ?? PlatformImagePickerService();
  late final GifSource _gifSource = widget.gifSource ?? DeviceGifSource();
  // Recent searches (W4-14): this device only, wiped on sign-out.
  late final RecentSearchesStore _recentSearches = DatabaseRecentSearchesStore(
    widget.database,
  );
  late final StreamSubscription<OnboardingState> _onboardingSub;
  Set<String>? _lastFeatures;

  /// The user the Messages access probe last ran for (W7-26).
  String? _probedUid;
  int _lastUnread = 0;
  int _lastUnreadConversations = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_themeMode.load());
    _authSub = widget.authBloc.stream.listen((state) {
      unawaited(_pushOptIn.load(state.user?.uid));
      if (state.status == AuthStatus.unauthenticated) {
        _messengerKey.currentState?.clearSnackBars();
        _pendingPosts.clear();
        _engagement.reset();
        _polls?.reset();
        _bookmarks.reset();
        _suggestions.reset();
        _trends?.reset();
        widget.likesRepository.clearSession();
        widget.unreadBadgeCubit.seed(0);
        _messagesBadge.seed(0);
        _lastFeatures = null;
        _probedUid = null;
        _lastUnread = 0;
        _lastUnreadConversations = 0;
        unawaited(widget.pushCubit.stop());
      }
    });
    unawaited(_pushOptIn.load(widget.authBloc.state.user?.uid));
    widget.pushCubit.onOpen = (location) => _appRouter.router.push(location);
    widget.pushCubit.onForeground = _onForegroundPush;
    widget.pushCubit.onMessagePush = _onMessagePush;
    // Every fresh GetMe (a new flag-set instance) seeds the badge, and
    // starts push once the notifications flag is on. Never a GetMe of its
    // own: the badge costs 0 extra reads.
    _onboardingSub = widget.onboardingBloc.stream.listen(_onOnboarding);
    _onOnboarding(widget.onboardingBloc.state);
  }

  /// A push arrived in the foreground: bump the badge, unless the list is
  /// open (it refreshes and marks everything seen itself, so the badge would
  /// only flash and then stick).
  void _onForegroundPush() {
    final path = _appRouter.router.routeInformationProvider.value.uri.path;
    if (path == AppRouter.notificationsPath) return;
    widget.unreadBadgeCubit.increment();
  }

  /// A direct-message push arrived in the foreground (W7-19): the Messages
  /// badge counts the conversation unless that thread is open (it polls
  /// instead), a request (requests never count, D10) or one the cached Inbox
  /// row already shows unread (the seed or the last Inbox load counted it).
  /// Reads the local cache only (0 extra reads). Never the notifications badge.
  Future<void> _onMessagePush(String conversationId) async {
    if (!widget.onboardingBloc.state.enabledFeatures.contains(
      kFeatureMessaging,
    )) {
      return;
    }
    pb.Conversation? cached;
    try {
      cached = await widget.messagingRepository.cachedConversation(
        conversationId,
      );
    } on Object {
      // No usable cache: count it, the next Inbox load or GetMe reconciles.
      cached = null;
    }
    if (!mounted) return;
    if (cached != null && cached.folder == Folder.FOLDER_REQUESTS) return;
    _messagesBadge.onMessagePush(
      conversationId,
      cachedUnread: cached != null && cached.unreadCount > 0,
    );
  }

  void _onOnboarding(OnboardingState state) {
    if (state.status != OnboardingStatus.ready) return;
    // A fresh GetMe changes the flag set or an unread count. Compared by
    // value: the state hands out a new set view on every read, so identity
    // would re-seed (and undo a local mark-seen) on any later emission.
    final last = _lastFeatures;
    final flagsChanged =
        last == null || !setEquals(last, state.enabledFeatures);
    // W7-26: the one Messages access probe, at session start, for another
    // user, and when the flag set changes, never on an unread-count change.
    // It sends nothing when messaging is on for the caller or the cache is
    // empty.
    if (flagsChanged) _polls?.flagsChanged();
    final uid = state.profile?.userId;
    if (flagsChanged || uid != _probedUid) {
      _probedUid = uid;
      unawaited(widget.messagingRepository.probeAccess());
    }
    final unreadChanged = _lastUnread != state.unreadNotificationCount;
    final conversationsChanged =
        _lastUnreadConversations != state.unreadConversationCount;
    if (!flagsChanged && !unreadChanged && !conversationsChanged) return;
    _lastFeatures = Set.of(state.enabledFeatures);
    _lastUnread = state.unreadNotificationCount;
    _lastUnreadConversations = state.unreadConversationCount;
    // Each badge is seeded when its own number (or the flag set) changed, so
    // a new conversation count never undoes a local mark-seen of the
    // notifications badge, and the other way round.
    // The Messages badge needs `messaging`, not `notifications` (push).
    if (flagsChanged || conversationsChanged) {
      _messagesBadge.seed(
        state.enabledFeatures.contains(kFeatureMessaging)
            ? state.unreadConversationCount
            : 0,
      );
    }
    if (!flagsChanged && !unreadChanged) return;
    if (state.enabledFeatures.contains(kFeatureNotifications)) {
      widget.unreadBadgeCubit.seed(state.unreadNotificationCount);
      unawaited(widget.pushCubit.start());
    } else {
      // Flag turned off mid-session: no listeners, no badge. The token is
      // kept (the same session may turn the flag back on).
      widget.unreadBadgeCubit.seed(0);
      unawaited(widget.pushCubit.stop(invalidateToken: false));
    }
  }

  @override
  void dispose() {
    _authSub.cancel();
    _onboardingSub.cancel();
    _pendingPosts.close();
    _engagement.close();
    _polls?.close();
    _bookmarks.close();
    _suggestions.close();
    _trends?.close();
    _themeMode.close();
    _pushOptIn.close();
    _messagesBadge.close();
    super.dispose();
  }

  late final AppRouter _appRouter = AppRouter(
    authBloc: widget.authBloc,
    onboardingBloc: widget.onboardingBloc,
    messagingGate: widget.messagingRepository.gate,
  );

  @override
  Widget build(BuildContext context) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: widget.identityRepository),
        RepositoryProvider.value(value: widget.graphRepository),
        RepositoryProvider.value(value: widget.accountRepository),
        RepositoryProvider.value(value: widget.authRepository),
        RepositoryProvider.value(value: widget.database),
        RepositoryProvider<PushOptInStore>.value(value: _pushOptInStore),
        RepositoryProvider<DraftsRepository>.value(value: _drafts),
        RepositoryProvider<UnexpectedErrorReporter>.value(
          value: reportUnexpectedError,
        ),
        RepositoryProvider.value(value: widget.postsRepository),
        RepositoryProvider.value(value: widget.timelineRepository),
        RepositoryProvider.value(value: widget.mediaRepository),
        RepositoryProvider<ImagePickerService>.value(value: _imagePicker),
        RepositoryProvider<RecentSearchesStore>.value(value: _recentSearches),
        RepositoryProvider<ImageProcessor>.value(value: widget.imageProcessor),
        RepositoryProvider<GifSource>.value(value: _gifSource),
        RepositoryProvider<GifPreparer>.value(value: widget.gifPreparer),
        RepositoryProvider.value(value: widget.notificationsRepository),
        RepositoryProvider.value(value: widget.messagingRepository),
        RepositoryProvider.value(value: widget.moderationRepository),
        RepositoryProvider.value(value: widget.engagementRepository),
        RepositoryProvider.value(value: widget.bookmarksRepository),
        if (widget.searchRepository != null)
          RepositoryProvider<SearchRepository>.value(
            value: widget.searchRepository!,
          ),
        RepositoryProvider.value(value: widget.likesRepository),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: widget.authBloc),
          BlocProvider.value(value: widget.onboardingBloc),
          BlocProvider.value(value: _pendingPosts),
          BlocProvider.value(value: _engagement),
          if (_polls case final polls?) BlocProvider.value(value: polls),
          BlocProvider.value(value: _bookmarks),
          BlocProvider.value(value: _suggestions),
          if (_trends case final trends?) BlocProvider.value(value: trends),
          BlocProvider.value(value: widget.pushCubit),
          BlocProvider.value(value: _pushOptIn),
          BlocProvider.value(value: widget.unreadBadgeCubit),
          BlocProvider.value(value: _messagesBadge),
          BlocProvider.value(value: _themeMode),
          BlocProvider.value(value: _servicePaused),
        ],
        child: ShareLinksScope(
          links: widget.shareLinks,
          child: BlocBuilder<ThemeModeCubit, ThemeMode>(
            builder: (context, mode) => MaterialApp.router(
              title: 'Dzeroth',
              debugShowCheckedModeBanner: false,
              scaffoldMessengerKey: _messengerKey,
              theme: appLightTheme,
              darkTheme: appDarkTheme,
              themeMode: mode,
              routerConfig: _appRouter.router,
              builder: (context, child) {
                final dark = Theme.of(context).brightness == Brightness.dark;
                final surface = Theme.of(context).colorScheme.surface;
                // The web theme colour and the status-bar icons follow the
                // theme (a top bar that is not an `AppBar` sets neither).
                return Title(
                  title: 'Dzeroth',
                  color: surface,
                  child: AnnotatedRegion<SystemUiOverlayStyle>(
                    value: SystemUiOverlayStyle(
                      statusBarColor: Colors.transparent,
                      statusBarIconBrightness: dark
                          ? Brightness.light
                          : Brightness.dark,
                      statusBarBrightness: dark
                          ? Brightness.dark
                          : Brightness.light,
                    ),
                    child: _PausedOverlay(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [ServicePausedView] over the app while the API is paused (ADR-0022).
/// The app underneath stays mounted (hidden and out of semantics), so the
/// current screen is exactly where it was when the service comes back.
class _PausedOverlay extends StatelessWidget {
  const _PausedOverlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ServicePausedCubit, ServicePauseStatus>(
      builder: (context, status) {
        final paused = status != ServicePauseStatus.running;
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(offstage: paused, child: child),
            if (paused)
              ServicePausedView(
                checking: status == ServicePauseStatus.checking,
                onRetry: () => context.read<ServicePausedCubit>().recheck(),
              ),
          ],
        );
      },
    );
  }
}
