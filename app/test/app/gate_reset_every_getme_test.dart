import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/posts_fixtures.dart';

// Plan 6 PR 6-2 follow-up: a remembered FEATURE_DISABLED is forgotten on
// EVERY successful GetMe, also one whose answer equals the last one. With a
// cached profile that renders exactly like the GetMe profile, the refresh
// emits states equal to the current one, which bloc drops (`emit` skips a
// state equal to the last): without a state field that moves per answer, no
// listener ever learned of the answer and the gate stayed off for the
// session. A failed GetMe does not count (fail closed).

class _MockIdentity extends Mock implements IdentityRepository {}

const _user = AppUser(
  uid: 'uid-1',
  email: 'a@example.com',
  emailVerified: true,
  isPasswordProvider: true,
);

final _cached = CachedProfile(
  userId: 'uid-1',
  handle: 'me',
  displayName: '',
  bio: '',
  avatarUrl: '',
  avatarThumbUrl: '',
  isPrivate: false,
  verified: false,
  subscriptionVerified: false,
  followersCount: 0,
  followingCount: 0,
  postsCount: 0,
  cachedAt: DateTime.now(),
);

identity.Profile _profile() => identity.Profile(userId: 'uid-1', handle: 'me');

connect.ConnectException _featureDisabled() => serverError(
  connect.Code.failedPrecondition,
  common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
);

void main() {
  late _MockIdentity identityRepository;
  late int getMeCalls;
  late bool getMeFails;
  late OnboardingBloc onboarding;
  const features = [kFeaturePosts, kFeatureMessaging, 'notifications'];

  setUp(() async {
    identityRepository = _MockIdentity();
    getMeCalls = 0;
    getMeFails = false;
    when(() => identityRepository.cachedOwnProfile(any()))
        .thenAnswer((_) async => _cached);
    when(() => identityRepository.profileFromCache(_cached))
        .thenAnswer((_) => _profile());
    when(() => identityRepository.getMe()).thenAnswer((_) async {
      getMeCalls++;
      if (getMeFails) throw const NetworkException('offline');
      // The same flag set (and everything else) on every answer.
      return identity.GetMeResponse(
        profile: _profile(),
        enabledFeatures: List.of(features),
      );
    });
    onboarding = OnboardingBloc(identityRepository: identityRepository);
    addTearDown(onboarding.close);
    onboarding.add(const OnboardingUserAuthenticated(_user));
    await pumpEventQueue();
    expect(getMeCalls, 1);
  });

  test('bloc: every successful GetMe emits a state, also an identical answer; '
      'a failed one does not move the generation', () async {
    final before = onboarding.state;
    final generation = onboarding.flagsGeneration;
    final emitted = [];
    final sub = onboarding.stream.listen(emitted.add);
    addTearDown(sub.cancel);

    onboarding.add(const OnboardingRefreshRequested());
    await pumpEventQueue();
    expect(getMeCalls, 2);
    expect(onboarding.flagsGeneration, generation + 1);
    expect(onboarding.state.flagsGeneration, generation + 1);
    expect(emitted, isNotEmpty, reason: 'an identical answer still emits');
    expect(onboarding.state.enabledFeatures, before.enabledFeatures);

    getMeFails = true;
    onboarding.add(const OnboardingRefreshRequested());
    await pumpEventQueue();
    expect(getMeCalls, 3);
    expect(onboarding.flagsGeneration, generation + 1, reason: 'fail closed');
    expect(onboarding.state.flagsGeneration, generation + 1);
  });

  test('service gate: FEATURE_DISABLED remembered, then a GetMe with an '
      'identical flag set enables the gate again', () async {
    final gate = buildServiceGate(onboarding, 'notifications');
    expect(gate.enabled, isTrue);
    await expectLater(
      gate.run<void>(() async => throw _featureDisabled()),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(gate.enabled, isFalse);
    await pumpEventQueue();
    expect(getMeCalls, 2, reason: 'the refusal asked for a fresh GetMe');
    expect(gate.enabled, isTrue, reason: 'the fresh GetMe decides');
  });

  test('posts gate: same, and a failed GetMe keeps the remembered answer '
      '(fail closed)', () async {
    final gate = buildPostsGate(onboarding);
    getMeFails = true;
    await expectLater(
      gate.run<void>(() async => throw _featureDisabled()),
      throwsA(isA<FeatureDisabledException>()),
    );
    await pumpEventQueue();
    expect(getMeCalls, 2);
    expect(gate.postsEnabled, isFalse, reason: 'a failed GetMe is no answer');

    getMeFails = false;
    onboarding.add(const OnboardingRefreshRequested());
    await pumpEventQueue();
    expect(getMeCalls, 3);
    expect(gate.postsEnabled, isTrue);
  });

  test('messaging gate: same', () async {
    final gate = buildMessagingGate(onboarding);
    await expectLater(
      gate.run<void>(() async => throw _featureDisabled()),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(gate.enabled, isFalse);
    await pumpEventQueue();
    expect(getMeCalls, 2);
    expect(gate.enabled, isTrue);
  });

  test('claim clock (ResumeFlagsRefresh): an identical GetMe answer counts '
      'as an answer', () async {
    var now = DateTime.now();
    final refresh = ResumeFlagsRefresh(onboarding, now: () => now);
    addTearDown(refresh.dispose);
    now = now.add(const Duration(minutes: 20));
    onboarding.add(const OnboardingRefreshRequested());
    await pumpEventQueue();
    expect(getMeCalls, 2);
    now = now.add(const Duration(minutes: 20));
    expect(
      refresh.answerOlderThan(kClaimFlagsMaxAge),
      isFalse,
      reason: 'the last answer was 20 minutes ago, not 40',
    );
  });
}
