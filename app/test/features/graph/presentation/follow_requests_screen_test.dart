import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/graph/presentation/follow_requests_screen.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/shared/widgets/protected_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/geometry.dart';
import '../../../support/suggestions_fixtures.dart' show suggestedUser;
import '../../../support/theme_harness.dart';

class _MockGraph extends Mock implements GraphRepository {}

class _MockOnboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// W3-34: the Follow requests screen.
void main() {
  late _MockGraph graphRepo;
  late _MockOnboarding onboarding;

  setUpAll(
    () => registerFallbackValue(const OnboardingFollowRequestAnswered()),
  );

  setUp(() {
    graphRepo = _MockGraph();
    onboarding = _MockOnboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(status: OnboardingStatus.ready),
    );
  });

  graph.UserListItem request(int i, {bool isPrivate = false, String? name}) {
    final item = suggestedUser(i);
    item.user.isPrivate = isPrivate;
    if (name != null) item.user.displayName = name;
    return item;
  }

  void stubList(List<GraphPage> pages) {
    var next = 0;
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => pages[next < pages.length ? next++ : next - 1]);
  }

  void stubRespond({
    graph.FollowState state = graph.FollowState.FOLLOW_STATE_NONE,
    Object? error,
    Completer<void>? gate,
  }) {
    when(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: any(named: 'requesterUserId'),
        accept: any(named: 'accept'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) async {
      await gate?.future;
      if (error != null) throw error;
      return graph.Relationship(
        userId: invocation.namedArguments[#requesterUserId] as String,
        followState: state,
      );
    });
  }

  Future<void> open(WidgetTester tester, {MatrixEnv? env}) async {
    await pumpThemed(
      tester,
      MultiRepositoryProvider(
        providers: [
          RepositoryProvider<GraphRepository>.value(value: graphRepo),
        ],
        child: BlocProvider<OnboardingBloc>.value(
          value: onboarding,
          child: const FollowRequestsScreen(),
        ),
      ),
      brightness: env?.brightness ?? Brightness.light,
      size: env?.size ?? const Size(360, 800),
      textScale: env?.textScale ?? 1.0,
      useScaffold: false,
    );
  }

  GraphPage page(List<graph.UserListItem> items, [String token = '']) =>
      GraphPage(items: items, nextPageToken: token);

  forEachThemeAndWidth('rows fit, keep 48dp targets and a long name', (
    tester,
    env,
  ) async {
    stubList([
      page([
        request(
          1,
          isPrivate: true,
          name:
              'A very long display name that would fill the whole row and more',
        ),
        request(2),
      ]),
    ]);
    final semantics = tester.ensureSemantics();
    await open(tester, env: env);

    expectNoOverflow(tester);
    expect(find.text('Follow requests'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Accept'), findsNWidgets(2));
    expect(find.widgetWithText(OutlinedButton, 'Decline'), findsNWidgets(2));
    expect(find.byType(ProtectedBadge), findsWidgets);
    for (final finder in [
      find.byType(FilledButton),
      find.byType(OutlinedButton),
    ]) {
      for (var i = 0; i < 2; i++) {
        expectMinTarget(tester, finder.at(i));
        expectInsideHorizontally(tester, finder.at(i), env.size.width);
      }
    }
    expect(
      find.bySemanticsLabel('Accept follow request from @user1'),
      findsOneWidget,
    );
    semantics.dispose();
  }, textScales: kMatrixTextScalesLarge);

  testWidgets('shows the empty state', (tester) async {
    stubList([page(const [])]);
    await open(tester);
    expect(find.text('No follow requests'), findsOneWidget);
  });

  testWidgets('shows an error with Retry that reloads page 1', (tester) async {
    var calls = 0;
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async {
      if (calls++ == 0) throw const NetworkException('offline');
      return page([request(1)]);
    });
    await open(tester);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('@user1'), findsOneWidget);
  });

  testWidgets('FEATURE_DISABLED shows a calm unavailable state, no retry', (
    tester,
  ) async {
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(const FeatureDisabledException('off'));
    await open(tester);
    expect(
      find.text("Follow requests aren't available right now"),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('pages 25 requests as 20 then 5 without duplicates', (
    tester,
  ) async {
    stubList([
      page([for (var i = 1; i <= 20; i++) request(i)], 'next=='),
      page([for (var i = 21; i <= 25; i++) request(i)]),
    ]);
    await open(tester);
    expect(find.text('@user1'), findsOneWidget);

    await tester.dragUntilVisible(
      find.text('@user20'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('@user25'),
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    verify(() => graphRepo.listFollowRequests(pageSize: 20, pageToken: ''))
        .called(1);
    verify(
      () => graphRepo.listFollowRequests(pageSize: 20, pageToken: 'next=='),
    ).called(1);
    expect(find.text('@user25'), findsOneWidget);
    expect(find.text('@user24'), findsOneWidget); // each row once
  });

  testWidgets('Accept removes the row at once, then offers Follow back', (
    tester,
  ) async {
    stubList([
      page([request(1), request(2)]),
    ]);
    final gate = Completer<void>();
    stubRespond(gate: gate);
    when(
      () => graphRepo.follow(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => graph.Relationship(userId: 'u1'));
    await open(tester);

    await tester.tap(
      find.bySemanticsLabel('Accept follow request from @user1'),
    );
    await tester.pump();
    // Optimistic: gone before the server answered.
    expect(find.text('@user1'), findsNothing);
    expect(find.text('@user2'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('@user1 can now see your posts.'), findsOneWidget);
    // No undo (founder answer B3).
    expect(find.text('Undo'), findsNothing);
    verify(
      () => onboarding.add(any(that: isA<OnboardingFollowRequestAnswered>())),
    ).called(1);

    await tester.tap(find.text('Follow back'));
    await tester.pumpAndSettle();
    verify(
      () => graphRepo.follow(
        userId: 'u1',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
  });

  testWidgets('no Follow back when the caller already follows them', (
    tester,
  ) async {
    stubList([
      page([request(1)]),
    ]);
    stubRespond(state: graph.FollowState.FOLLOW_STATE_FOLLOWING);
    await open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();
    expect(find.text('Accepted @user1.'), findsOneWidget);
    expect(find.text('Follow back'), findsNothing);
  });

  testWidgets('Decline removes the row, says so, has no undo', (tester) async {
    stubList([
      page([request(1)]),
    ]);
    stubRespond();
    await open(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Decline'));
    await tester.pumpAndSettle();
    expect(find.text('@user1'), findsNothing);
    expect(find.text('Declined @user1.'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    verify(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: 'u1',
        accept: false,
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
  });

  testWidgets('a failed answer restores the row and a retry reuses its key', (
    tester,
  ) async {
    stubList([
      page([request(1)]),
    ]);
    stubRespond(error: const NetworkException('offline'));
    await open(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();
    expect(find.text('@user1'), findsOneWidget); // back
    expect(
      find.text('No connection. Check your network and try again.'),
      findsOneWidget,
    );
    verifyNever(
      () => onboarding.add(any(that: isA<OnboardingFollowRequestAnswered>())),
    );

    // Retry the same answer: the same idempotency key (a replay is safe).
    stubRespond();
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();
    final keys = verify(
      () => graphRepo.respondToFollowRequest(
        requesterUserId: 'u1',
        accept: true,
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
    expect(find.text('@user1'), findsNothing);
  });

  testWidgets('a requester over the following cap explains, row returns', (
    tester,
  ) async {
    stubList([
      page([request(1)]),
    ]);
    stubRespond(
      error: const LimitReachedException('x', quota: 'requester_following'),
    );
    await open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();
    expect(find.textContaining('You can still decline'), findsOneWidget);
    expect(find.text('@user1'), findsOneWidget);
  });

  testWidgets('Accept is not gated by anything but the server', (tester) async {
    stubList([
      page([request(1)]),
    ]);
    stubRespond();
    await open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();
    expect(find.text('@user1'), findsNothing);
    verifyNever(
      () => graphRepo.listFollowRequests(pageSize: 20, pageToken: 'x'),
    );
  });
}
