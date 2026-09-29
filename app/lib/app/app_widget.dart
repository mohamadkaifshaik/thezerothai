import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/router/app_router.dart';
import '../core/theme/app_theme.dart';
import '../features/auth/presentation/bloc/auth_bloc.dart';
import '../features/graph/data/graph_repository.dart';
import '../features/onboarding/data/identity_repository.dart';
import '../features/onboarding/presentation/bloc/onboarding_bloc.dart';

/// Root widget: theme + `go_router`. All dependency wiring happens in
/// `bootstrap.dart`; this widget only assembles what it's given.
class AppWidget extends StatefulWidget {
  const AppWidget({
    super.key,
    required this.authBloc,
    required this.onboardingBloc,
    required this.identityRepository,
    required this.graphRepository,
  });

  final AuthBloc authBloc;
  final OnboardingBloc onboardingBloc;
  final IdentityRepository identityRepository;
  final GraphRepository graphRepository;

  @override
  State<AppWidget> createState() => _AppWidgetState();
}

class _AppWidgetState extends State<AppWidget> {
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
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider.value(value: widget.authBloc),
          BlocProvider.value(value: widget.onboardingBloc),
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
