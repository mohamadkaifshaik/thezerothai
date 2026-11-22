part of 'group_starter.dart';

// Routing: where a first message goes ([GroupStarter.startOrRoute]), what
// it answers, and the draft a start is made with. Moved from
// `group_starter.dart` unchanged (Task 10's file-size rule).

/// What [GroupStarter.startOrRoute] did with a first message.
///
/// `started`: this device created a provisional group; the row is saved and
/// its init is being sent. `joinedExisting`: the conversation is (or was
/// ever) encrypted here; the row is saved with the sender and goes out, or
/// waits. `plaintext`: nothing is saved; the caller sends it in plaintext.
/// Every other value: nothing is saved and nothing is sent.
/// `lookupFailed` (security read H1): the peer's list could not be read;
/// `cause` carries a [CannotMessageException] when the lookup answered
/// CANNOT_MESSAGE, and a failed claim's error.
enum StartResult {
  started,
  joinedExisting,
  plaintext,
  peerHasNoDevice,
  tryAgainTomorrow,
  unavailable,
  lookupFailed,
}

/// What [GroupStarter.startOrRoute] answered. Review M9: a class, not the
/// brief's record: a record's built-in `toString` prints the conversation
/// id, and no scan sees a record. It defines no `toString`.
class StartOutcome {
  const StartOutcome({required this.result, this.conversationId, this.cause});

  final StartResult result;

  /// The conversation the row was saved for; null when nothing was saved.
  final String? conversationId;

  /// The typed error behind `lookupFailed` and `tryAgainTomorrow`.
  final AppException? cause;
}

/// The server's deterministic id of the 1:1 conversation of the raw uids
/// [a] and [b] (`backend/internal/messaging/model.go`, `ConversationID`):
/// the first 32 lower-case hex characters of SHA-256 of
/// `"dm1|" + lo + "|" + hi`, the uids in byte order (uids are ASCII, so
/// `String.compareTo` is byte order). Only for raw uids: a public id gives
/// another value.
String dmConversationId(String a, String b) {
  final swap = b.compareTo(a) < 0;
  final lo = swap ? b : a;
  final hi = swap ? a : b;
  return sha256.convert(utf8.encode('dm1|$lo|$hi')).toString().substring(0, 32);
}

/// The shape of a public user id (`backend/internal/identity/publicid.go`,
/// `ValidPublicID`): `u`, then 26 characters of the lower-case Crockford
/// alphabet, the first one 0-7.
final RegExp _publicIdShape = RegExp(r'^u[0-7][0-9a-hjkmnp-tv-z]{25}$');

/// Task 8 audit M2 (iii): whether two user references are of the same id
/// kind (both public ids, or both raw uids). A raw uid is
/// `[A-Za-z0-9-]{1,128}` (`backend/pkg/platform/ids`); it can take the
/// public shape only by chance, and then reads as one (compared: fail
/// closed).
bool sameIdKind(String a, String b) =>
    _publicIdShape.hasMatch(a) == _publicIdShape.hasMatch(b);

/// The body of [GroupStarter.startOrRoute] (its contract is written there).
extension _Route on GroupStarter {
  Future<StartOutcome> _route({
    required String localId,
    required String peer,
    required String? conversationId,
    required String text,
    required String sharedPostId,
  }) async {
    final vault = _session.vault;
    // Review I1. Decision: a vault exists on this device and cannot be
    // asked now (opening, a key outage, a lost lock): its known set is the
    // only record that a conversation is encrypted, so nothing is routed
    // without it. Never plaintext, whatever the flag says; with no vault
    // on the device at all the flag decides as before (R1's inertness).
    //
    // Review N2. Decision: "no vault on the device" is taken only from a
    // session that SAYS so (status `off`, or `unsupported`: no vault can
    // exist on this platform). `vaultKnown` is false as well when the
    // marker could not be read (status `unavailable`), and a vault that
    // may exist is treated as one that does: never plaintext in doubt.
    if (vault == null) {
      final status = _session.status.value;
      if (_session.vaultKnown ||
          (status != VaultStatus.off && status != VaultStatus.unsupported)) {
        return _out(StartResult.unavailable);
      }
    }
    if (vault != null && !_known.isLoadedFor(vault)) await _known.load(vault);

    // 1. Known first (security read C1): the known set and the cache's
    // sticky marker are asked BEFORE the flag and before any lookup.
    String? known;
    if (conversationId != null) {
      // Task 8 audit M2 (iii). Decision: a known id whose stored peer ref is
      // of the same id kind as [peer] and names someone else is not routed
      // to: `unavailable`, nothing saved, nothing plaintext. Why: the row
      // would be encrypted to the stored peer's devices, a person the
      // caller did not address. A ref of the other id kind cannot be
      // compared (audit L8, a stated limit): routed as before.
      final stored = _known.contains(conversationId)
          ? _known.peerOf(conversationId)
          : null;
      if (stored != null && stored != peer && sameIdKind(stored, peer)) {
        return _out(StartResult.unavailable);
      }
      if (_known.contains(conversationId) ||
          await _messaging.cachedEverEncrypted(conversationId)) {
        known = conversationId;
      } else if (vault != null &&
          await _known.conversationForPeer(vault, peer) != null) {
        // Review M2. Decision: the id is not known, but the vault stores
        // this peer for ANOTHER conversation. An honest server cannot
        // produce that (the id is deterministic): nothing is started and
        // nothing is plaintext.
        return _out(StartResult.unavailable);
      }
    } else if (vault != null) {
      known = await _known.conversationForPeer(vault, peer);
    }
    if (known != null) {
      final saved = await _viaSender(
        known,
        localId: localId,
        text: text,
        sharedPostId: sharedPostId,
      );
      // Review F1 (c): a new send is an explicit trigger. When the vault
      // shows this device was never a member (its own init was refused or
      // abandoned), encryption starts again here; else the row waits.
      if (saved.result == StartResult.joinedExisting) {
        await _restartKnown(known, peer);
      }
      return saved;
    }
    if (conversationId == null) {
      // Second re-read R1: a recipient the stored refs do not resolve,
      // whose cached row is of a conversation ever known as encrypted (the
      // stored ref and this one may be of different id kinds). Nothing is
      // started and nothing is plaintext.
      final row = await _messaging.cachedConversationWith(peer);
      if (row != null &&
          row.id.isNotEmpty &&
          (_known.contains(row.id) ||
              await _messaging.cachedEverEncrypted(row.id))) {
        return _out(StartResult.unavailable);
      }
    }

    // 2. A device whose flag is off or unknown never claims or inits.
    if (!_session.mayStart) return _plaintextUnlessKnown(conversationId, peer);
    // The flag is on but nothing can be started here now (no usable vault
    // or engine, or this device was removed elsewhere). Decision: never
    // plaintext in doubt; the caller may try again.
    if (vault == null || _removedElsewhere() || _engineDown()) {
      return _out(StartResult.unavailable);
    }

    // 3. The peer's device list (security read H1): plaintext ONLY on a
    // readable, empty answer.
    final list = await _directory.peer(peer, priority: BudgetPriority.user);
    switch (list.state) {
      case ListState.readable:
        if (list.devices.isEmpty) {
          return _plaintextUnlessKnown(conversationId, peer);
        }
      case ListState.unreadable:
        return _lookupFailed(peer);
      case ListState.deferred:
        // Review 3b, the brief as amended: deferred -> start only when the
        // last readable list is younger than `kDeviceListReuse`, else
        // `lookupFailed`. Here: no kept list, or an empty one, ends now;
        // a non-empty one lets the start's own fresh lookup try, and
        // [_lastReadable] refuses a kept list that is too old. Why: fail
        // closed; the old clause trusted a list of any age.
        if (list.fetchedAt == null || list.devices.isEmpty) {
          return _out(StartResult.lookupFailed);
        }
    }

    // The report key and the exact bytes are fixed here, once.
    final content = encodeMessageContent(
      text: text,
      sharedPostId: sharedPostId,
      reportKey: await _random(kReportKeyBytes),
    );
    final outcome = await _begin(
      peer,
      _Draft(
        localId: localId,
        content: content,
        text: text,
        sharedPostId: sharedPostId,
        recipient: conversationId == null ? peer : null,
        conversationId: conversationId,
      ),
    );
    final id = outcome.conversationId;
    if (outcome.result == StartResult.started && id != null) {
      _onChanged(id);
      // The init goes out after this call returned (it may take 30 s).
      unawaited(_resume(id, BudgetPriority.user));
    }
    return outcome;
  }

  /// A conversation this device ever knew as encrypted: the row goes to the
  /// sender under [id] (it is sent in an existing group, or waits for a
  /// welcome); never plaintext.
  Future<StartOutcome> _viaSender(
    String id, {
    required String localId,
    required String text,
    required String sharedPostId,
  }) async {
    if (_session.vault == null || _removedElsewhere() || _engineDown()) {
      return _out(StartResult.unavailable, id);
    }
    try {
      await _sender.enqueue(
        localId: localId,
        conversationId: id,
        text: text,
        sharedPostId: sharedPostId,
      );
    } on StateError {
      // The vault closed meanwhile: nothing was saved.
      return _out(StartResult.unavailable, id);
    }
    return _out(StartResult.joinedExisting, id);
  }

  /// An unreadable lookup: with the typed cause when it answered
  /// CANNOT_MESSAGE (the directory parks the peer then).
  StartOutcome _lookupFailed(String peer) => _out(
    StartResult.lookupFailed,
    null,
    _directory.isParked(peer) ? const CannotMessageException() : null,
  );

  /// Review M1. `plaintext`, unless the conversation is known NOW. The
  /// known check of step 1 and this answer are separated by awaits (a
  /// lookup of up to 30 s) in which a welcome can be joined: the
  /// synchronous part of step 1 is asked again right before answering,
  /// so the server's ENCRYPTION_REQUIRED is not what stops it.
  StartOutcome _plaintextUnlessKnown(String? conversationId, String peer) {
    final known =
        (conversationId != null && _known.contains(conversationId)) ||
        _known.ids.any((id) => _known.peerOf(id) == peer);
    return _out(known ? StartResult.unavailable : StartResult.plaintext);
  }
}

/// The first message of a start: a new draft, or the row [replaces] that
/// this start encrypts again: the waiting stage-plain row of a known
/// conversation ([_Mode.restart]), or the init row of the expired
/// provisional group the start replaces ([_Mode.replace]; that group is
/// not discarded first, it goes in the creating transaction). No
/// `toString`.
class _Draft {
  const _Draft({
    required this.localId,
    required this.content,
    this.text,
    this.sharedPostId = '',
    this.recipient,
    this.conversationId,
    this.replaces,
    this.createdAtMicros,
    this.expectId,
    this.replacesCommit,
  });

  final String localId;
  final Uint8List content;

  /// The typed text of a new draft (for the sender, when the conversation
  /// turns out to exist); null for a rebuild.
  final String? text;
  final String sharedPostId;

  /// The recipient reference exactly as sent, for a draft addressed by
  /// recipient; null for one addressed by [conversationId].
  final String? recipient;
  final String? conversationId;

  /// The key of the row this start encrypts again (it is replaced by a row
  /// under a NEW key in the same transaction): a stage-plain row
  /// ([_Mode.restart]), or the old init row ([_Mode.replace]).
  final String? replaces;
  final int? createdAtMicros;

  /// The conversation id the claim must answer, for a row addressed by
  /// recipient whose conversation is already known ([_Mode.replace]).
  final String? expectId;

  /// [_Mode.replace]: the pending commit of the provisional group this
  /// start replaces (the group is replaced only while it is still that one).
  final Uint8List? replacesCommit;
}

/// How a start treats what the vault already holds for the claim's id.
///
/// `fresh`: a first message; a known id or a stored group takes the row
/// instead. `restart`: a known conversation this device was never a member
/// of (review F1, option c). `replace`: the 24 h rebuild (review I3): the
/// old provisional group is replaced in the creating transaction.
enum _Mode { fresh, restart, replace }
