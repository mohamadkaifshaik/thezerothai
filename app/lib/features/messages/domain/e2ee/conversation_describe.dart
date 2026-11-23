part of 'conversation_crypto.dart';

/// The 5b state of one conversation ([ConversationCrypto.describeState]),
/// moved out of the library file to keep it under the size limit (Task 12,
/// a pure move).
extension _Describe on ConversationCrypto {
  Future<ConversationCryptoState> _describeState(String conversationId) async {
    final id = conversationId;
    final context = _contexts.of(id);
    final engine = _engine();
    final engineDown =
        engine is GuardedCryptoEngine && engine.unavailable.value;
    final vault = _session.vault;
    final List<GroupRecord> groups;
    final ConversationRecord? record;
    final List<MemberRecord> pins;
    try {
      if (vault == null) throw StateError('No vault.');
      groups = await vault.groups(id);
      record = await vault.conversation(id);
      pins = await vault.members(id);
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'describeState');
      return ConversationCryptoState(
        phase: ConversationPhase.notEncrypted,
        sendBlock: SendBlock.unavailable,
        requestAccepted: false,
        incomingRequest: context.incomingRequest ?? true,
        deviceListUnverifiable: false,
        unknownDevicePresent: false,
        committingPausedToday: false,
        unattributedPresent: false,
        myDeviceCount: 0,
        theirDeviceCount: 0,
        canReset: false,
      );
    }
    // The key history's state (a read only; false for both when it cannot
    // be read: the allowance is no exit from an unreadable history). No
    // lock is held here, so a first join can commit between these reads
    // and make the history look missing: this read never reports, and so
    // never spends the conversation's one `keyHistory.read` report.
    var keyHistoryClosed = false;
    var mayAllowMoreDevices = false;
    try {
      final history = await _keyHistory.of(
        vault,
        id,
        currentPins: pins,
        formerPins: await _formerPins.of(vault, id),
        report: false,
      );
      keyHistoryClosed = !history.unreadable && history.closed;
      mayAllowMoreDevices = history.mayAllowMore;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'describeState');
    }
    final sync = record?.sync ?? const ConversationSync();
    final accepted = sync.requestAccepted;
    GroupRecord? current;
    for (final group in groups) {
      if (!group.provisional) current = group;
    }
    final server = context.serverPair;
    final ConversationPhase phase;
    // The brief's order: a remembered stuck answer before a provisional
    // group.
    if (context.stuck) {
      phase = ConversationPhase.stuck;
    } else if (groups.any((x) => x.provisional)) {
      phase = ConversationPhase.provisional;
    } else if (current != null &&
        (server == null || current.generation >= server.generation) &&
        (sync.firstSawGeneration ?? 0) <= current.generation) {
      phase = ConversationPhase.ready;
    } else if (current != null || record != null || _known.contains(id)) {
      phase = ConversationPhase.waitingForWelcome;
    } else {
      phase = ConversationPhase.notEncrypted;
    }
    final unattributed = pins.any((p) => p.side == MemberSide.unattributed);
    final unknown =
        accepted &&
        pins.any(
          (p) =>
              p.side == MemberSide.unattributed &&
              context.unknownDevices.contains(vaultDeviceIdHex(p.deviceId)),
        );
    final now = _now();
    final unverifiable =
        context.listUnverifiable ||
        deferralOutlasted(
          deferredSince: context.deferredSince,
          unattributedPresent: unattributed,
          now: now,
        );
    final SendBlock block;
    if (engineDown) {
      block = SendBlock.unavailable;
    } else if (phase == ConversationPhase.stuck) {
      block = SendBlock.stuck;
    } else if (phase == ConversationPhase.waitingForWelcome) {
      block = SendBlock.waitingForWelcome;
    } else if (phase == ConversationPhase.provisional) {
      block = SendBlock.provisional;
    } else if (phase == ConversationPhase.notEncrypted) {
      block = context.canReply ? SendBlock.none : SendBlock.cannotMessage;
    } else if (unknown) {
      block = SendBlock.unknownDevice;
    } else if (sync.epochMustAdvance) {
      block = SendBlock.epochMustAdvance;
    } else if (!context.syncedSinceStart ||
        context.attributionPending ||
        unattributed) {
      block = SendBlock.notSynced;
    } else if (!context.canReply) {
      block = SendBlock.cannotMessage;
    } else {
      block = SendBlock.none;
    }
    final seenAt = sync.firstSawGenerationAtMicros;
    // M5: this device makes no membership commit here for the rest of the
    // IST day. A read only (`readLocked` with no transaction opens no write
    // and stores nothing). A ledger that cannot be asked reads as paused
    // (fail closed, as the ledger itself does for an unreadable value).
    var committingPaused = true;
    try {
      committingPaused =
          (await _ledger.readLocked(vault)).undoneIn(id) >=
          kAntiFlapUndosPerDay;
    } on Object catch (e, s) {
      _reportIfBug(e, s, 'describeState');
    }
    // Task 10, R12, the plan's "who may reset, and when": the flag is on
    // (a flag-off device never resets: it stays stuck and says so here),
    // the conversation is accepted, and one of: catch-up answered `stuck`;
    // waiting for a welcome for at least [kResetWaitWithoutWelcome] since
    // the first sighting of that generation (never earlier; a device that
    // recorded no sighting has no time to count from and waits); M5's
    // pause (`committingPausedToday`, the anti-flap offer). Decision: never
    // while a provisional group is stored (a reset or a start in progress:
    // a second reset would race the first, whose call may still land),
    // whatever the remembered stuck answer says. Audit M2 / L5: never while
    // this device is removed elsewhere (Task 12's seam: a removed device
    // must not reset itself back in) or the engine is unavailable (the
    // reset could not be built, and an automatic one would count an
    // attempt that cannot run).
    final resetAt =
        phase == ConversationPhase.waitingForWelcome && seenAt != null
        ? DateTime.fromMicrosecondsSinceEpoch(
            seenAt,
            isUtc: true,
          ).add(kResetWaitWithoutWelcome)
        : null;
    final canReset =
        _session.mayStart &&
        !_removedElsewhere() &&
        !engineDown &&
        accepted &&
        !groups.any((x) => x.provisional) &&
        (phase == ConversationPhase.stuck ||
            (resetAt != null && !now.isBefore(resetAt)) ||
            (committingPaused && phase != ConversationPhase.notEncrypted));
    return ConversationCryptoState(
      phase: phase,
      sendBlock: block,
      requestAccepted: accepted,
      incomingRequest: context.incomingRequest ?? !accepted,
      deviceListUnverifiable: unverifiable,
      unknownDevicePresent: unknown,
      committingPausedToday: committingPaused,
      unattributedPresent: unattributed,
      myDeviceCount: pins.where((p) => p.side == MemberSide.mine).length,
      theirDeviceCount: pins.where((p) => p.side == MemberSide.theirs).length,
      canReset: canReset,
      resetAllowedAt: resetAt,
      keyHistoryClosed: keyHistoryClosed,
      mayAllowMoreDevices: mayAllowMoreDevices,
    );
  }
}
