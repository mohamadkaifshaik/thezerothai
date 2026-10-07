import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/router/app_router.dart';
import '../core/theme/app_theme.dart';
import '../features/account/data/account_repository.dart';
import 'session_wiring.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/bloc/auth_bloc.dart';
import '../features/auth/presentation/bloc/auth_state.dart';
import '../features/graph/data/graph_repository.dart';
import '../features/onboarding/data/identity_repository.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';
import '../features/posts/data/posts_repository.dart';
import '../features/posts/domain/posts_feature_flag.dart';
import '../features/posts/presentation/bloc/pending_posts_cubit.dart';
import '../features/timeline/data/timeline_repository.dart';

/// Root widget: theme + `go_router`. All dependency wiring happens in
/// `bootstrap.dart`; this widget only assembles what it's given.
class AppWidget extends StatefulWidget {
  const AppWidget({
    super.key,
    required this.authBloc,
    required this.onboardingBloc,
    required this.identityRepository,
    required this.graphRepository,
    required this.postsRepository,
    required this.timelineRepository,
    required this.postsGate,
    required this.accountRepository,
    required this.authRepository,
  });

  final AuthBloc authBloc;
  final OnboardingBloc onboardingBloc;
  final IdentityRepository identityRepository;
  final GraphRepository graphRepository;
  final PostsRepository postsRepository;
  final TimelineRepository timelineRepository;
  final PostsFeatureGate postsGate;
  final AccountRepository accountRepository;
  final AuthRepository authRepository;

  @override
  State<AppWidget> createState() => _AppWidgetState();
}

class _AppWidgetState extends State<AppWidget> {
  // Optimistic posts live for the session only (T16); sign-out drops them.
  final PendingPostsCubit _pendingPosts = PendingPostsCubit();
  late final StreamSubscription<AuthState> _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = widget.authBloc.stream.listen((state) {
      if (state.status == AuthStatus.unauthenticated) _pendingPosts.clear();
    });
  }

  @override
  void dispose() {
    _authSub.cancel();
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
        RepositoryProvider.value(value: widget.postsRepository),
        RepositoryProvider.value(value: widget.timelineRepository),
        RepositoryProvider.value(value: widget.postsGate),
        RepositoryProvider.value(value: widget.accountRepository),
        RepositoryProvider<UnexpectedErrorReporter>.value(
          value: reportUnexpectedError,
        ),
        RepositoryProvider.value(value: widget.authRepository),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: widget.authBloc),
          BlocProvider.value(value: widget.onboardingBloc),
          BlocProvider.value(value: _pendingPosts),
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
