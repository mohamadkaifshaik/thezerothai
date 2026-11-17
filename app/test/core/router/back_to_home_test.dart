import 'dart:async';

import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/router/back_to_home.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: [
    GoRoute(
      path: AppRouter.homePath,
      builder: (_, _) => const BackToHome(enabled: false, child: Text('home')),
    ),
    GoRoute(
      path: AppRouter.listsPath,
      builder: (_, _) => const BackToHome(enabled: true, child: Text('lists')),
      routes: [
        GoRoute(path: 'detail', builder: (_, _) => const Text('detail')),
      ],
    ),
  ],
);

Future<GoRouter> _pump(WidgetTester tester, String initial) async {
  final router = _router(initial);
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('back from a go-reached screen lands on Home', (tester) async {
    final router = await _pump(tester, AppRouter.listsPath);
    expect(find.text('lists'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(find.text('home'), findsOneWidget);
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      AppRouter.homePath,
    );
  });

  testWidgets('back on Home is not handled, so the app exits', (tester) async {
    await _pump(tester, AppRouter.homePath);

    final handled = await tester.binding.handlePopRoute();

    expect(handled, isFalse);
  });

  testWidgets('a page pushed over the screen pops first, then Home', (
    tester,
  ) async {
    final router = await _pump(tester, AppRouter.listsPath);
    unawaited(router.push('${AppRouter.listsPath}/detail'));
    await tester.pumpAndSettle();
    expect(find.text('detail'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('lists'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
}
