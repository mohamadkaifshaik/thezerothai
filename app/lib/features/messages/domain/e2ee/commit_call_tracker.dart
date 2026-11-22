import 'dart:async';
import 'dart:typed_data';

import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../data/messaging_repository.dart';
import 'pipeline_support.dart';

/// The longest a server-chosen retry time holds a pending commit (review
/// m9, ruling R3). `retryAfterOf` allows a day (`kMaxServerRetryWait`),
/// which is right for one outbox row; a pending commit holds every send of
/// its conversation, so a hostile or broken retry time must not hold them
/// for a day. After [kRequestInFlightMargin] the catch-up proof decides
/// anyway. Cost: a few more counted calls, bounded by the daily cap.
const Duration kCommitRetryWaitMax = Duration(minutes: 5);

/// What counting one more `CommitConversation` call ended with
/// ([countCommitCall]).
enum CommitCallCount { counted, atCap }

/// The `CommitConversation` calls made in a conversation today (the
/// server's day, IST), from its sync record.
int commitCallsToday(ConversationSync sync, DateTime now) =>
    sync.commitCallsDay == istDay(now) ? sync.commitCallsToday : 0;

/// One more `CommitConversation` call of [conversationId] is about to be
/// made: counted first, in its own `runWrite` body and transaction, so a
/// crash never undercounts. `atCap`: [cap] calls were made today, nothing
/// is written and no call may be made. Throws when nothing could be written
/// (that says nothing about the cap: the caller makes no call then).
///
/// Task 10 amendment 1: one body for the commit runner's resends (Task 9)
/// and the reset's (Task 10).
Future<CommitCallCount> countCommitCall({
  required VaultSession session,
  required PipelineOp op,
  required String conversationId,
  required int cap,
  required DateTime Function() now,
}) => session.runWrite((v) async {
  op.check(v);
  final sync =
      (await v.conversation(conversationId))?.sync ?? const ConversationSync();
  final calls = commitCallsToday(sync, now());
  if (calls >= cap) return CommitCallCount.atCap;
  await v.transaction(
    (tx) => tx.putConversationSync(
      conversationId,
      sync.copyWith(commitCallsDay: istDay(now()), commitCallsToday: calls + 1),
    ),
  );
  return CommitCallCount.counted;
});

/// What this run knows about the `CommitConversation` calls of one pending
/// commit per conversation (Task 9 review I1, I2 and audit M2), so that a
/// decision resting on "the server does not hold it" (a discard, "another
/// commit won") is made only when no call of those bytes can still be
/// stored. Memory of this run only; nothing here is a fact a write relies
/// on.
///
/// Task 10 amendment 1: the commit runner (Task 9) and the reset (Task 10)
/// each hold one, so the two follow ONE set of rules:
///
/// - **The margin.** A record's margin counts from the latest of: the last
///   call of its bytes in this run ([noteCall]), the moment this run first
///   saw the record ([noteSeen]: every call of an earlier run was made
///   before it), and the real end of a call that outlived the client's
///   wait. A "not stored" read is trusted only when [kRequestInFlightMargin]
///   had passed when its listing STARTED (`provedAt`, review N1;
///   [marginLeft]).
/// - **Abandoned calls** (audit M2, `MessagingRepository.abandonedMlsCall`):
///   while one still runs nothing is decided ([callStillOut]); its end moves
///   the margin's start and, when none is left running, calls the caller's
///   `onAllEnded` (which schedules the resume that decides).
/// - **Spaced resends** after an unknown outcome ([noteUnknown]): nothing is
///   sent before the server's retry time, at most [kCommitRetryWaitMax],
///   else [kRequestInFlightMargin] after that outcome ([heldBack]).
///
/// Defines no `toString`.
class CommitCallTracker {
  CommitCallTracker({
    required MessagingRepository messaging,
    required DateTime Function() now,
  }) : _messaging = messaging,
       _now = now;

  final MessagingRepository _messaging;
  final DateTime Function() _now;

  /// Conversation -> the pending commit this run last dealt with there and
  /// the time its margin counts from.
  final Map<String, _MarginStart> _starts = {};

  /// Conversation -> no call before this time.
  final Map<String, DateTime> _notBefore = {};

  /// The time before which no call of [conversationId]'s pending commit is
  /// made; null when this run holds none.
  DateTime? notBefore(String conversationId) => _notBefore[conversationId];

  /// Whether [conversationId]'s next call must still wait ([notBefore]).
  bool heldBack(String conversationId) {
    final at = _notBefore[conversationId];
    return at != null && _now().isBefore(at);
  }

  /// A call got an unknown outcome: no call before the server's retry time
  /// [named] (at most [kCommitRetryWaitMax]), or, when it named none,
  /// before [kRequestInFlightMargin] from now (review I2: else every resume
  /// is one more counted call while the RPC times out). Returns the wait.
  Duration noteUnknown(String conversationId, Duration? named) {
    final wait = named == null
        ? kRequestInFlightMargin
        : (named > kCommitRetryWaitMax ? kCommitRetryWaitMax : named);
    _notBefore[conversationId] = _now().add(wait);
    return wait;
  }

  /// This run meets [commit] as [conversationId]'s pending record: its
  /// margin counts from now when this run has no call time for it.
  void noteSeen(String conversationId, Uint8List commit) {
    final start = _starts[conversationId];
    if (start == null || !_same(start.commit, commit)) {
      _starts[conversationId] = _MarginStart(commit, _now());
    }
  }

  /// A call of [commit] starts now: its margin counts from now; what this
  /// run knows of earlier calls of the same bytes still running is kept.
  void noteCall(String conversationId, Uint8List commit) {
    final start = _starts[conversationId];
    if (start == null || !_same(start.commit, commit)) {
      _starts[conversationId] = _MarginStart(commit, _now());
    } else if (_now().isAfter(start.at)) {
      start.at = _now();
    }
  }

  /// Audit M2: the call under [key] got no answer in the client's wait.
  /// When it still runs, the margin waits for its end; then the margin
  /// counts from that end and, once no call of [commit] runs any more,
  /// [onAllEnded] is called (outside any zone the caller holds a lock in:
  /// it runs from the call's own completion). An end after the record was
  /// forgotten ([forget], [clear]) or replaced changes nothing.
  void trackAbandoned(
    String conversationId,
    Uint8List commit,
    String key,
    void Function() onAllEnded,
  ) {
    final call = _messaging.abandonedMlsCall(key);
    final start = _starts[conversationId];
    if (call == null || start == null || !_same(start.commit, commit)) return;
    start.running++;
    unawaited(
      call.then((_) {
        if (!identical(_starts[conversationId], start)) return;
        start.running--;
        if (_now().isAfter(start.at)) start.at = _now();
        if (start.running == 0) onAllEnded();
      }),
    );
  }

  /// Whether a call of [commit] that outlived the client's wait still runs
  /// (it may not even have left the client yet).
  bool callStillOut(String conversationId, Uint8List commit) {
    noteSeen(conversationId, commit);
    return _starts[conversationId]!.running > 0;
  }

  /// Null when [commit]'s margin had passed at [provedAt] (the start of the
  /// listing a decision rests on). Otherwise the wait until its end from
  /// now: zero when the end lies between [provedAt] and now.
  Duration? marginLeft(
    String conversationId,
    Uint8List commit,
    DateTime provedAt,
  ) {
    noteSeen(conversationId, commit);
    final end = _starts[conversationId]!.at.add(kRequestInFlightMargin);
    if (!provedAt.isBefore(end)) return null;
    final now = _now();
    return now.isBefore(end) ? end.difference(now) : Duration.zero;
  }

  /// Whether this run met [commit] as [conversationId]'s pending record (it
  /// was seen, or a call of it was made). Task 10 review m-2: a reset this
  /// run built and nothing met yet still needs its first call.
  bool knows(String conversationId, Uint8List commit) {
    final start = _starts[conversationId];
    return start != null && _same(start.commit, commit);
  }

  /// The pending record of [conversationId] is gone (settled or
  /// discarded).
  void forget(String conversationId) {
    _notBefore.remove(conversationId);
    _starts.remove(conversationId);
  }

  /// Sign-out or a new vault: everything is forgotten.
  void clear() {
    _notBefore.clear();
    _starts.clear();
  }
}

/// A pending commit's bytes and the time its margin counts from. No
/// `toString`.
class _MarginStart {
  _MarginStart(this.commit, this.at);

  final Uint8List commit;
  DateTime at;

  /// Calls of these bytes that outlived the client's wait and have not
  /// ended yet (audit M2): while one runs, no margin has started.
  int running = 0;
}

/// Constant-time equality of two byte lists (the length is not secret).
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
