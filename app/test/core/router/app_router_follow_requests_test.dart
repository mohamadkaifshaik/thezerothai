import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/router/app_router.dart';
import 'package:dzeroth/core/theme/theme_mode_cubit.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/suggestions_fixtures.dart' show suggestedUser;

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

class _MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

class _MockGraph extends Mock implements GraphRepository {}

class _NoThemeStore implements ThemeModeStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) async {}
}

/// `/follow-requests` on the real router (W3-34): reachable with `graph` and
/// either `private_accounts` or a protected caller (the undo rule), else Home.
void main() {
  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  Future<String> openAt(
    WidgetTester tester,
    Set<String> flags, {
    required bool protected,
    void Function(_MockGraph graph)? arrange,
    Stream<AuthState> authStates = const Stream<AuthState>.empty(),
  }) async {
    final auth = _MockAuthBloc();
    final onboarding = _MockOnboardingBloc();
    whenListen(
      auth,
      authStates,
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: user,
      ),
    );
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(
          userId: 'uid-1',
          handle: 'me',
          isPrivate: protected,
        ),
        enabledFeatures: flags,
      ),
    );
    final graphRepo = _MockGraph();
    when(
      () => graphRepo.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((_) async => const GraphPage(items: [], nextPageToken: ''));
    arrange?.call(graphRepo);
    final appRouter = AppRouter(authBloc: auth, onboardingBloc: onboarding);
    await tester.pumpWidget(
      RepositoryProvider<GraphRepository>.value(
        value: graphRepo,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<OnboardingBloc>.value(value: onboarding),
            BlocProvider<ThemeModeCubit>(
              create: (_) => ThemeModeCubit(_NoThemeStore()),
            ),
          ],
          child: MaterialApp.router(routerConfig: appRouter.router),
        ),
      ),
    );
    appRouter.router.go(AppRouter.followRequestsPath);
    await tester.pump();
    await tester.pump();
    // The landing page (Home or the requests list) needs repositories this
    // test does not provide; only the location matters here.
    tester.takeException();
    return appRouter.router.routeInformationProvider.value.uri.path;
  }

  final cases = <String, ({Set<String> flags, bool protected, bool stays})>{
    'public caller, private_accounts on': (
      flags: {'graph', 'private_accounts'},
      protected: false,
      stays: true,
    ),
    'protected caller, private_accounts OFF everywhere (undo rule)': (
      flags: {'graph'},
      protected: true,
      stays: true,
    ),
    'public caller, private_accounts off': (
      flags: {'graph'},
      protected: false,
      stays: false,
    ),
    'protected caller, graph off': (
      flags: {'private_accounts'},
      protected: true,
      stays: false,
    ),
    // W3-35c: the other four cells of graph x private_accounts x protected.
    'protected caller, private_accounts on': (
      flags: {'graph', 'private_accounts'},
      protected: true,
      stays: true,
    ),
    'public caller, graph off, private_accounts on': (
      flags: {'private_accounts'},
      protected: false,
      stays: false,
    ),
    'public caller, no flags': (
      flags: <String>{},
      protected: false,
      stays: false,
    ),
    'protected caller, no flags': (
      flags: <String>{},
      protected: true,
      stays: false,
    ),
  };
  // W3-35c: the undo rule end to end. A protected caller with every flag off
  // but `graph` reaches the screen on the real router and answers a request.
  testWidgets('protected caller with private_accounts off: the screen lists '
      'and Accept reaches the server', (tester) async {
    final graphs = <_MockGraph>[];
    final path = await openAt(
      tester,
      {'graph'},
      protected: true,
      arrange: (repo) {
        graphs.add(repo);
        when(
          () => repo.listFollowRequests(
            pageSize: any(named: 'pageSize'),
            pageToken: any(named: 'pageToken'),
          ),
        ).thenAnswer(
          (_) async => GraphPage(items: [suggestedUser(1)], nextPageToken: ''),
        );
        when(
          () => repo.respondToFollowRequest(
            requesterUserId: any(named: 'requesterUserId'),
            accept: any(named: 'accept'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer(
          (_) async => graph.Relationship(
            userId: 'u1',
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
        );
      },
    );
    expect(path, AppRouter.followRequestsPath);
    await tester.pumpAndSettle();
    expect(find.text('@user1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
    await tester.pumpAndSettle();
    verify(
      () => graphs.single.respondToFollowRequest(
        requesterUserId: 'u1',
        accept: true,
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.text('@user1'), findsNothing);
    // "Follow back" comes from the Respond answer: no relationship lookup.
    expect(find.text('Follow back'), findsOneWidget);
    verifyNever(() => graphs.single.relationshipsFor(any()));
    verifyNever(() => graphs.single.relationshipFor(any()));
    verifyNever(() => graphs.single.profileRelationshipFor(any()));
  });

  testWidgets('signing out leaves /follow-requests for sign-in and asks for '
      'no list again', (tester) async {
    final states = StreamController<AuthState>();
    addTearDown(states.close);
    final graphs = <_MockGraph>[];
    final path = await openAt(
      tester,
      {'graph'},
      protected: true,
      authStates: states.stream,
      arrange: graphs.add,
    );
    expect(path, AppRouter.followRequestsPath);
    // The one list the open asked for; `verify` consumes it, so the
    // `verifyNever` below sees only what a signed-out session adds.
    verify(
      () => graphs.single.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    ).called(1);

    states.add(const AuthState(status: AuthStatus.unauthenticated));
    await tester.pump();
    await tester.pump();
    tester.takeException();
    final location =
        (tester.firstWidget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
                as GoRouter)
            .routeInformationProvider
            .value
            .uri
            .path;
    expect(location, AppRouter.signInPath);
    // Nothing of the signed-out session asked for the list again.
    verifyNever(
      () => graphs.single.listFollowRequests(
        pageSize: any(named: 'pageSize'),
        pageToken: any(named: 'pageToken'),
      ),
    );
    verifyNever(
      () => graphs.single.respondToFollowRequest(
        requesterUserId: any(named: 'requesterUserId'),
        accept: any(named: 'accept'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
  });

  for (final entry in cases.entries) {
    testWidgets(
      '${entry.key}: ${entry.value.stays ? 'stays' : 'redirects Home'}',
      (tester) async {
        final path = await openAt(
          tester,
          entry.value.flags,
          protected: entry.value.protected,
        );
        expect(
          path,
          entry.value.stays ? AppRouter.followRequestsPath : AppRouter.homePath,
        );
      },
    );
  }
}
