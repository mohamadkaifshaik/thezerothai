import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/presentation/widgets/follow_requests_row.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The "Follow requests" row (title and count badge) at the top of
/// Notifications, in the matrix and under the shared visibility rule.
void main() {
  var visited = <String>[];

  Future<void> pump(
    WidgetTester tester,
    MatrixEnv env, {
    Set<String> flags = const {'graph'},
    bool isProtected = true,
    int pending = 3,
    bool backedOff = false,
    bool rtl = false,
  }) async {
    visited = [];
    final onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        pendingFollowRequestCount: pending,
        enabledFeatures: flags,
        profile: identity.Profile(
          userId: 'me',
          handle: 'me',
          isPrivate: isProtected,
        ),
      ),
    );
    final graphRepo = _MockGraph();
    when(() => graphRepo.followRequestsUnavailable).thenReturn(backedOff);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: FollowRequestsRow()),
        ),
        GoRoute(
          path: '/follow-requests',
          builder: (context, state) {
            visited.add('/follow-requests');
            return const Scaffold(body: Text('requests page'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = env.size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graphRepo,
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: MediaQuery(
            data: MediaQueryData(
              size: env.size,
              textScaler: TextScaler.linear(env.textScale),
            ),
            child: MaterialApp.router(
              theme: buildAppTheme(brightness: env.brightness),
              routerConfig: router,
              builder: (context, child) => Directionality(
                textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                child: child!,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  forEachThemeAndWidth(
    'the row is 48dp, inside the screen, spoken, and opens /follow-requests',
    (tester, env) async {
      await pump(tester, env, pending: 7);
      expect(tester.takeException(), isNull);
      final row = find.byKey(const ValueKey('notifications-follow-requests'));
      // R8: the title and the count are two texts (the count in a badge).
      expect(find.text('Follow requests'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Follow requests, 7 pending'),
        findsOneWidget,
      );
      expectMinTarget(tester, row);
      expectInsideHorizontally(tester, row, env.size.width);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(visited, ['/follow-requests']);
    },
    textScales: kMatrixTextScalesLarge,
  );

  const env = MatrixEnv(
    brightness: Brightness.light,
    size: Size(600, 800),
    textScale: 1,
  );

  testWidgets('1000+ at the server cap', (tester) async {
    await pump(tester, env, pending: 1000);
    expect(find.text('1000+'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Follow requests, 1000 or more pending'),
      findsOneWidget,
    );
  });

  testWidgets('nothing pending: no row, whatever the rule says', (
    tester,
  ) async {
    await pump(tester, env, pending: 0);
    expect(find.textContaining('Follow requests'), findsNothing);
  });

  testWidgets('a public caller with private_accounts off and a stale count '
      'sees no row', (tester) async {
    await pump(tester, env, isProtected: false, pending: 3);
    expect(find.textContaining('Follow requests'), findsNothing);
  });

  testWidgets('hidden while ListFollowRequests is backed off', (tester) async {
    await pump(tester, env, backedOff: true);
    expect(find.textContaining('Follow requests'), findsNothing);
  });

  testWidgets('RTL: the tile leads on the right and the chevron points '
      'away from it (mirrored once, by the icon itself)', (tester) async {
    await pump(tester, env, pending: 2, rtl: true);
    final row = find.byKey(const ValueKey('notifications-follow-requests'));
    final title = tester.getRect(find.text('Follow requests'));
    final chevron = tester.getRect(find.byIcon(Icons.chevron_right));
    expect(chevron.right, lessThan(title.left));
    expect(tester.getRect(row).right - title.right, greaterThan(40));
    expectNoOverflow(tester);
  });
}
