import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/moderation/data/moderation_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'theme_harness.dart';

class FakeOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// [child] under an `OnboardingBloc` whose `enabled_features` is [features];
/// each set [changes] emits replaces it, as a fresh `GetMe` would. Call it
/// inside a test: the bloc is closed on tear-down.
Widget withPlansFeatures(
  Widget child,
  Set<String> features, {
  Stream<Set<String>>? changes,
}) {
  OnboardingState ready(Set<String> set) =>
      OnboardingState(status: OnboardingStatus.ready, enabledFeatures: set);
  final onboarding = FakeOnboardingBloc();
  whenListen(
    onboarding,
    changes?.map(ready) ?? const Stream<OnboardingState>.empty(),
    initialState: ready(features),
  );
  addTearDown(onboarding.close);
  return BlocProvider<OnboardingBloc>.value(value: onboarding, child: child);
}

/// Mounts [routes] under a real [GoRouter] (so `context.push` works) with the
/// Plans repositories provided, at [env]'s theme, size and text scale.
/// [features] provides an `OnboardingBloc` whose `enabled_features` is that
/// set (null: no bloc, for screens that read no flag); each set
/// [featureChanges] emits replaces it, as a fresh `GetMe` would. Returns the
/// router for location assertions.
Future<GoRouter> pumpPlansRouter(
  WidgetTester tester, {
  required BeaconsRepository beacons,
  CommunitiesRepository? communities,
  GraphRepository? graph,
  ModerationRepository? moderation,
  MessagingRepository? messaging,
  Set<String>? features,
  Stream<Set<String>>? featureChanges,
  required List<GoRoute> routes,
  String initialLocation = '/plans',
  MatrixEnv? env,
}) async {
  final router = GoRouter(initialLocation: initialLocation, routes: routes);
  addTearDown(router.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = env?.size ?? const Size(360, 800);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = env?.textScale ?? 1.0;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  Widget app = MaterialApp.router(
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(brightness: env?.brightness ?? Brightness.light),
    routerConfig: router,
  );
  if (features != null) {
    app = withPlansFeatures(app, features, changes: featureChanges);
  }
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<BeaconsRepository>.value(value: beacons),
        RepositoryProvider<UnexpectedErrorReporter>.value(value: (_, _) {}),
        if (communities != null)
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
        if (graph != null)
          RepositoryProvider<GraphRepository>.value(value: graph),
        if (moderation != null)
          RepositoryProvider<ModerationRepository>.value(value: moderation),
        if (messaging != null)
          RepositoryProvider<MessagingRepository>.value(value: messaging),
      ],
      child: app,
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// A stub page for a route the test only navigates to.
Widget stubPage(String text) => Scaffold(
  body: Center(child: Text(text, key: ValueKey('stub:$text'))),
);
