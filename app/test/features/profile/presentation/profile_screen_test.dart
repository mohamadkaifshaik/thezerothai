import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/domain/profile_edit_feature_flag.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/features/profile/presentation/widgets/profile_header.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

class MockGraphRepository extends Mock implements GraphRepository {}

class MockOnboardingBloc extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

void main() {
  late MockIdentityRepository identityRepository;
  late MockGraphRepository graphRepository;
  late MockOnboardingBloc onboardingBloc;

  setUp(() {
    identityRepository = MockIdentityRepository();
    graphRepository = MockGraphRepository();
    when(() => graphRepository.cached(any())).thenReturn(null);
    onboardingBloc = MockOnboardingBloc();
  });

  Widget wrap({String handle = 'kaif'}) {
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<IdentityRepository>.value(value: identityRepository),
        RepositoryProvider<GraphRepository>.value(value: graphRepository),
      ],
      child: BlocProvider<OnboardingBloc>.value(
        value: onboardingBloc,
        child: MaterialApp(home: ProfileScreen(handle: handle)),
      ),
    );
  }

  testWidgets('shows a loading indicator, then the profile', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(
        userId: 'target-uid',
        handle: 'kaif',
        displayName: 'Kaif',
      ),
    );

    await tester.pumpWidget(wrap());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(ProfileHeader),
        matching: find.text('Kaif'),
      ),
      findsOneWidget,
    );
    // No graph UI at all: the flag is off.
    expect(find.text('Follow'), findsNothing);
  });

  testWidgets('own profile: no FollowButton, no overflow menu', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'graph'},
        profile: identity.Profile(userId: 'viewer-uid', handle: 'kaif'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'viewer-uid', handle: 'kaif'),
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Follow'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    verifyNever(() => graphRepository.relationshipFor(any()));
  });

  testWidgets('own profile: "Edit profile" only with the profile_snapshot '
      'flag on', (tester) async {
    Future<void> openOwn(Set<String> features) async {
      whenListen(
        onboardingBloc,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          enabledFeatures: features,
          profile: identity.Profile(userId: 'viewer-uid', handle: 'kaif'),
        ),
      );
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(userId: 'viewer-uid', handle: 'kaif'),
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
    }

    await openOwn(const {});
    expect(find.text('Edit profile'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await openOwn({kFeatureProfileSnapshot});
    expect(find.text('Edit profile'), findsOneWidget);
  });

  testWidgets(
    'a saved edit shows the returned profile without another GetProfile',
    (tester) async {
      whenListen(
        onboardingBloc,
        const Stream<OnboardingState>.empty(),
        initialState: OnboardingState(
          enabledFeatures: const {kFeatureProfileSnapshot},
          profile: identity.Profile(userId: 'viewer-uid', handle: 'kaif'),
        ),
      );
      when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
        (_) async => identity.Profile(
          userId: 'viewer-uid',
          handle: 'kaif',
          displayName: 'Old name',
        ),
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const ProfileScreen(handle: 'kaif'),
          ),
          GoRoute(
            path: '/settings/profile',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () => context.pop(
                  identity.Profile(
                    userId: 'viewer-uid',
                    handle: 'kaif',
                    displayName: 'New name',
                  ),
                ),
                child: const Text('finish edit'),
              ),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<IdentityRepository>.value(
              value: identityRepository,
            ),
            RepositoryProvider<GraphRepository>.value(value: graphRepository),
          ],
          child: BlocProvider<OnboardingBloc>.value(
            value: onboardingBloc,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(ProfileHeader),
          matching: find.text('Old name'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Edit profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('finish edit'));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(ProfileHeader),
          matching: find.text('New name'),
        ),
        findsOneWidget,
      );
      expect(find.text('Old name'), findsNothing);
      verify(() => identityRepository.getProfile(handle: 'kaif')).called(1);
    },
  );

  testWidgets('other profile: never shows "Edit profile"', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: {kFeatureProfileSnapshot},
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Edit profile'), findsNothing);
  });

  testWidgets('other profile with the flag on: shows Follow', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'graph'},
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
    );
    when(() => graphRepository.relationshipFor('target-uid')).thenAnswer(
      (_) async => graph.Relationship(
        userId: 'target-uid',
        followState: graph.FollowState.FOLLOW_STATE_NONE,
      ),
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('the flag off: no graph UI, even for another profile', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Follow'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    verifyNever(() => graphRepository.relationshipFor(any()));
  });

  testWidgets('wide screens cap the profile column to the feed width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(
        userId: 'target-uid',
        handle: 'kaif',
        displayName: 'Kaif',
      ),
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(ProfileHeader)).width,
      AppBreakpoints.mobile,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a blocking relationship shows the "You blocked" banner and '
      'hides the counts links', (tester) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'graph'},
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
    );
    when(() => graphRepository.relationshipFor('target-uid')).thenAnswer(
      (_) async => graph.Relationship(userId: 'target-uid', blocking: true),
    );

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('You blocked @kaif'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
    expect(find.text('Following'), findsNothing);
  });

  testWidgets('NOT_FOUND shows the generic "doesn\'t exist" view', (
    tester,
  ) async {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: const OnboardingState(),
    );
    when(() => identityRepository.getProfile(handle: 'ghost'))
        .thenThrow(const NotFoundException('server text, never shown'));

    await tester.pumpWidget(wrap(handle: 'ghost'));
    await tester.pumpAndSettle();

    expect(find.text("This account doesn't exist."), findsOneWidget);
    expect(find.text('server text, never shown'), findsNothing);
  });

  // T17 sweep: block/mute affordances of ProfileHeader (overflow menu, confirmation dialog, banner Unblock).
  void arrangeOtherProfile({bool blocking = false}) {
    whenListen(
      onboardingBloc,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        enabledFeatures: const {'graph'},
        profile: identity.Profile(userId: 'viewer-uid', handle: 'viewer'),
      ),
    );
    when(() => identityRepository.getProfile(handle: 'kaif')).thenAnswer(
      (_) async => identity.Profile(userId: 'target-uid', handle: 'kaif'),
    );
    when(() => graphRepository.relationshipFor('target-uid')).thenAnswer(
      (_) async => graph.Relationship(
        userId: 'target-uid',
        followState: graph.FollowState.FOLLOW_STATE_NONE,
        blocking: blocking,
      ),
    );
  }

  testWidgets('Block asks for confirmation; Cancel never calls the API', (
    tester,
  ) async {
    arrangeOtherProfile();
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(find.text('Block this account?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    verifyNever(
      () => graphRepository.block(
        userId: any(named: 'userId'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
    expect(find.textContaining('You blocked'), findsNothing);
  });

  testWidgets('confirming Block calls the API and shows the banner', (
    tester,
  ) async {
    arrangeOtherProfile();
    when(
      () => graphRepository.block(
        userId: 'target-uid',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer(
      (_) async => graph.Relationship(userId: 'target-uid', blocking: true),
    );
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pumpAndSettle();

    verify(
      () => graphRepository.block(
        userId: 'target-uid',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.textContaining('You blocked @kaif'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);
  });

  testWidgets('the banner Unblock button unblocks and restores Follow', (
    tester,
  ) async {
    arrangeOtherProfile(blocking: true);
    when(
      () => graphRepository.unblock(
        userId: 'target-uid',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => graph.Relationship(userId: 'target-uid'));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Unblock'));
    await tester.pumpAndSettle();

    verify(
      () => graphRepository.unblock(
        userId: 'target-uid',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(find.textContaining('You blocked'), findsNothing);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('the overflow menu Mute calls the API', (tester) async {
    arrangeOtherProfile();
    when(
      () => graphRepository.mute(
        userId: 'target-uid',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer(
      (_) async => graph.Relationship(userId: 'target-uid', muting: true),
    );
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mute'));
    await tester.pumpAndSettle();

    verify(
      () => graphRepository.mute(
        userId: 'target-uid',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
  });
}
