import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/communities/data/communities_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'theme_harness.dart';

/// Mounts [routes] under a real [GoRouter] (so `context.push` works) with the
/// Plans repositories provided, at [env]'s theme, size and text scale.
/// Returns the router for location assertions.
Future<GoRouter> pumpPlansRouter(
  WidgetTester tester, {
  required BeaconsRepository beacons,
  CommunitiesRepository? communities,
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
  await tester.pumpWidget(
    MultiRepositoryProvider(
      providers: [
        RepositoryProvider<BeaconsRepository>.value(value: beacons),
        if (communities != null)
          RepositoryProvider<CommunitiesRepository>.value(value: communities),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(brightness: env?.brightness ?? Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// A stub page for a route the test only navigates to.
Widget stubPage(String text) => Scaffold(
  body: Center(child: Text(text, key: ValueKey('stub:$text'))),
);
