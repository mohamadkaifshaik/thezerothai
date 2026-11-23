part of 'message_receiver.dart';

// The receiver's value types and stateless helpers, moved unchanged out of
// message_receiver.dart (Task 12 review M6: that file was over the size
// limit).

/// What one receive pass ended with (§2). `complete`: the since token is
/// saved (or already stored), no walk has pages left, and the reconcile
/// entry has no work left (it is null, or was disarmed in this pass): never
/// while a tombstone listing has pages left or only waits for a since
/// token. A pass of a conversation with NO final group is `complete` once
/// its leftover undecryptable walks have ended and no reconcile entry
/// stands; while one stands with its listing at the end (no walk of such a
/// conversation saves the since token that would disarm it) the pass is
/// `stopped` for one walk backoff. `more`: work is left (the allowance was
/// spent, a page was discarded, a token was retired, a listing reached its
/// end before a since token was saved); `held`: rate limited or the budget
/// is paused, until [until]; `stopped`: a failure or a backoff, not before
/// [until]. Never names a conversation, a message or a key.
class ReceiveOutcome {
  const ReceiveOutcome._(this.kind, this.until);

  static const ReceiveOutcome complete = ReceiveOutcome._(
    ReceiveOutcomeKind.complete,
    null,
  );
  static const ReceiveOutcome more = ReceiveOutcome._(
    ReceiveOutcomeKind.more,
    null,
  );

  factory ReceiveOutcome.held(DateTime until) =>
      ReceiveOutcome._(ReceiveOutcomeKind.held, until);

  factory ReceiveOutcome.stopped(DateTime until) =>
      ReceiveOutcome._(ReceiveOutcomeKind.stopped, until);

  final ReceiveOutcomeKind kind;
  final DateTime? until;

  @override
  String toString() => 'ReceiveOutcome(${kind.name})';
}

enum ReceiveOutcomeKind { complete, more, held, stopped }

/// `created_at`, then id.
void _sort(List<pb.Message> messages) {
  messages.sort((a, b) => _posOf(a).compareTo(_posOf(b)));
}

/// A message's listing position (`created_at` micros, then id).
WalkPos _posOf(pb.Message m) => WalkPos(_createdMicros(m), m.id);

/// The largest whole second whose microseconds stay exact on the web
/// (below 2^53).
final Int64 _maxSeconds = Int64(9007199254);

/// A server time in microseconds since the epoch; null when it is not a
/// time this client holds exactly (negative, nanos out of range, or above
/// [kMaxPairComponent] = 2^53 - 1 microseconds, the bound the receive
/// record's decoder holds a position time to). Never throws (a server value
/// never reaches `DateTime`).
int? _micros(Int64 seconds, int nanos) {
  if (seconds.isNegative || seconds > _maxSeconds) return null;
  if (nanos < 0 || nanos > 999999999) return null;
  // At most 9007199254 * 10^6 + 999999, below 2^63: exact on the VM; on
  // the web a result above 2^53 may round, but stays above the bound.
  final micros = seconds.toInt() * 1000000 + nanos ~/ 1000;
  return micros > kMaxPairComponent ? null : micros;
}

/// A message's `created_at` in microseconds: 0 (the oldest possible) when it
/// is unset or out of range, so such a message sorts first and is hidden by
/// any `cleared_at`. An ordered epoch page never carries an out-of-range
/// time (the order check refuses the page), so a recorded position always
/// decodes.
int _createdMicros(pb.Message m) =>
    m.hasCreatedAt() ? _micros(m.createdAt.seconds, m.createdAt.nanos) ?? 0 : 0;

/// [m]'s `created_at` is unset or a time [_micros] holds.
bool _timeConverts(pb.Message m) =>
    !m.hasCreatedAt() ||
    _micros(m.createdAt.seconds, m.createdAt.nanos) != null;

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

enum _Mode { live, epoch, undecryptable }

/// `wrote`: one transaction ran; `skipped`: nothing was written; `later`: a
/// pair above the group's (live only); `stop`: the batch ends here.
enum _Step { wrote, skipped, later, stop }

/// A since token to save, only when the stored token is still [expect].
typedef _TokenSave = ({String token, String expect});

/// What a page's last transaction writes besides its message, computed in
/// the write body from the record read fresh there: the record and a since
/// token (§4 rule 2). Null: the walk's entry is no longer the one the page
/// was listed for; write nothing. (The page that ends a close or orphan
/// walk has no such update: its end is a transaction of its own, after the
/// final attempts of its deferred messages.)
typedef _RecordUpdate =
    Future<({ReceiveRecord record, String? sinceToken})?> Function(
      SecureVault v,
      ConversationSync sync,
    );

class _BatchEnd {
  const _BatchEnd({
    required this.completed,
    required this.waitingForWelcome,
    required this.caughtUp,
  });

  final bool completed;
  final bool waitingForWelcome;

  /// The batch ran its one catch-up (a message of a later pair).
  final bool caughtUp;
}

/// The vault the operation started with is no longer the session's.
/// Carries nothing.
class _Stopped implements Exception {
  const _Stopped();
}

/// One operation's vault, user and device; no `toString`.
class _Pass {
  _Pass(this.session, this.vault, this.uid, this.deviceId)
    : deviceGeneration = deviceGenerationOf(vault);

  final VaultSession session;
  final SecureVault vault;
  final String uid;
  final Uint8List deviceId;

  /// The vault's device generation when the pass started (Task 12 fix
  /// round 1, I2: a body after "set up again" writes nothing).
  final int deviceGeneration;

  bool get live {
    final v = session.vault;
    return identical(v, vault) && v?.uid == uid;
  }

  /// The first thing every runWrite body does.
  void check(SecureVault v) {
    if (!identical(v, vault) ||
        v.uid != uid ||
        !live ||
        deviceGenerationOf(v) != deviceGeneration) {
      throw const _Stopped();
    }
  }
}

/// The one transaction of one message, inside its runWrite body: the row
/// (dropped at or before cleared_at), the group state, the outbox delete,
/// the sync record (a since token, "epoch must advance"), the receive record
/// and the deferred record, all read or computed fresh in that body.
/// No `toString`.
class _Write {
  _Write(
    this.vault,
    this.id,
    this.sync,
    this.token,
    this.hidden,
    this.record,
    this.onTokenSaved,
  );

  final SecureVault vault;
  final String id;
  final ConversationSync sync;
  final String? token;
  final bool hidden;
  final ReceiveRecord? record;

  /// Called with the since token a transaction of [commit] saved over
  /// [sync]'s, once that transaction committed.
  final void Function(String token) onTokenSaved;

  /// [deferred]: the deferred record to write (an item added or removed
  /// with this message); [rows]: rows of other messages that end with this
  /// transaction (an evicted deferred item; the caller already left out any
  /// that is stored or hidden); [recordOverride]: the receive record to
  /// write instead of [record] (the same record with its group failure
  /// count changed). Each sealed setting is written at most once.
  Future<_Step> commit({
    StoredMessage? row,
    GroupRecord? group,
    String? deleteOutbox,
    (String, String)? tombstone,
    bool epochMustAdvance = false,
    DeferredRecord? deferred,
    List<StoredMessage> rows = const [],
    ReceiveRecord? recordOverride,
  }) async {
    final keptRow = hidden ? null : row;
    final newRecord = recordOverride ?? record;
    // An answer without a since token keeps the stored one.
    final newToken = token != null && token!.isNotEmpty ? token : null;
    final needSync =
        (newToken != null && newToken != sync.sinceToken) ||
        (epochMustAdvance && !sync.epochMustAdvance);
    if (keptRow == null &&
        group == null &&
        deleteOutbox == null &&
        tombstone == null &&
        newRecord == null &&
        deferred == null &&
        rows.isEmpty &&
        !needSync) {
      return _Step.skipped;
    }
    await vault.transaction((tx) async {
      if (group != null) await tx.putGroup(group);
      if (keptRow != null) await tx.putMessage(keptRow);
      for (final other in rows) {
        await tx.putMessage(other);
      }
      if (tombstone != null) {
        await tx.setMessageState(id, tombstone.$1, tombstone.$2);
      }
      if (deleteOutbox != null) await tx.deleteOutbox(deleteOutbox);
      if (deferred != null) {
        await tx.putSetting(DeferredRecords.keyOf(id), deferred.encode());
      }
      if (newRecord != null) {
        await tx.putSetting(ReceiveRecords.keyOf(id), newRecord.encode());
      }
      if (needSync) {
        await tx.putConversationSync(
          id,
          sync.copyWith(
            sinceToken: newToken,
            epochMustAdvance: epochMustAdvance ? true : null,
          ),
        );
      }
    });
    if (newToken != null && newToken != sync.sinceToken) {
      onTokenSaved(newToken);
    }
    return _Step.wrote;
  }
}
