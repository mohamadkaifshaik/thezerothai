import 'dart:async';

import '../core/feature_flags/public_ids_feature_flag.dart';
import '../features/notifications/presentation/bloc/push_cubit.dart';
import '../features/onboarding/presentation/bloc/onboarding_state.dart';

/// Reports an unexpected failure (bootstrap's `reportUnexpectedError`).
typedef E2eeWiringErrorReporter = void Function(Object error, StackTrace stack);

/// Plan 5a Task 13 (gate items 35-37): one app resume, in this order.
///
/// 1. [engineResumed] (F-4: a crypto engine that timed out may be tried
///    again);
/// 2. ONE [retryVault] with `allowConfirmedWipe: false` (item 36: a resume
///    never confirms a key-loss wipe; never in a loop, each refused web open
///    can leave an idle worker);
/// 3. [deviceKeysResumed];
/// 4. [pipelineResumed] (absent where the pipeline is not built), whose
///    first step is a new receive run right after the engine's (item 37).
///
/// The two futures are not awaited (as before); a failure of either is
/// reported, never thrown.
void resumeE2ee({
  required void Function() engineResumed,
  required Future<void> Function({required bool allowConfirmedWipe}) retryVault,
  required Future<void> Function() deviceKeysResumed,
  void Function()? pipelineResumed,
  E2eeWiringErrorReporter? onUnexpectedError,
}) {
  engineResumed();
  unawaited(
    _reported(retryVault(allowConfirmedWipe: false), onUnexpectedError),
  );
  unawaited(_reported(deviceKeysResumed(), onUnexpectedError));
  pipelineResumed?.call();
}

/// Plan 5a Task 13 (gate item 29): the e2ee_dm answer turned `on` with a
/// vault already open (the ready hooks ran before the answer and found the
/// gate closed). The device first, the pipeline second, as with the ready
/// hooks; the pipeline's start is idempotent and checks the device itself,
/// so it runs even when the device run failed. Never throws.
Future<void> flagTurnedOnWithOpenVault({
  required Future<void> Function() ensureDeviceReady,
  Future<void> Function()? startPipeline,
  E2eeWiringErrorReporter? onUnexpectedError,
}) async {
  await _reported(ensureDeviceReady(), onUnexpectedError);
  final start = startPipeline;
  if (start != null) await _reported(start(), onUnexpectedError);
}

/// Plan 5a Task 13 (gate item 67): each time `messagePushes` GROWS from the
/// previous state's count (starting from [initial]), [onPush] gets that
/// push's conversation id, or null when it carried none (the pipeline then
/// polls welcomes only). Other push-state changes forward nothing.
///
/// Fix wave ruling 2 (code review I1): the count is compared with the
/// PREVIOUS state, never a high-water mark: `PushCubit.stop()` (sign-out,
/// account switch) resets it to 0, and the next session's pushes count
/// from 1 again.
///
/// Ruling 11 (N5): the null path is kept for safety but is not reached
/// today: `PushCubit` drops a message push that carries no conversation.
StreamSubscription<PushState> forwardMessagePushes({
  required Stream<PushState> states,
  required PushState initial,
  required void Function(String? conversationId) onPush,
}) {
  var previous = initial.messagePushes;
  return states.listen((state) {
    final grew = state.messagePushes > previous;
    previous = state.messagePushes;
    if (!grew) return;
    final id = state.lastMessageConversationId;
    onPush(id.isEmpty ? null : id);
  });
}

/// Plan 5a Task 13 (gate item 9): `public_ids` is KNOWN off for the
/// signed-in account: a ready state whose flags this session's GetMe
/// answered, without the flag. Not answered yet is not off.
bool publicIdsKnownOff(OnboardingState s) =>
    s.status == OnboardingStatus.ready &&
    !s.flagsPending &&
    !s.enabledFeatures.contains(kFeaturePublicIds);

Future<void> _reported(
  Future<void> run,
  E2eeWiringErrorReporter? onUnexpectedError,
) async {
  try {
    await run;
  } on Object catch (e, s) {
    onUnexpectedError?.call(e, s);
  }
}
