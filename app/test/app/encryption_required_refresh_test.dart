import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/rate_limit_hold.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/messaging_feature_flag.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.connect.spec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/fake_transport.dart';
import '../support/messaging_fixtures.dart';

// Plan 6 Task 1.B fix round, security review H1: a session that is already
// open holds the flag set of its last GetMe. A plaintext send the server
// refuses with ENCRYPTION_REQUIRED asks for a fresh GetMe (the real wiring:
// buildMessagingGate over a real OnboardingBloc), so the NEXT send is refused
// on this device. One plaintext send can still reach the server in that
// window; the server's refusal is the control.

class _MockIdentity extends Mock implements IdentityRepository {}

const _user = AppUser(
  uid: 'uid-1',
  email: 'a@example.com',
  emailVerified: true,
  isPasswordProvider: true,
);

identity.GetMeResponse _me(List<String> features) => identity.GetMeResponse(
  profile: identity.Profile(userId: 'uid-1', handle: 'me'),
  enabledFeatures: features,
  // Pending follow requests, so answering one changes the state (a state
  // equal to the last is not emitted).
  pendingFollowRequestCount: Int64(5),
);

void main() {
  late _MockIdentity identityRepository;
  late List<String> serverFeatures;
  late int getMeCalls;
  late OnboardingBloc onboarding;

  setUp(() async {
    identityRepository = _MockIdentity();
    serverFeatures = [kFeatureMessaging];
    getMeCalls = 0;
    when(() => identityRepository.cachedOwnProfile(any()))
        .thenAnswer((_) async => null);
    when(() => identityRepository.getMe()).thenAnswer((_) async {
      getMeCalls++;
      return _me(List.of(serverFeatures));
    });
    onboarding = OnboardingBloc(identityRepository: identityRepository);
    addTearDown(onboarding.close);
    onboarding.add(const OnboardingUserAuthenticated(_user));
    await pumpEventQueue();
    expect(getMeCalls, 1);
  });

  test('ENCRYPTION_REQUIRED on a plaintext send refreshes GetMe, and the next '
      'send is refused on this device with no server call', () async {
    final sends = <pb.SendMessageRequest>[];
    final transport = FakeTransport((procedure, input) async {
      if (procedure == '/${MessagingService.name}/SendMessage') {
        sends.add(input as pb.SendMessageRequest);
        // The server's cohort moved on; this session's flags did not.
        serverFeatures = [kFeatureMessaging, kFeatureE2eeRequired];
        throw withDetail(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_ENCRYPTION_REQUIRED,
        );
      }
      throw StateError('unexpected $procedure');
    });
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = MessagingRepository(
      apiClient: ApiClient.withTransport(transport),
      store: MessagingStore(database),
      gate: buildMessagingGate(onboarding),
      rateLimitHold: RateLimitHold(),
    );
    final cubit = MessageComposerCubit(
      repository: repository,
      conversationId: hexId(0xc1),
      outbox: repository.outbox,
      encryptionRequired: e2eeRequiredOf(onboarding),
    );
    addTearDown(cubit.close);

    // Required is off on this device: today's plaintext send, refused by
    // the server.
    cubit.textChanged('first');
    await cubit.send();
    expect(sends, hasLength(1));
    await pumpEventQueue();
    expect(getMeCalls, 2, reason: 'the refusal asked for a fresh GetMe');
    expect(onboarding.state.enabledFeatures, contains(kFeatureE2eeRequired));

    cubit.textChanged('second');
    await cubit.send();
    expect(sends, hasLength(1), reason: 'refused locally, no server call');
    expect(cubit.state.refusedProblem, SendProblem.requiredNotOnThisDevice);
    expect(cubit.state.draft.text, 'second');
  });

  group('ResumeFlagsRefresh (H1: refresh on resume after 15 minutes)', () {
    test('no refresh within 15 minutes of the last GetMe answer; one after; '
        'the clock restarts with that answer', () async {
      var now = DateTime.now();
      final refresh = ResumeFlagsRefresh(onboarding, now: () => now);
      addTearDown(refresh.dispose);

      now = now.add(const Duration(minutes: 14, seconds: 59));
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 1);

      now = now.add(const Duration(seconds: 1));
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 2);

      // A second resume right after: the answer just came, no new GetMe.
      now = now.add(const Duration(minutes: 1));
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 2);
    });

    test('a GetMe answered for another reason restarts the clock (and only '
        'the answer does: a later non-GetMe update does not)', () async {
      var now = DateTime.now();
      final refresh = ResumeFlagsRefresh(onboarding, now: () => now);
      addTearDown(refresh.dispose);
      final generation = onboarding.flagsGeneration;
      now = now.add(const Duration(minutes: 10));
      onboarding.add(const OnboardingRefreshRequested());
      await pumpEventQueue();
      expect(getMeCalls, 2);
      expect(onboarding.flagsGeneration, generation + 1);

      // At 20 minutes a state change that is not a GetMe answer.
      now = now.add(const Duration(minutes: 10));
      onboarding.add(const OnboardingFollowRequestAnswered());
      await pumpEventQueue();
      expect(onboarding.flagsGeneration, generation + 1);
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 2, reason: '10 minutes after the last answer');

      // 25 minutes: 15 after the answer at 10, whatever happened at 20.
      now = now.add(const Duration(minutes: 5));
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 3);
    });

    test('security L-new-1: a follow-request answer at 10 minutes does not '
        'restart the clock; a resume at 15 minutes still asks GetMe', () async {
      var now = DateTime.now();
      final refresh = ResumeFlagsRefresh(onboarding, now: () => now);
      addTearDown(refresh.dispose);
      now = now.add(const Duration(minutes: 10));
      onboarding.add(const OnboardingFollowRequestAnswered());
      await pumpEventQueue();
      expect(onboarding.state.pendingFollowRequestCount, 4, reason: 'emitted');
      now = now.add(const Duration(minutes: 5));
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 2);
    });

    test('signed out: no refresh', () async {
      var now = DateTime.now();
      final refresh = ResumeFlagsRefresh(onboarding, now: () => now);
      addTearDown(refresh.dispose);
      onboarding.add(const OnboardingUserSignedOut());
      await pumpEventQueue();
      now = now.add(const Duration(hours: 1));
      refresh.onResume();
      await pumpEventQueue();
      expect(getMeCalls, 1);
    });
  });
}
