import 'dart:async';

import '../core/feature_flags/public_ids_feature_flag.dart';
import '../core/vault/vault_status.dart';
import '../features/messages/domain/e2ee/e2ee_types.dart'
    show E2eePipelineError;
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
///
/// Fix wave ruling 3 (code review I2, security audit L1): with a
/// [throttle] (bootstrap always passes one), steps 2 and 4 run only when
/// [E2eeResumeThrottle.takeResume] allows, and step 2 only when
/// [E2eeResumeThrottle.mayRetry] allows for [vaultStatus]. The engine's
/// resume (1) and the device keys' (3, which throttle themselves) run on
/// every resume, as before this branch.
void resumeE2ee({
  required void Function() engineResumed,
  required Future<void> Function({required bool allowConfirmedWipe}) retryVault,
  required Future<void> Function() deviceKeysResumed,
  void Function()? pipelineResumed,
  E2eeResumeThrottle? throttle,
  VaultStatus Function()? vaultStatus,
  E2eeWiringErrorReporter? onUnexpectedError,
}) {
  engineResumed();
  final due = throttle?.takeResume() ?? true;
  final status = vaultStatus?.call();
  final retry =
      due && (throttle == null || status == null || throttle.mayRetry(status));
  if (retry) {
    unawaited(
      _reported(
        'retry',
        retryVault(allowConfirmedWipe: false),
        onUnexpectedError,
      ),
    );
  }
  unawaited(_reported('deviceKeys', deviceKeysResumed(), onUnexpectedError));
  if (due) pipelineResumed?.call();
}

/// The floor between two throttled resumes ([E2eeResumeThrottle]); the
/// welcome poll's floor.
const kE2eeResumeFloor = Duration(seconds: 60);

/// Fix wave ruling 3 (code review I2, security audit L1): which app resumes
/// run the automatic vault retry and the pipeline's resume.
///
/// Decision: at most once per [kE2eeResumeFloor], and at once after a real
/// pause ([notePaused]). Why: on the web the engine maps every window focus
/// to `resumed` and never reports `paused`, and on Android a notification
/// shade or a system dialog is `inactive` → `resumed`; a time floor works
/// the same on both, while "only after a real background" would need two
/// different lifecycle mappings. A real pause always opens the floor, so a
/// paused pipeline (Android) is never left paused by the throttle.
///
/// [mayRetry]: never an automatic retry while the vault is
/// `storageChanged` (only a user reset ends it) or `unsupported`, and on
/// the web never again in this process once an open was refused
/// (`unavailable`): each refused web open can leave an idle worker until
/// the page unloads (`vault_open_web.dart`). The web cannot tell a refused
/// probe from another `unavailable`, so any web `unavailable` counts. A
/// user's own retry (5b) and a new sign-in still open.
class E2eeResumeThrottle {
  E2eeResumeThrottle({
    required bool isWeb,
    DateTime Function() now = DateTime.now,
  }) : _isWeb = isWeb,
       _now = now;

  final bool _isWeb;
  final DateTime Function() _now;
  DateTime? _last;
  bool _paused = false;
  bool _webRefused = false;

  /// Every vault status change (bootstrap's listener on the session).
  void noteStatus(VaultStatus status) {
    if (_isWeb && status == VaultStatus.unavailable) _webRefused = true;
  }

  /// The app was paused (a real background).
  void notePaused() => _paused = true;

  /// Whether this resume runs the throttled steps; if so it counts.
  bool takeResume() {
    final now = _now();
    final last = _last;
    final due =
        _paused || last == null || !now.isBefore(last.add(kE2eeResumeFloor));
    if (due) {
      _last = now;
      _paused = false;
    }
    return due;
  }

  /// Whether an automatic vault retry may run in [status].
  bool mayRetry(VaultStatus status) =>
      status != VaultStatus.storageChanged &&
      status != VaultStatus.unsupported &&
      !_webRefused;
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
  await _reported('flagOn.deviceKeys', ensureDeviceReady(), onUnexpectedError);
  final start = startPipeline;
  if (start != null) {
    await _reported('flagOn.start', start(), onUnexpectedError);
  }
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

/// Awaits [run]; a failure is reported as `E2eePipelineError('wiring.<step>')`
/// with its stack, never the raw error object (fix wave ruling 8, security
/// audit L5: its message could carry text into crash reports; the pipeline
/// reports step names only, and so does its wiring).
Future<void> _reported(
  String step,
  Future<void> run,
  E2eeWiringErrorReporter? onUnexpectedError,
) async {
  try {
    await run;
  } on Object catch (_, s) {
    onUnexpectedError?.call(E2eePipelineError('wiring.$step'), s);
  }
}
