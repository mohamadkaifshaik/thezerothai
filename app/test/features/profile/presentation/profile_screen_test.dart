import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/features/profile/presentation/profile_screen.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
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

    expect(find.text('Kaif'), findsOneWidget);
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
}
