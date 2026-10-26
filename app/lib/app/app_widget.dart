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
import '../features/engagement/presentation/bloc/bookmarks_cubit.dart';
import '../features/engagement/presentation/bloc/engagement_cubit.dart';
import '../features/graph/data/graph_repository.dart';
import '../features/media/data/image_picker_service.dart';
import '../features/media/data/media_repository.dart';
import '../features/media/domain/image_processor.dart';
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
import '../features/posts/data/posts_repository.dart';
import '../features/posts/domain/posts_feature_flag.dart';
import '../features/posts/presentation/bloc/pending_posts_cubit.dart';
import '../features/timeline/data/timeline_repository.dart';
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
    required this.accountRepository,
    required this.authRepository,
    required this.database,
    required this.postsRepository,
    required this.timelineRepository,
    required this.postsGate,
    required this.mediaRepository,
    this.imagePicker,
    this.imageProcessor = const IsolateImageProcessor(),
    required this.notificationsRepository,
    required this.moderationRepository,
    required this.engagementRepository,
    required this.bookmarksRepository,
    required this.pushCubit,
    required this.unreadBadgeCubit,
    this.servicePausedCubit,
    this.shareLinks,
  });

  final AuthBloc authBloc;
  final OnboardingBloc onboardingBloc;
  final IdentityRepository identityRepository;
  final GraphRepository graphRepository;
  final AccountRepository accountRepository;
  final AuthRepository authRepository;
  final AppDatabase database;
  final PostsRepository postsRepository;
  final TimelineRepository timelineRepository;
  final PostsFeatureGate postsGate;
  final NotificationsRepository notificationsRepository;
  final ModerationRepository moderationRepository;

  /// Likes, reposts and quotes (P5, `FEATURE_ENGAGEMENT`).
  final EngagementRepository engagementRepository;

  /// Bookmarks (W2-6, `FEATURE_BOOKMARKS`): the session overlay and
  /// Add / RemoveBookmark.
  final BookmarksRepository bookmarksRepository;

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
  // The session's bookmark overlay (W2-6); sign-out forgets it. The toast's
  // "View" opens the Bookmarks screen (W2-7).
  late final BookmarksCubit _bookmarks = BookmarksCubit(
    repository: widget.bookmarksRepository,
    viewRoute: AppRouter.bookmarksPath,
  );
  // The "Turn on notifications" card's memory (W2-12): one "Not now" per
  // account for Home and Notifications; keyed by the signed-in uid.
  // The store is also provided to the tree: Delete account forgets the
  // deleted uid's record there (W2-14 L-6).
  late final PushOptInStore _pushOptInStore = DatabasePushOptInStore(
    widget.database,
  );
  late final PushOptInCubit _pushOptIn = PushOptInCubit(
    store: _pushOptInStore,
    push: widget.pushCubit,
  );
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
  late final StreamSubscription<OnboardingState> _onboardingSub;
  Set<String>? _lastFeatures;
  int _lastUnread = 0;

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
        _bookmarks.reset();
        widget.unreadBadgeCubit.seed(0);
        _lastFeatures = null;
        _lastUnread = 0;
        unawaited(widget.pushCubit.stop());
      }
    });
    unawaited(_pushOptIn.load(widget.authBloc.state.user?.uid));
    widget.pushCubit.onOpen = (location) => _appRouter.router.push(location);
    widget.pushCubit.onForeground = _onForegroundPush;
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

  void _onOnboarding(OnboardingState state) {
    if (state.status != OnboardingStatus.ready) return;
    // A fresh GetMe changes the flag set or the unread count. Compared by
    // value: the state hands out a new set view on every read, so identity
    // would re-seed (and undo a local mark-seen) on any later emission.
    final last = _lastFeatures;
    if (last != null &&
        setEquals(last, state.enabledFeatures) &&
        _lastUnread == state.unreadNotificationCount) {
      return;
    }
    _lastFeatures = Set.of(state.enabledFeatures);
    _lastUnread = state.unreadNotificationCount;
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
    _bookmarks.close();
    _themeMode.close();
    _pushOptIn.close();
    super.dispose();
  }

  late final AppRouter _appRouter = AppRouter(
    authBloc: widget.authBloc,
    onboardingBloc: widget.onboardingBloc,
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
        RepositoryProvider<UnexpectedErrorReporter>.value(
          value: reportUnexpectedError,
        ),
        RepositoryProvider.value(value: widget.postsRepository),
        RepositoryProvider.value(value: widget.timelineRepository),
        RepositoryProvider.value(value: widget.mediaRepository),
        RepositoryProvider<ImagePickerService>.value(value: _imagePicker),
        RepositoryProvider<ImageProcessor>.value(value: widget.imageProcessor),
        RepositoryProvider.value(value: widget.notificationsRepository),
        RepositoryProvider.value(value: widget.moderationRepository),
        RepositoryProvider.value(value: widget.engagementRepository),
        RepositoryProvider.value(value: widget.bookmarksRepository),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: widget.authBloc),
          BlocProvider.value(value: widget.onboardingBloc),
          BlocProvider.value(value: _pendingPosts),
          BlocProvider.value(value: _engagement),
          BlocProvider.value(value: _bookmarks),
          BlocProvider.value(value: widget.pushCubit),
          BlocProvider.value(value: _pushOptIn),
          BlocProvider.value(value: widget.unreadBadgeCubit),
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
