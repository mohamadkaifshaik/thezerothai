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

  /// The sink left a close (or orphan) walk unfinished: the next pass
  /// continues it without the lock.
  bool epochWalkPending = false;

  /// An unprocessed probe page held a message of a pair above the group's
  /// (its since token may be saved past it): the end of a pass runs one
  /// catch-up until one answers other than `interrupted`.
  bool laterPairSeen = false;

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

  /// Sign-out or a new vault.
  void clear() => _byId.clear();
}
