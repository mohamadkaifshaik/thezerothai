import '../../../../core/crypto/mls_pair.dart';
import '../../../../gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import '../../../../gen/dzeroth/messaging/v1/messaging.pbenum.dart';

/// Memory-only facts per conversation, reset at sign-out and on a new vault.
/// Nothing here is persisted: after a restart every field starts again, which
/// only ever delays a decision (a removal, a send), never advances it. No
/// `toString` (it holds a user reference and device ids).
class ConversationContext {
  /// The reference exactly as the client holds it; never logged.
  String? peerUserId;

  /// Null: not known yet (treated as an unaccepted incoming request).
  bool? incomingRequest;
  bool canReply = true;

  /// The removal clock: when this run first knew the conversation accepted.
  DateTime? acceptedSeenAt;

  /// R7: commits applied to the server's current pair AND attribution complete
  /// AND (security read M10) one `pullLive` of the current pair completed since
  /// the last start.
  bool syncedSinceStart = false;

  /// M10: the pair of the last completed `pullLive` this run; null at start.
  MlsPair? livePulledAt;

  /// M4: first deferred list met while a member is unattributed.
  DateTime? deferredSince;

  /// A new member has not been attributed with usable lists yet.
  bool attributionPending = false;

  /// M2: the last attribution or reconciliation met an unreadable list.
  bool listUnverifiable = false;

  /// Device id hex -> time first seen unattributed.
  final Map<String, DateTime> firstSeenUnattributed = {};

  /// Device id hex -> `fetchedAt` of the first counting miss.
  final Map<String, DateTime> firstMiss = {};
  bool clearedAtReadThisRun = false;

  /// A remembered stuck answer of the last catch-up (memory only: a restart
  /// finds out again at the next catch-up).
  bool stuck = false;

  /// Device id hexes met unknown in this run (for `unknownDevicePresent`).
  final Set<String> unknownDevices = {};

  /// Device id hex -> pair at which an `unknownDevice` row was written this
  /// run (once per device and pair).
  final Set<String> unknownRowsWritten = {};

  /// A member was concluded (attributed or flagged) in this run for the
  /// current pair, so [attributeMembers] need not run again.
  bool attributionConcluded = false;

  /// The time of the one scheduled re-attribution, when a peer fetch did not
  /// count yet.
  DateTime? reattributeAt;

  /// The server's current pair as the last catch-up pass of this run read
  /// it; null before one (`describeState`'s "server's last known
  /// generation").
  MlsPair? serverPair;

  // --- the receiver's walks (design rev 3 §2-§5; memory only) -------------

  /// The receive pass running now (single flight): a second `pullLive`
  /// joins it. The receiver types it; null when none runs.
  Future<Object?>? running;

  /// Bumped by every write of the receive record (step 2's reconcile page
  /// must bump it too); a page listed without the lock is applied only when
  /// it is unchanged.
  int serial = 0;

  /// The since token of the last probe page that was not processed, with
  /// the stored token it was asked with and when it was fetched (the
  /// receiver's call sequence). Saved by §4 rule 2 only.
  ({String token, String sentWith, int seq})? endToken;

  /// The sequence number of the open walk's last listing start this run.
  int? openListingSeq;

  /// The sink refused or left a close (or orphan) walk unfinished, so a
  /// catch-up ended `interrupted` with a commit waiting at this pair (the
  /// highest group pair any such signal saw; the sink's own pair when the
  /// group's was not known): once no walk of the current or a later pair is
  /// left, the end of a pass runs one catch-up. Cleared when one answers
  /// other than `interrupted`, or once the group's current pair is strictly
  /// past it (the fast path or another catch-up applied the commit). Not
  /// cleared when an older walk ends (the commit that waited for it is
  /// still unapplied). Null: none due.
  MlsPair? catchUpDueAt;

  /// The highest pair above the group's that an unprocessed probe page held
  /// (its since token may be saved past it): the end of a pass runs one
  /// catch-up while the current pair is below it, until one answers other
  /// than `interrupted`. Null: none.
  MlsPair? laterPairSeen;

  /// The group pair at which the end-of-pass catch-up last applied nothing
  /// and left no walk: a second such run at the same pair waits twice as
  /// long, doubling up to the walk backoff's cap. Reset (with the two
  /// fields below) when the pair moves, or a catch-up there applies
  /// something or leaves a walk; never by a pass that returns `complete`.
  /// Null: no streak.
  MlsPair? fruitlessCatchUpAt;

  /// The end-of-pass catch-up's own wait (never the walks'): no end-of-pass
  /// catch-up before [catchUpNotBefore]; [catchUpBackoff] is the last wait
  /// of the streak. The walks and the sink are not held by it.
  DateTime? catchUpNotBefore;
  Duration? catchUpBackoff;

  /// The walk backoff after an order violation, a missing order echo, an
  /// RPC failure or the restart cap: no walk before [walkBackoffUntil];
  /// [walkBackoff] doubles from 1 min to 1 h, reset by an applied page.
  DateTime? walkBackoffUntil;
  Duration? walkBackoff;

  /// Refused page tokens this run (at most 2 restarts, §3.2).
  int walkRestarts = 0;

  /// Counters of this run: pages without the order echo, pages out of
  /// order, and pages listed without the lock that were discarded.
  int orderMissing = 0;
  int orderViolation = 0;
  int discardedPages = 0;

  // --- the receiver's reconcile walk (design rev 3 §8.2; memory only) -----

  /// No tombstone listing before this time (a refused, failed or
  /// out-of-order listing); [reconcileBackoff] is its last wait, 1 min
  /// doubling to 1 h, reset by an applied page. The failures that bound a
  /// final attempt's wait are counted in the sealed receive record, not
  /// here. The probe and the walks are not held by it.
  DateTime? reconcileNotBefore;
  Duration? reconcileBackoff;

  /// Counters of this run: tombstone pages refused for their shape or
  /// order, and tombstone pages listed without the lock that were
  /// discarded.
  int reconcileViolation = 0;
  int reconcileDiscarded = 0;

  // --- the receiver's failure rule (design rev 3 §7; memory only) ---------

  /// No engine call of the receiver for THIS conversation before this time:
  /// a group-level failure stopped a pass (1 min, doubling with the group
  /// failure count). Device-level trouble (a device-down answer, the
  /// breaker, an unwitnessed crash) is held receiver-wide, in the receiver.
  /// Cleared when the app resumes.
  DateTime? engineHoldUntil;

  /// Message id -> state (`removed` / `deletedAccount`) of every tombstone
  /// seen this run, oldest first, bounded: a deferred message whose id is
  /// here is never given to the engine again (§7.4 check 2, §8.1).
  final Map<String, String> tombstoned = {};

  /// `generation:epoch` -> the receiver's run id in which that group
  /// reached the group failure maximum: for the rest of that run its
  /// `internal` / `deadline` answers become rows with no probe (§7.2).
  final Map<String, String> groupBroken = {};

  /// `generation:epoch` -> the receiver's run id in which a `process` call
  /// on that group last succeeded: the witness that the group itself works,
  /// without which a full deferred record never evicts (a ruling after the
  /// design, fix round 1).
  final Map<String, String> groupWorked = {};

  /// Message id -> the receiver's count of engine successes when that
  /// message was deferred unwitnessed this run (§7.2): once the count has
  /// grown, the end of a pass promotes it.
  final Map<String, int> unwitnessed = {};

  /// A hint, never a fact a write relies on: the deferred record was read
  /// or written empty by this run's last pass (then a walk does not open
  /// it again for every message). Null: not known.
  bool? deferredEmpty;

  /// A hint: the receive record's group failure count was read or written
  /// null this run (then a process success does not read it again). Null:
  /// not known.
  bool? groupFailuresNull;

  /// How many times the walk backoff was raised this run (every order
  /// violation, missing order echo or restart cap; never an RPC failure).
  /// The receiver reads it around a walk step to tell the walk's own
  /// refusal from a failed or rate-limited call; the refusals that lead to
  /// an abandonment are counted in the sealed receive record, not here.
  int walkBackOffs = 0;
}

/// The [ConversationContext] of every conversation, by id.
class ConversationContexts {
  final Map<String, ConversationContext> _byId = {};

  ConversationContext of(String conversationId) =>
      _byId.putIfAbsent(conversationId, ConversationContext.new);

  /// Takes the facts a conversation header row carries. Never sets
  /// `acceptedSeenAt` (the caller owns the clock).
  void note(pb.Conversation row) {
    if (row.id.isEmpty) return;
    final c = of(row.id);
    if (row.hasPeer() && row.peer.userId.isNotEmpty) {
      c.peerUserId = row.peer.userId;
    }
    if (row.folder == Folder.FOLDER_REQUESTS) {
      c.incomingRequest = true;
    } else if (row.folder == Folder.FOLDER_INBOX) {
      c.incomingRequest = false;
    }
    c.canReply = row.canReply;
  }

  /// The app resumed: no conversation's own engine hold is kept.
  void clearEngineHolds() {
    for (final c in _byId.values) {
      c.engineHoldUntil = null;
    }
  }

  /// Sign-out or a new vault.
  void clear() => _byId.clear();
}
