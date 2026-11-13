import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/domain/handle_rules.dart'
    show HandleCheckStatus;
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements IdentityRepository {}

/// `photoStepPending`: set by this session's CreateProfile when `media` is
/// on, never by a warm start, cleared by finishing or skipping the step.
void main() {
  late _MockRepo repo;

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  final profile = identity.Profile(userId: 'uid-1', handle: 'kaif');

  setUp(() {
    repo = _MockRepo();
    when(() => repo.cachedOwnProfile(any())).thenAnswer((_) async => null);
    when(
      () => repo.createProfile(
        handle: any(named: 'handle'),
        displayName: any(named: 'displayName'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => profile);
  });

  OnboardingBloc build() => OnboardingBloc(identityRepository: repo);

  const seed = OnboardingState(
    handle: 'kaif',
    displayName: 'Kaif',
    handleCheckStatus: HandleCheckStatus.available,
  );

  blocTest<OnboardingBloc, OnboardingState>(
    'CreateProfile with media on: the step is pending',
    setUp: () => when(() => repo.getMe()).thenAnswer(
      (_) async => identity.GetMeResponse(
        profile: profile,
        enabledFeatures: ['media', 'graph'],
      ),
    ),
    build: build,
    seed: () => seed,
    act: (b) => b.add(const OnboardingProfileSubmitted()),
    verify: (b) {
      expect(b.state.status, OnboardingStatus.ready);
      expect(b.state.photoStepPending, isTrue);
    },
  );

  blocTest<OnboardingBloc, OnboardingState>(
    'CreateProfile with media off: no step',
    setUp: () => when(() => repo.getMe()).thenAnswer(
      (_) async =>
          identity.GetMeResponse(profile: profile, enabledFeatures: ['graph']),
    ),
    build: build,
    seed: () => seed,
    act: (b) => b.add(const OnboardingProfileSubmitted()),
    verify: (b) {
      expect(b.state.status, OnboardingStatus.ready);
      expect(b.state.photoStepPending, isFalse);
    },
  );

  blocTest<OnboardingBloc, OnboardingState>(
    'a warm start (GetMe with a profile, no create) never shows the step',
    setUp: () => when(() => repo.getMe()).thenAnswer(
      (_) async =>
          identity.GetMeResponse(profile: profile, enabledFeatures: ['media']),
    ),
    build: build,
    act: (b) => b.add(const OnboardingUserAuthenticated(user)),
    verify: (b) {
      expect(b.state.status, OnboardingStatus.ready);
      expect(b.state.photoStepPending, isFalse);
    },
  );

  blocTest<OnboardingBloc, OnboardingState>(
    'finishing or skipping clears it, and a later GetMe does not bring it back',
    setUp: () => when(() => repo.getMe()).thenAnswer(
      (_) async =>
          identity.GetMeResponse(profile: profile, enabledFeatures: ['media']),
    ),
    build: build,
    seed: () => seed,
    act: (b) async {
      b.add(const OnboardingProfileSubmitted());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      b.add(const OnboardingPhotoStepFinished());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      b.add(const OnboardingRefreshRequested());
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
    verify: (b) {
      expect(b.state.status, OnboardingStatus.ready);
      expect(b.state.photoStepPending, isFalse);
    },
  );

  blocTest<OnboardingBloc, OnboardingState>(
    'sign-out forgets a pending step',
    setUp: () => when(() => repo.getMe()).thenAnswer(
      (_) async =>
          identity.GetMeResponse(profile: profile, enabledFeatures: ['media']),
    ),
    build: build,
    seed: () => seed,
    act: (b) async {
      b.add(const OnboardingUserAuthenticated(user));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      b.add(const OnboardingProfileSubmitted());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      b.add(const OnboardingUserSignedOut());
    },
    verify: (b) => expect(b.state, const OnboardingState()),
  );
}
