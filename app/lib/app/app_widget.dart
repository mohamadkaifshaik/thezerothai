import 'dart:async';

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/router/app_router.dart';
import '../core/storage/app_database.dart';
import '../core/theme/app_theme.dart';
import '../features/account/data/account_repository.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/bloc/auth_bloc.dart';
import '../features/auth/presentation/bloc/auth_state.dart';
import '../features/graph/data/graph_repository.dart';
import '../features/moderation/data/moderation_repository.dart';
import '../features/notifications/data/notifications_repository.dart';
import '../features/notifications/domain/notifications_feature_flag.dart';
import '../features/notifications/presentation/bloc/push_cubit.dart';
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
    required this.notificationsRepository,
    required this.moderationRepository,
    required this.pushCubit,
    required this.unreadBadgeCubit,
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

  /// Push registration and tap handling (P6); built in bootstrap so the
  /// sign-out hook can unregister the device before the token is dropped.
  final PushCubit pushCubit;

  /// The unread badge, seeded from `GetMe` (P6).
  final UnreadBadgeCubit unreadBadgeCubit;

  @override
  State<AppWidget> createState() => _AppWidgetState();
}

class _AppWidgetState extends State<AppWidget> {
  // Optimistic posts live for the session only (T16); sign-out drops them.
  final PendingPostsCubit _pendingPosts = PendingPostsCubit();
  late final StreamSubscription<AuthState> _authSub;
  late final StreamSubscription<OnboardingState> _onboardingSub;
  Set<String>? _lastFeatures;
  int _lastUnread = 0;

  @override
  void initState() {
    super.initState();
    _authSub = widget.authBloc.stream.listen((state) {
      if (state.status == AuthStatus.unauthenticated) {
        _pendingPosts.clear();
        widget.unreadBadgeCubit.seed(0);
        _lastFeatures = null;
        _lastUnread = 0;
        unawaited(widget.pushCubit.stop());
      }
    });
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
        RepositoryProvider<UnexpectedErrorReporter>.value(
          value: reportUnexpectedError,
        ),
        RepositoryProvider.value(value: widget.postsRepository),
        RepositoryProvider.value(value: widget.timelineRepository),
        RepositoryProvider.value(value: widget.notificationsRepository),
        RepositoryProvider.value(value: widget.moderationRepository),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: widget.authBloc),
          BlocProvider.value(value: widget.onboardingBloc),
          BlocProvider.value(value: _pendingPosts),
          BlocProvider.value(value: widget.pushCubit),
          BlocProvider.value(value: widget.unreadBadgeCubit),
        ],
        child: MaterialApp.router(
          title: 'dZeroth',
          debugShowCheckedModeBanner: false,
          theme: appLightTheme,
          darkTheme: appDarkTheme,
          themeMode: ThemeMode.system,
          routerConfig: _appRouter.router,
        ),
      ),
    );
  }
}
