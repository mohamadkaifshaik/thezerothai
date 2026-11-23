import '../../../../core/network/app_exception.dart';
import '../../../../core/vault/secure_vault.dart';
import 'deferred_record.dart' show DeferredView;
import 'e2ee_types.dart';
import 'encrypted_messaging.dart';
import 'group_starter.dart' show kStartErrorPeerHasNoDevice;
import 'message_content_codec.dart';

// Plan 5a Task 13b: the pure mapping from the pipeline's rows and state to
// the port's thread entries, previews and security (no engine, no network,
// no vault reads). Step 13b-i: the outgoing half; step 13b-ii: the rest.

/// 5b's preview text limit (characters, a single line).
const int kPreviewTextMax = 140;

/// The port's security of one conversation from the pipeline's state
/// ("Produces for Plan 5b", the mapping). [usable]: the vault is ready, the
/// engine works and the device is not removed elsewhere; when false
/// nothing can be sent and nothing reset.
///
/// A conversation the pipeline knows nothing about (phase `notEncrypted`)
/// is `ready` with `canSend` (the port's empty thread: whether it is
/// encrypted is the caller's decision). Otherwise the first that holds, in
/// 5b's order: pendingRequest, waitingForDevice, stuck, changesBlocked,
/// unknownDevice, listUnverifiable (Task 2's M4 rule decides it, never a
/// routine cap: gate item 38), peerHasNoDevice, sendPaused, syncing, ready
/// (a provisional group is ready).
ConversationSecurity securityOf(
  ConversationCryptoState state, {
  required bool usable,
}) {
  if (state.phase == ConversationPhase.notEncrypted) {
    // The port's documented answer for a ref the pipeline knows nothing
    // about: ready, canSend, no entries (the caller decides encryption).
    return const ConversationSecurity(state: ConversationEncryptionState.ready);
  }
  final unaccepted = !state.requestAccepted;
  final pending = unaccepted && state.incomingRequest;
  final sent = unaccepted && !state.incomingRequest;
  final ConversationEncryptionState s;
  if (pending) {
    s = ConversationEncryptionState.pendingRequest;
  } else if (state.phase == ConversationPhase.waitingForWelcome) {
    s = ConversationEncryptionState.waitingForDevice;
  } else if (state.phase == ConversationPhase.stuck) {
    s = ConversationEncryptionState.stuck;
  } else if (state.committingPausedToday) {
    s = ConversationEncryptionState.changesBlocked;
  } else if (state.unknownDevicePresent) {
    s = ConversationEncryptionState.unknownDevice;
  } else if (state.deviceListUnverifiable) {
    s = ConversationEncryptionState.listUnverifiable;
  } else if (state.sendBlock == SendBlock.peerHasNoDevice) {
    s = ConversationEncryptionState.peerHasNoDevice;
  } else if (state.sendBlock == SendBlock.epochMustAdvance) {
    s = ConversationEncryptionState.sendPaused;
  } else if (state.sendBlock == SendBlock.notSynced) {
    s = ConversationEncryptionState.syncing;
  } else {
    s = ConversationEncryptionState.ready;
  }
  final blocked = switch (s) {
    ConversationEncryptionState.pendingRequest ||
    ConversationEncryptionState.waitingForDevice ||
    ConversationEncryptionState.stuck ||
    ConversationEncryptionState.unknownDevice ||
    ConversationEncryptionState.peerHasNoDevice => true,
    // Difference 1: M5 stops commits; sends only while an unknown device
    // is present.
    ConversationEncryptionState.changesBlocked => state.unknownDevicePresent,
    _ => false,
  };
  final member =
      state.phase == ConversationPhase.ready ||
      state.phase == ConversationPhase.provisional;
  final counts = member && !unaccepted;
  return ConversationSecurity(
    state: s,
    canSend: usable && !blocked,
    canReset: usable && !sent && state.canReset,
    sentRequest: sent,
    myDevices: counts ? state.myDeviceCount : 0,
    theirDevices: counts ? state.theirDeviceCount : 0,
  );
}

/// A stored message row as the port's entry. Gate item 26: the stored check
/// `badReportKey` (a matching commitment over content whose report key has
/// the wrong length) is `unverified`, as a real mismatch is, and the port's
/// `checkDetail` tells the two apart (port additions; owner decision b: the
/// report sheet's "couldn't confirm" sentence is for a real mismatch only).
/// A stored name this build does not know is a mismatch (fail closed: the
/// sentence stays). Text and shared post only for a visible row whose check
/// is ok and whose bytes decode; `canReport` for the peer's visible row
/// whose bytes are here.
DecryptedMessage entryOfStored(StoredMessage row) {
  final state = _stateOf(row.state);
  final visible = state == EncryptedMessageState.visible;
  final content = row.content;
  var detail = switch (row.check) {
    StoredMessageCheck.ok => MessageCheckDetail.ok,
    StoredMessageCheck.undecodable => MessageCheckDetail.undecodable,
    StoredMessageCheck.badReportKey => MessageCheckDetail.badReportKey,
    _ => MessageCheckDetail.mismatch,
  };
  var text = '';
  var shared = '';
  if (visible && detail == MessageCheckDetail.ok) {
    final decoded = content == null
        ? null
        : decodeMessageContentLenient(content);
    if (decoded == null || !decoded.wireOk) {
      detail = MessageCheckDetail.undecodable;
    } else {
      text = decoded.text;
      shared = decoded.sharedPostId;
    }
  }
  return DecryptedMessage(
    id: row.messageId,
    at: DateTime.fromMicrosecondsSinceEpoch(row.createdAtMicros, isUtc: true),
    mine: row.mine,
    state: state,
    check: detail.check,
    checkDetail: detail,
    text: text,
    sharedPostId: shared,
    canReport: !row.mine && visible && content != null,
  );
}

EncryptedMessageState _stateOf(String stored) => switch (stored) {
  StoredMessageState.visible => EncryptedMessageState.visible,
  StoredMessageState.removed => EncryptedMessageState.removed,
  StoredMessageState.deletedAccount => EncryptedMessageState.deletedAccount,
  _ => EncryptedMessageState.undecryptable,
};

/// A stored system row as the port's line; null when its content does not
/// decode or names a line this build does not know (never shown).
SystemLineEntry? lineOfStored(StoredMessage row) {
  final content = row.content;
  if (content == null) return null;
  final line = SystemLineContent.decode(content);
  if (line == null) return null;
  final kind = switch (line.line) {
    SystemLine.encryptionReset => SystemLineKind.encryptionReset,
    SystemLine.deviceAdded => SystemLineKind.deviceAdded,
    SystemLine.deviceRemoved => SystemLineKind.deviceRemoved,
    SystemLine.unknownDevice => SystemLineKind.unknownDevice,
    _ => null,
  };
  if (kind == null) return null;
  final side = switch (line.side) {
    MemberSide.mine => LineSide.mine,
    MemberSide.theirs => LineSide.theirs,
    MemberSide.unattributed => LineSide.unattributed,
    _ => null,
  };
  return SystemLineEntry(
    id: row.messageId,
    at: DateTime.fromMicrosecondsSinceEpoch(row.createdAtMicros, isUtc: true),
    kind: kind,
    side: side,
  );
}

/// Gate item 27: a message this device still holds and will try to decrypt
/// again: undecryptable, waiting, with no side, text or report.
DecryptedMessage entryOfDeferred(DeferredView view) => DecryptedMessage(
  id: view.id,
  at: DateTime.fromMicrosecondsSinceEpoch(view.atMicros, isUtc: true),
  mine: false,
  state: EncryptedMessageState.undecryptable,
  waitingToDecrypt: true,
);

/// The inbox preview of a conversation from its newest stored message row
/// (never a system row; the caller picks it). [genericOnly]: an unaccepted
/// incoming request (R10). `generic` with no row. Text: the first line, cut
/// to [kPreviewTextMax] characters (never inside a surrogate pair).
ConversationPreview previewOf(
  StoredMessage? newest, {
  required bool genericOnly,
}) {
  if (genericOnly || newest == null) {
    return const ConversationPreview(kind: PreviewKind.generic);
  }
  final e = entryOfStored(newest);
  final kind = switch (e.state) {
    EncryptedMessageState.removed => PreviewKind.removed,
    EncryptedMessageState.deletedAccount => PreviewKind.deletedAccount,
    EncryptedMessageState.undecryptable => PreviewKind.undecryptable,
    EncryptedMessageState.visible => switch (e.check) {
      MessageCheck.unverified => PreviewKind.unverified,
      MessageCheck.undecodable => PreviewKind.undecodable,
      MessageCheck.ok =>
        e.sharedPostId.isNotEmpty ? PreviewKind.sharedPost : PreviewKind.text,
    },
  };
  if (kind != PreviewKind.text) {
    return ConversationPreview(kind: kind, mine: e.mine);
  }
  // Branch review n3: the first line that is not blank, trimmed ('' when
  // every line is blank).
  final firstLine = e.text
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  final runes = firstLine.runes;
  final text = runes.length <= kPreviewTextMax
      ? firstLine
      : String.fromCharCodes(runes.take(kPreviewTextMax));
  return ConversationPreview(kind: kind, text: text, mine: e.mine);
}

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
/// network) is shown as a retry, with no error carried. 13b-i review M2:
/// an account check (restricted, email not verified) is lasting: tapping
/// retry would fail the same way, so the row says why.
bool _lasting(AppException e) => switch (e) {
  CannotMessageException() ||
  FeatureDisabledException() ||
  LimitReachedException() ||
  QuotaExceededException() ||
  NotFoundException() ||
  ValidationException() ||
  EncryptionRequiredException() ||
  AccountRestrictedException() ||
  EmailNotVerifiedException() => true,
  _ => false,
};
