import 'dart:async';

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
  late Completer<identity.GetMeResponse> getMeGate;
  late Completer<identity.Profile> submitGate;
  late Completer<identity.CheckHandleAvailabilityResponse> handleGate;

  const user = AppUser(
    uid: 'uid-1',
    email: 'a@example.com',
    emailVerified: true,
    isPasswordProvider: true,
  );

  setUp(() {
    identityRepository = MockIdentityRepository();
    when(() => identityRepository.cachedOwnProfile(any()))
        .thenAnswer((_) async => null);
  });

  group('OnboardingBloc sign-out races', () {
    blocTest<OnboardingBloc, OnboardingState>(
      'a CreateProfile completing after sign-out never emits the old profile',
      setUp: () {
        when(() => identityRepository.getMe())
            .thenThrow(const ProfileRequiredException('create a profile'));
        submitGate = Completer<identity.Profile>();
        when(
          () => identityRepository.createProfile(
            handle: any(named: 'handle'),
            displayName: any(named: 'displayName'),
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenAnswer((_) => submitGate.future);
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      seed: () => const OnboardingState(
        handle: 'kaif',
        displayName: 'Kaif',
        handleCheckStatus: HandleCheckStatus.available,
      ),
      act: (bloc) async {
        bloc.add(const OnboardingUserAuthenticated(user));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const OnboardingProfileSubmitted());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const OnboardingUserSignedOut());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        submitGate.complete(identity.Profile(userId: 'uid-1', handle: 'old'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (bloc) {
        expect(bloc.state, const OnboardingState());
        expect(bloc.state.profile, isNull);
      },
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'a handle check completing after sign-out emits nothing',
      setUp: () {
        when(() => identityRepository.getMe())
            .thenThrow(const ProfileRequiredException('create a profile'));
        handleGate = Completer<identity.CheckHandleAvailabilityResponse>();
        when(() => identityRepository.checkHandleAvailability('kaif'))
            .thenAnswer((_) => handleGate.future);
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) async {
        bloc.add(const OnboardingUserAuthenticated(user));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const OnboardingHandleChanged('kaif'));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        bloc.add(const OnboardingUserSignedOut());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        handleGate.complete(
          identity.CheckHandleAvailabilityResponse(available: true),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      verify: (bloc) => expect(bloc.state, const OnboardingState()),
    );
  });

  group('OnboardingBloc', () {
    blocTest<OnboardingBloc, OnboardingState>(
      'a GetMe completing after sign-out never emits the old profile',
      setUp: () {
        final gate = Completer<identity.GetMeResponse>();
        getMeGate = gate;
        when(() => identityRepository.getMe()).thenAnswer((_) => gate.future);
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) async {
        bloc.add(const OnboardingUserAuthenticated(user));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        bloc.add(const OnboardingUserSignedOut());
        await Future<void>.delayed(Duration.zero);
        getMeGate.complete(
          identity.GetMeResponse(
            profile: identity.Profile(userId: 'uid-1', handle: 'old'),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      },
      expect: () => [
        const OnboardingState(status: OnboardingStatus.loading),
        const OnboardingState(),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'goes to profileRequired when GetMe throws ProfileRequiredException',
      setUp: () {
        when(() => identityRepository.getMe())
            .thenThrow(const ProfileRequiredException('create a profile'));
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
        when(() => identityRepository.getMe())
            .thenAnswer((_) async => identity.GetMeResponse(profile: profile));
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
      'populates enabledFeatures from GetMe.enabled_features (ADR-0008 D6), '
      'at 0 extra reads',
      setUp: () {
        final profile = identity.Profile(userId: 'uid-1', handle: 'kaif');
        when(() => identityRepository.getMe()).thenAnswer(
          (_) async => identity.GetMeResponse(
            profile: profile,
            enabledFeatures: ['graph'],
          ),
        );
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingUserAuthenticated(user)),
      expect: () => [
        const OnboardingState(status: OnboardingStatus.loading),
        isA<OnboardingState>()
            .having((s) => s.status, 'status', OnboardingStatus.ready)
            .having((s) => s.enabledFeatures, 'enabledFeatures', {'graph'}),
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
        when(() => identityRepository.cachedOwnProfile('uid-1'))
            .thenAnswer((_) async => cachedProfile);
        when(() => identityRepository.profileFromCache(cachedProfile))
            .thenReturn(
              identity.Profile(
                userId: 'uid-1',
                handle: 'kaif',
                displayName: 'Kaif (cached)',
              ),
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
        when(() => identityRepository.checkHandleAvailability('kaif'))
            .thenAnswer(
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
        when(() => identityRepository.checkHandleAvailability('kaif'))
            .thenAnswer(
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
        ).thenAnswer(
          (_) async => identity.Profile(userId: 'uid-1', handle: 'kaif'),
        );
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

    blocTest<OnboardingBloc, OnboardingState>(
      'goes to emailVerificationRequired when CreateProfile throws '
      'EmailNotVerifiedException, instead of a bare error',
      setUp: () {
        when(
          () => identityRepository.createProfile(
            handle: 'kaif',
            displayName: 'Kaif',
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenThrow(const EmailNotVerifiedException('verify your email'));
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
            .having(
              (s) => s.status,
              'status',
              OnboardingStatus.emailVerificationRequired,
            )
            .having((s) => s.isSubmitting, 'isSubmitting', false)
            .having((s) => s.error, 'error', isA<EmailNotVerifiedException>())
            // The handle/name the user typed must survive so they can retry
            // Continue after verifying without retyping anything.
            .having((s) => s.handle, 'handle', 'kaif')
            .having((s) => s.displayName, 'displayName', 'Kaif'),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'handle check EmailNotVerified shows the verify-email state, not '
      '"handle unavailable" (ADR-0010 D5 A2/A10)',
      setUp: () {
        when(() => identityRepository.checkHandleAvailability('kaif'))
            .thenThrow(const EmailNotVerifiedException('verify your email'));
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingHandleChanged('kaif')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        const OnboardingState(
          handle: 'kaif',
          handleCheckStatus: HandleCheckStatus.checking,
        ),
        isA<OnboardingState>()
            .having(
              (s) => s.status,
              'status',
              OnboardingStatus.emailVerificationRequired,
            )
            .having(
              (s) => s.handleCheckStatus,
              'handleCheckStatus',
              HandleCheckStatus.idle,
            )
            .having((s) => s.handleCheckMessage, 'message', isEmpty)
            .having((s) => s.error, 'error', isA<EmailNotVerifiedException>()),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'handle check RATE_LIMITED is "unknown" and still allows Submit (N1)',
      setUp: () {
        when(() => identityRepository.checkHandleAvailability('kaif')).thenThrow(
          const RateLimitedException(
            'slow',
            limitName: 'check_handle_daily',
            retryAfter: Duration(hours: 5),
          ),
        );
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      seed: () => const OnboardingState(displayName: 'Kaif'),
      act: (bloc) => bloc.add(const OnboardingHandleChanged('kaif')),
      wait: const Duration(milliseconds: 350),
      expect: () => [
        isA<OnboardingState>().having(
          (s) => s.handleCheckStatus,
          'status',
          HandleCheckStatus.checking,
        ),
        isA<OnboardingState>()
            .having(
              (s) => s.handleCheckStatus,
              'status',
              HandleCheckStatus.unknown,
            )
            .having((s) => s.canSubmit, 'canSubmit', isTrue)
            .having((s) => s.status, 'status', OnboardingStatus.unknown),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'CreateProfile after an unknown handle check still surfaces '
      'HandleTaken from the server',
      setUp: () {
        when(
          () => identityRepository.createProfile(
            handle: 'kaif',
            displayName: 'Kaif',
            idempotencyKey: any(named: 'idempotencyKey'),
          ),
        ).thenThrow(const HandleTakenException('That handle is taken.'));
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      seed: () => const OnboardingState(
        handle: 'kaif',
        displayName: 'Kaif',
        handleCheckStatus: HandleCheckStatus.unknown,
      ),
      act: (bloc) => bloc.add(const OnboardingProfileSubmitted()),
      expect: () => [
        isA<OnboardingState>().having((s) => s.isSubmitting, 'sub', isTrue),
        isA<OnboardingState>()
            .having(
              (s) => s.handleCheckStatus,
              'status',
              HandleCheckStatus.unavailable,
            )
            .having((s) => s.canSubmit, 'canSubmit', isFalse),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'GetMe EmailNotVerified goes to emailVerificationRequired',
      setUp: () {
        when(() => identityRepository.getMe())
            .thenThrow(const EmailNotVerifiedException('verify'));
      },
      build: () => OnboardingBloc(identityRepository: identityRepository),
      act: (bloc) => bloc.add(const OnboardingUserAuthenticated(user)),
      expect: () => [
        const OnboardingState(status: OnboardingStatus.loading),
        isA<OnboardingState>().having(
          (s) => s.status,
          'status',
          OnboardingStatus.emailVerificationRequired,
        ),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'OnboardingEmailVerificationDismissed returns to the create-profile '
      'form, keeping the typed handle/name',
      build: () => OnboardingBloc(identityRepository: identityRepository),
      seed: () => const OnboardingState(
        status: OnboardingStatus.emailVerificationRequired,
        handle: 'kaif',
        displayName: 'Kaif',
        handleCheckStatus: HandleCheckStatus.available,
        error: EmailNotVerifiedException('verify your email'),
      ),
      act: (bloc) => bloc.add(const OnboardingEmailVerificationDismissed()),
      expect: () => [
        const OnboardingState(
          status: OnboardingStatus.profileRequired,
          handle: 'kaif',
          displayName: 'Kaif',
          handleCheckStatus: HandleCheckStatus.available,
        ),
      ],
    );
  });
}
