// Plan 5a Task 13 step 13-ii: the app-level E2EE pipeline wiring helpers
// (lib/app/e2ee_wiring.dart). The bootstrap lines that call them are pinned
// by test/guards/e2ee_bootstrap_wiring_guard_test.dart.
import 'dart:async';

import 'package:dzeroth/app/e2ee_wiring.dart';
import 'package:dzeroth/core/feature_flags/public_ids_feature_flag.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/push_cubit.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resumeE2ee (gate items 35-37)', () {
    test('engine, then one non-confirming session retry, then the device '
        'keys, then the pipeline', () {
      final calls = <String>[];
      resumeE2ee(
        engineResumed: () => calls.add('engine'),
        retryVault: ({required bool allowConfirmedWipe}) async {
          calls.add('retry:$allowConfirmedWipe');
        },
        deviceKeysResumed: () async => calls.add('deviceKeys'),
        pipelineResumed: () => calls.add('pipeline'),
      );
      expect(calls, ['engine', 'retry:false', 'deviceKeys', 'pipeline']);
    });

    test('no pipeline (unsupported platform): the other three still run', () {
      final calls = <String>[];
      resumeE2ee(
        engineResumed: () => calls.add('engine'),
        retryVault: ({required bool allowConfirmedWipe}) async {
          calls.add('retry');
        },
        deviceKeysResumed: () async => calls.add('deviceKeys'),
      );
      expect(calls, ['engine', 'retry', 'deviceKeys']);
    });

    test(
      'a failing retry or device-keys run is reported, never thrown',
      () async {
        final reported = <Object>[];
        runZonedGuarded(
          () => resumeE2ee(
            engineResumed: () {},
            retryVault: ({required bool allowConfirmedWipe}) =>
                Future.error(StateError('x')),
            deviceKeysResumed: () => Future.error(ArgumentError('y')),
            onUnexpectedError: (e, _) => reported.add(e),
          ),
          (e, _) => fail('escaped: $e'),
        );
        await pumpEventQueue();
        expect(reported, hasLength(2));
      },
    );
  });

  group('flagTurnedOnWithOpenVault (gate item 29)', () {
    test('the device keys first, the pipeline start after them', () async {
      final calls = <String>[];
      final keys = Completer<void>();
      final done = flagTurnedOnWithOpenVault(
        ensureDeviceReady: () {
          calls.add('deviceKeys');
          return keys.future;
        },
        startPipeline: () async => calls.add('pipeline'),
      );
      await pumpEventQueue();
      expect(calls, ['deviceKeys'], reason: 'the pipeline waits');
      keys.complete();
      await done;
      expect(calls, ['deviceKeys', 'pipeline']);
    });

    test('a failed device run still starts the pipeline (it gates itself) '
        'and is reported', () async {
      final calls = <String>[];
      final reported = <Object>[];
      await flagTurnedOnWithOpenVault(
        ensureDeviceReady: () => Future.error(StateError('x')),
        startPipeline: () async => calls.add('pipeline'),
        onUnexpectedError: (e, _) => reported.add(e),
      );
      expect(calls, ['pipeline']);
      expect(reported, hasLength(1));
    });
  });

  group('forwardMessagePushes (gate item 67)', () {
    late StreamController<PushState> states;
    late List<String?> pushes;

    setUp(() {
      states = StreamController<PushState>.broadcast();
      pushes = [];
    });
    tearDown(() => states.close());

    test(
      'only a grown messagePushes forwards, with its conversation id',
      () async {
        final sub = forwardMessagePushes(
          states: states.stream,
          initial: const PushState(messagePushes: 2),
          onPush: pushes.add,
        );
        states
          ..add(
            const PushState(messagePushes: 2, lastMessageConversationId: 'a'),
          )
          ..add(
            const PushState(messagePushes: 3, lastMessageConversationId: 'b'),
          )
          ..add(
            const PushState(messagePushes: 3, lastMessageConversationId: 'b'),
          )
          ..add(
            const PushState(messagePushes: 4, lastMessageConversationId: 'b'),
          );
        await pumpEventQueue();
        await sub.cancel();
        expect(pushes, ['b', 'b']);
      },
    );

    test(
      'a push without a conversation id forwards null (welcomes only)',
      () async {
        final sub = forwardMessagePushes(
          states: states.stream,
          initial: const PushState(),
          onPush: pushes.add,
        );
        states.add(const PushState(messagePushes: 1));
        await pumpEventQueue();
        await sub.cancel();
        expect(pushes, [null]);
      },
    );
  });

  group('publicIdsKnownOff (gate item 9)', () {
    test('only a ready, fully answered state without public_ids is off', () {
      expect(
        publicIdsKnownOff(
          const OnboardingState(status: OnboardingStatus.ready),
        ),
        isTrue,
      );
      expect(
        publicIdsKnownOff(
          const OnboardingState(
            status: OnboardingStatus.ready,
            enabledFeatures: {kFeaturePublicIds},
          ),
        ),
        isFalse,
      );
      expect(
        publicIdsKnownOff(
          const OnboardingState(
            status: OnboardingStatus.ready,
            flagsPending: true,
          ),
        ),
        isFalse,
        reason: 'not answered yet is not off',
      );
      expect(publicIdsKnownOff(const OnboardingState()), isFalse);
    });
  });
}
