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
