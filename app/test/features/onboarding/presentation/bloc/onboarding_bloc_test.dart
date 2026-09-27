import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockIdentityRepository extends Mock implements IdentityRepository {}

void main() {
  late MockIdentityRepository identityRepository;

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUp(() {
    identityRepository = MockIdentityRepository();
    when(
      () => identityRepository.cachedOwnProfile(any()),
    ).thenAnswer((_) async => null);
  });

  group('OnboardingBloc', () {
    blocTest<OnboardingBloc, OnboardingState>(
      'goes to profileRequired when GetMe throws ProfileRequiredException',
      setUp: () {
        when(
          () => identityRepository.getMe(),
        ).thenThrow(const ProfileRequiredException('create a profile'));
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingUserAuthenticated(user)),
      expect: () => [
        const OnboardingState(status: OnboardingStatus.loading),
        const OnboardingState(status: OnboardingStatus.profileRequired),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'goes to ready with the profile on success',
      setUp: () {
        final profile = identity.Profile(userId: 'uid-1', handle: 'kaif');
        when(() => identityRepository.getMe()).thenAnswer(
          (_) async => identity.GetMeResponse(profile: profile),
        );
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingUserAuthenticated(user)),
      expect: () => [
        const OnboardingState(status: OnboardingStatus.loading),
        isA<OnboardingState>()
            .having((s) => s.status, 'status', OnboardingStatus.ready)
            .having((s) => s.profile?.handle, 'profile.handle', 'kaif'),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'renders the cached profile instantly, then reconciles with GetMe',
      setUp: () {
        final cachedProfile = CachedProfile(
          userId: 'uid-1',
          handle: 'kaif',
          displayName: 'Kaif (cached)',
          bio: '',
          avatarUrl: '',
          avatarThumbUrl: '',
          isPrivate: false,
          verified: false,
          followersCount: 0,
          followingCount: 0,
          postsCount: 0,
          cachedAt: DateTime(2024),
        );
        when(
          () => identityRepository.cachedOwnProfile('uid-1'),
        ).thenAnswer((_) async => cachedProfile);
        when(() => identityRepository.profileFromCache(cachedProfile)).thenReturn(
          identity.Profile(userId: 'uid-1', handle: 'kaif', displayName: 'Kaif (cached)'),
        );
        when(() => identityRepository.getMe()).thenAnswer(
          (_) async => identity.GetMeResponse(
            profile: identity.Profile(
              userId: 'uid-1',
              handle: 'kaif',
              displayName: 'Kaif (fresh)',
            ),
          ),
        );
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingUserAuthenticated(user)),
      expect: () => [
        isA<OnboardingState>()
            .having((s) => s.status, 'status', OnboardingStatus.ready)
            .having(
              (s) => s.profile?.displayName,
              'profile.displayName',
              'Kaif (cached)',
            ),
        isA<OnboardingState>()
            .having((s) => s.status, 'status', OnboardingStatus.ready)
            .having(
              (s) => s.profile?.displayName,
              'profile.displayName',
              'Kaif (fresh)',
            ),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'resets on sign-out',
      build: () => OnboardingBloc(identityRepository: identityRepository),
      seed: () => const OnboardingState(status: OnboardingStatus.ready),
      act: (bloc) => bloc.add(const OnboardingUserSignedOut()),
      expect: () => [const OnboardingState()],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'handle availability check marks an available handle',
      setUp: () {
        when(() => identityRepository.checkHandleAvailability('kaif')).thenAnswer(
          (_) async =>
              identity.CheckHandleAvailabilityResponse(available: true),
        );
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingHandleChanged('kaif')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        const OnboardingState(
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.checking,
        ),
        const OnboardingState(
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.available,
        ),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'rejects a too-short handle without calling the API',
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingHandleChanged('ab')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        const OnboardingState(
          handle: 'ab',
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage:
              '3-15 characters: lowercase letters, numbers, underscore.',
        ),
      ],
      verify: (_) {
        verifyNever(() => identityRepository.checkHandleAvailability(any()));
      },
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'rejects a handle longer than the server allows (15 chars) without '
      'calling the API',
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) =>
          bloc.add(const OnboardingHandleChanged('abcdefghijklmnop')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        OnboardingState(
          handle: 'abcdefghijklmnop',
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage:
              '3-15 characters: lowercase letters, numbers, underscore.',
        ),
      ],
      verify: (_) {
        verifyNever(() => identityRepository.checkHandleAvailability(any()));
      },
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'rejects a reserved handle without calling the API',
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingHandleChanged('admin')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        const OnboardingState(
          handle: 'admin',
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: 'That handle is reserved.',
        ),
      ],
      verify: (_) {
        verifyNever(() => identityRepository.checkHandleAvailability(any()));
      },
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'maps a taken handle (server reason "") to friendly text, never the '
      'raw reason code',
      setUp: () {
        when(() => identityRepository.checkHandleAvailability('kaif')).thenAnswer(
          (_) async => identity.CheckHandleAvailabilityResponse(
            available: false,
            reason: '',
          ),
        );
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingHandleChanged('kaif')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        const OnboardingState(
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.checking,
        ),
        const OnboardingState(
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.unavailable,
          handleCheckMessage: 'That handle is taken.',
        ),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'submits the profile once handle is available and display name is set',
      setUp: () {
        when(
          () => identityRepository.createProfile(
            handle: 'kaif',
            displayName: 'Kaif',
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer((_) async => identity.Profile(userId: 'uid-1', handle: 'kaif'));
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      seed: () => const OnboardingState(
        handle: 'kaif',
        displayName: 'Kaif',
        handleCheckStatus: HandleCheckStatus.available,
      ),
      act: (bloc) => bloc.add(const OnboardingProfileSubmitted()),
      expect: () => [
        const OnboardingState(
          handle: 'kaif',
          displayName: 'Kaif',
          handleCheckStatus: HandleCheckStatus.available,
          isSubmitting: true,
        ),
        isA<OnboardingState>()
            .having((s) => s.status, 'status', OnboardingStatus.ready)
            .having((s) => s.isSubmitting, 'isSubmitting', false),
      ],
    );
  });
}
