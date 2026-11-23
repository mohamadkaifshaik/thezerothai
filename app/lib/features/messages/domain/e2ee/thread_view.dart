import '../../../../core/network/app_exception.dart';
import 'e2ee_types.dart';
import 'encrypted_messaging.dart';
import 'group_starter.dart' show kStartErrorPeerHasNoDevice;
import 'message_content_codec.dart';

// Plan 5a Task 13b: the pure mapping from the pipeline's rows to the port's
// thread entries (no engine, no network, no vault). Step 13b-i holds the
// outgoing half; the stored-row, system-line, preview and security mappings
// come with step 13b-ii.

/// One own unsent row (`EncryptedSender.outgoing`, or the starter's pending
/// init) as the port's entry: [ThreadEntry.id] is the caller's `localId`
/// until delivery, `mine` is true, and it can never be reported.
///
/// Progress, first that holds:
/// - `failed`: `notSent` with the problem [_failedProblem] gives;
/// - `sending`: `sending` (stage encrypted, in flight or awaiting an unknown
///   outcome, or the init of a provisional group);
/// - `waiting`: the row's own gate, or [state]'s when the row names none
///   ([_blockedProblem]): `notSent` with `blocked`, `peerHasNoDevice` or
///   `refused` for a gate the row cannot pass by itself, else `waiting`
///   (syncing, an epoch to advance, a provisional group).
///
/// Text and shared post are the row's own bytes, decoded leniently; bytes
/// that do not decode carry no text (`undecodable`).
DecryptedMessage entryOfOutgoing(
  OutgoingRow row,
  ConversationCryptoState state,
) {
  final content = decodeMessageContentLenient(row.content);
  final _Status status = switch (row.status) {
    OutgoingStatus5a.failed => _failedProblem(row),
    OutgoingStatus5a.sending => const _Status(SendProgress.sending),
    OutgoingStatus5a.waiting => _blockedProblem(
      row.waitingOn != SendBlock.none ? row.waitingOn : state.sendBlock,
    ),
  };
  return DecryptedMessage(
    id: row.localId,
    at: row.createdAt,
    mine: true,
    check: content.wireOk ? MessageCheck.ok : MessageCheck.undecodable,
    text: content.wireOk ? content.text : '',
    sharedPostId: content.wireOk ? content.sharedPostId : '',
    progress: status.progress,
    problem: status.problem,
    error: status.error,
  );
}

/// What an own row shows; defines no `toString` (the error is typed only).
class _Status {
  const _Status(this.progress, [this.problem = SendProblem.none, this.error]);

  final SendProgress progress;
  final SendProblem problem;
  final AppException? error;
}

/// A waiting row's gate. Decision (gate item 22 and the port's
/// `SendProblem.blocked`): a gate the row waits behind until something
/// outside it changes (an unknown device, a stuck member, no welcome yet, a
/// vault or engine that cannot be used, the flag not on, removed elsewhere)
/// is `notSent` / `blocked`, and the row goes out by itself when it clears.
/// A peer that cannot be messaged is the typed refusal, a peer with no
/// device its own problem. Everything else only waits.
_Status _blockedProblem(SendBlock block) => switch (block) {
  SendBlock.unknownDevice ||
  SendBlock.stuck ||
  SendBlock.waitingForWelcome ||
  SendBlock.unavailable => const _Status(
    SendProgress.notSent,
    SendProblem.blocked,
  ),
  SendBlock.peerHasNoDevice => const _Status(
    SendProgress.notSent,
    SendProblem.peerHasNoDevice,
  ),
  SendBlock.cannotMessage => const _Status(
    SendProgress.notSent,
    SendProblem.refused,
    CannotMessageException(),
  ),
  SendBlock.none ||
  SendBlock.notSynced ||
  SendBlock.epochMustAdvance ||
  SendBlock.provisional => const _Status(SendProgress.waiting),
};

/// A failed row. Decision (gate items 16, 22, 25):
/// - a daily cap is `tryTomorrow` (its typed error is not needed: the copy
///   is fixed);
/// - a row the sender will not retry (the peer cannot be messaged) is
///   `refused` with [CannotMessageException], also after a restart, when
///   only its stored name is left;
/// - the starter's `PeerHasNoDevice` name is `peerHasNoDevice`;
/// - a typed error this run remembers that is a lasting answer
///   ([_lasting]) is `refused` with that error, so the row says why;
/// - everything else, a stored name with no typed error included (after a
///   restart; `LookupFailed`, `StartUnavailable`, `InitDiscarded`, or no
///   name at all), is `retryable`: "Not sent. Tap to retry", and the retry
///   goes through the starter's `retryStart`.
_Status _failedProblem(OutgoingRow row) {
  final error = row.error;
  if (row.tryTomorrow) {
    return const _Status(SendProgress.notSent, SendProblem.tryTomorrow);
  }
  if (!row.retryable) {
    return _Status(
      SendProgress.notSent,
      SendProblem.refused,
      error is CannotMessageException ? error : const CannotMessageException(),
    );
  }
  if (row.errorName == kStartErrorPeerHasNoDevice) {
    return const _Status(SendProgress.notSent, SendProblem.peerHasNoDevice);
  }
  if (error != null && _lasting(error)) {
    return _Status(SendProgress.notSent, SendProblem.refused, error);
  }
  return const _Status(SendProgress.notSent, SendProblem.retryable);
}

/// A server answer that will not change by sending again now, and that
/// `messagingErrorMessage` has its own line for (gate item 25). Every other
/// typed error (a short rate limit, a degraded or paused service, the
/// network, an account check) is shown as a retry, with no error carried.
bool _lasting(AppException e) => switch (e) {
  CannotMessageException() ||
  FeatureDisabledException() ||
  LimitReachedException() ||
  QuotaExceededException() ||
  NotFoundException() ||
  ValidationException() ||
  EncryptionRequiredException() => true,
  _ => false,
};
