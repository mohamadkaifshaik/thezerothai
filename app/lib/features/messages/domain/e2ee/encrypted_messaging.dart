import 'package:flutter/foundation.dart';

import '../../../../core/network/app_exception.dart';
import '../../../../gen/dzeroth/common/v1/common.pb.dart' show AuthorSnapshot;
import 'message_content_codec.dart';

/// Which thread: an existing conversation, or a first message to a person (draft thread).
final class ThreadRef {
  const ThreadRef.conversation(String this.conversationId)
    : recipientUserId = null;

  /// Second re-read R1: the ONLY way to address a person. The ref is `AuthorSnapshot.user_id`, the same field (and
  /// so the same id kind) as a conversation header's `peer.userId`; no constructor takes a bare string for a person.
  factory ThreadRef.recipientOf(AuthorSnapshot person) =>
      ThreadRef._recipient(person.userId);
  const ThreadRef._recipient(String this.recipientUserId)
    : conversationId = null;
  final String? conversationId;
  final String? recipientUserId; // AuthorSnapshot.user_id of the person (R1), never another field

  @override
  bool operator ==(Object other) =>
      other is ThreadRef &&
      other.conversationId == conversationId &&
      other.recipientUserId == recipientUserId;

  @override
  int get hashCode => Object.hash(conversationId, recipientUserId);
}

/// The one state of a conversation's encryption on this device. Exactly one value at a time; when several
/// hold, the pipeline reports the first in this order.
enum ConversationEncryptionState {
  pendingRequest, // R10: an incoming request the user has not accepted. No lines, no code, no device state.
  waitingForDevice, // MP:186: this device has no group state and no usable welcome. Cannot send.
  stuck, // R7: lost pending commit or an unprocessable commit. Cannot send.
  changesBlocked, // M5: this device's add or remove was undone twice today. M5 stops this device's COMMITS
  // for the day; sends are blocked only while an unknown device is present (the usual case).
  // The pipeline reports this state with canSend TRUE when no member is unattributed:
  // screens decide the composer from `canSend`, never from this state. Reported BEFORE
  // unknownDevice, because the unknown device is usually still present when M5 fires and
  // only this state carries the offer (wait, block, reset).
  unknownDevice, // M2: an unattributed member. No sends, no code.
  listUnverifiable, // M2: a device list answered CANNOT_MESSAGE, FEATURE_DISABLED or a failure. Sends continue, no code.
  // Not reported for a routine GetKeyDevices cap or rate limit (pilot gate 5.2: keep the list, no
  // warning). One exception (security read M4): a list deferred for longer than 30 minutes while a
  // member of this conversation is unattributed is reported as listUnverifiable.
  peerHasNoDevice, // R11 / spec 7.4: reported ONLY when the conversation is already encrypted, or the peer's device
  // list is non-empty and no key package is usable. NEVER for a first message to a peer whose
  // list is empty: the server answers "no flag" and "flag but no device" identically, so that
  // message goes out as an ordinary not-encrypted message (`send` answers notEncrypted). Cannot send.
  sendPaused, // R7: the epoch must advance before the next encrypt. Typed text waits.
  syncing, // R7: not yet synced since start. Typed text waits.
  ready,
}

final class ConversationSecurity {
  const ConversationSecurity({
    required this.state,
    this.canSend = true,
    this.canReset = false,
    this.sentRequest = false,
    this.myDevices = 0,
    this.theirDevices = 0,
  });
  final ConversationEncryptionState state;
  final bool canSend; // false: the composer is replaced by the state's notice. The ONLY input to the composer
  // decision: a state does not imply a value (changesBlocked can come with canSend true).
  final bool canReset; // the contract and the flag allow THIS device to reset the conversation now
  // (stuck member; waiting 24 h; M5 offer). Always false with the flag not on, and always
  // false in a request this user sent (no commits, no reset there), even when stuck.
  final bool sentRequest; // the caller's own request, not yet accepted: no code and no device counts (gate 5.3)
  final int myDevices; // members pinned mine / theirs in the current group (R4); 0 when not a member
  final int theirDevices;
}

enum EncryptedMessageState { visible, undecryptable, removed, deletedAccount }

enum SendProgress { delivered, sending, waiting, notSent }

enum SendProblem {
  none,
  retryable, // a failed attempt the user may retry ("Not sent. Tap to retry"); as a `refused` outcome of
  // `send`: the device lookup of the start path could not be read, nothing was saved or sent
  // (security read H1)
  blocked, // the conversation cannot send now (unknownDevice, changesBlocked, stuck, waitingForDevice)
  peerHasNoDevice, // "They can't receive encrypted messages yet" (only where the state of that name is reported)
  tryTomorrow, // R6 step 4: the per-target claim cap ("Try again tomorrow")
  refused, // a definitive server refusal; [DecryptedMessage.error] carries the typed reason
}

enum SystemLineKind {
  encryptionReset,
  deviceAdded,
  deviceRemoved,
  unknownDevice,
}

enum LineSide { mine, theirs, unattributed }

/// One row of an encrypted thread. No subclass defines toString.
sealed class ThreadEntry {
  const ThreadEntry({required this.id, required this.at});
  final String id; // message id, the outbox local id while unsent, or the system line id. 32 hex or a UUID.
  final DateTime at; // display time (UTC)
}

final class DecryptedMessage extends ThreadEntry {
  const DecryptedMessage({
    required super.id,
    required super.at,
    required this.mine,
    this.state = EncryptedMessageState.visible,
    this.check = MessageCheck.ok,
    this.text = '',
    this.sharedPostId = '',
    this.progress = SendProgress.delivered,
    this.problem = SendProblem.none,
    this.error,
    this.canReport = false,
  });
  final bool mine; // from the MLS sender device's pinned side (R7), never the server's from_self.
  // For an `undecryptable` row it is true only for a lost own send (R7); every other
  // undecryptable row has mine == false, own or not. Screens never take a side from
  // an undecryptable row.
  final EncryptedMessageState state;
  final MessageCheck check; // meaningful only for `visible`; unverified and undecodable carry no text
  final String text; // '' unless visible and check == ok
  final String sharedPostId; // '' unless visible and check == ok
  final SendProgress progress; // `delivered` for every received message; an own unsent row is not delivered.
  // A message sent on a provisional group (R6) is `sending` until it is confirmed.
  final SendProblem problem; // != none only with progress == notSent
  final AppException? error; // only with problem == refused
  final bool canReport; // the peer's (not mine) visible message whose exact bytes are still on this device (R13)
}

final class SystemLineEntry extends ThreadEntry {
  const SystemLineEntry({
    required super.id,
    required super.at,
    required this.kind,
    this.side,
  });
  final SystemLineKind kind;
  final LineSide? side; // for deviceAdded / deviceRemoved. A device's OWN joining is never reported
  // as deviceAdded/mine on that device itself.
}

final class EncryptedThread {
  const EncryptedThread({
    this.conversationId,
    this.entries = const [],
    this.hasMore = false,
    required this.security,
  });
  final String? conversationId; // null for a draft whose conversation id is not known yet (K2 gives it)
  final List<ThreadEntry> entries; // newest first; own unsent rows included; nothing at or before cleared_at
  final bool hasMore; // older rows exist in the vault
  final ConversationSecurity security;
}

enum SendOutcomeKind { queued, notEncrypted, refused }

final class SendOutcome {
  const SendOutcome(
    this.kind, {
    this.conversationId,
    this.problem = SendProblem.none,
    this.error,
  });
  final SendOutcomeKind
  kind; // queued: saved on this device (stage plain), shown by watchThread.
  // notEncrypted: nothing was saved; the caller sends through MessagingRepository as today.
  // Also the answer for a first message to a peer whose device list is READABLE and empty.
  // NEVER for a conversation (or a recipient) this device has ever known as encrypted
  // (the vault's known set or the cached row's sticky encrypted marker), and NEVER
  // while a vault exists on this device and is not ready (security read C1).
  // refused: nothing was saved; show [problem] / [error]. Returned ONLY from the start
  // path of an encryption (peerHasNoDevice with a non-empty list, tryTomorrow, blocked,
  // retryable when the device lookup could not be read (H1), a first-attempt server
  // refusal of the init), and `blocked` while a vault on this device is not ready
  // (C1: no conversation can be classified then). In an existing encrypted conversation
  // `send` returns before the network call, so a later refusal arrives as the row's
  // `notSent` / `problem` through watchThread, never as `refused`.
  final String? conversationId; // known for an existing conversation, or once the claim answered
  final SendProblem problem;
  final AppException? error;
}

/// `unavailable` also covers a member not yet attributed (attribution pending or deferred) and a provisional
/// group (security read H3); counts are 0 with it.
enum NoCodeReason {
  pendingRequest,
  sentRequest,
  notAMember,
  unknownDevice,
  listUnverifiable,
  unavailable,
}

final class SecurityCode {
  const SecurityCode({
    this.digits,
    this.reason,
    this.myDevices = 0,
    this.theirDevices = 0,
  });
  final String?
  digits; // exactly 60 ASCII digits (12 groups of 5), or null with [reason]
  final NoCodeReason? reason;
  final int myDevices;
  final int theirDevices;
}

enum PreviewKind {
  text,
  sharedPost,
  removed,
  deletedAccount,
  undecryptable,
  unverified,
  undecodable,
  generic,
}

final class ConversationPreview {
  const ConversationPreview({
    required this.kind,
    this.text = '',
    this.mine = false,
  });
  final PreviewKind
  kind; // generic: an unaccepted incoming request (R10), or no local copy yet
  final String
  text; // only for kind == text; a single line, at most 140 characters
  final bool mine;
}

final class EncryptedSearchHit {
  const EncryptedSearchHit({
    required this.conversationId,
    required this.messageId,
    required this.at,
    required this.mine,
    required this.text,
  });
  final String conversationId;
  final String messageId;
  final DateTime at;
  final bool mine;
  final String text;
}

final class OwnDevice {
  const OwnDevice({
    required this.ref,
    required this.thisDevice,
    this.addedAt,
    this.lastSeenAt,
    this.inactive = false,
    this.inDirectory = true,
    this.inConversations = false,
  });
  final String
  ref; // opaque handle for removeDevice; never displayed, never logged
  final bool thisDevice;
  final DateTime? addedAt; // KeyDevice.created_at; null when the device is not in the directory answer
  final DateTime? lastSeenAt; // KeyDevice.last_seen_at
  final bool
  inactive; // KeyDevice.inactive (K5): not seen for 30 days; NOT removed
  final bool inDirectory; // listed by ListMyKeyDevices
  final bool inConversations; // pinned `mine` in at least one group stored in this vault (R4)
}

final class OwnDeviceList {
  const OwnDeviceList({this.devices = const [], this.directoryKnown = true});
  final List<OwnDevice> devices; // this device first, then oldest first
  final bool directoryKnown; // false: ListMyKeyDevices could not be read; the list is vault membership only
}

/// Why `resetConversation` refused for a reason the server's typed errors do not cover.
enum ResetRefusal {
  notAccepted, // the conversation is not accepted yet (a request): there is nothing to reset
  peerHasNoDevice, // the peer has no claimable device: a reset would have nobody to encrypt to
}

/// Thrown by `resetConversation` for exactly those two cases. 5a throws this, never its internal
/// E2eeActionException. No toString.
final class ResetRefusedException implements Exception {
  const ResetRefusedException(this.reason);
  final ResetRefusal reason;
}

abstract interface class EncryptedMessaging {
  // ----- this device -----
  /// R17: true once this device, after a confirmed registration, was missing from two consecutive successful
  /// ListMyKeyDevices answers. The pipeline has then stopped syncing, decrypting and sending. It returns to false
  /// when two consecutive successful answers list this device again (security read M5); nothing is deleted either way.
  ValueListenable<bool> get removedElsewhere;

  /// The removed card's non-destructive "Check again" (security read M5): one ListMyKeyDevices read now, counted
  /// toward the two consecutive listed answers that clear [removedElsewhere]. No-op when not removed elsewhere.
  Future<void> checkRemovedAgain();

  /// R17 choice "set up again": new device id, old group states deleted, local messages kept. Needs the flag on;
  /// throws FeatureDisabledException otherwise, and StateError when the device is not removed elsewhere (screens
  /// call it only from the removed-elsewhere card).
  Future<void> setUpDeviceAgain();

  /// Runs the device registration again now (after the user removed a device at the 5-device limit). Maps to
  /// `DeviceKeysService.retryNow()`: it clears the device-limit latch for the current vault and registers; it does
  /// nothing for the other latches (key mismatch, unusable device).
  Future<void> retryDeviceSetup();

  // ----- threads -----
  /// Synchronous: this vault has ever recorded an encryption fact for the conversation (a first-saw generation, a
  /// welcome, a provisional or stored group, a stored message, or the repository saying it is MLS; security read C1);
  /// lets an offline start open it. False before the vault is ready.
  bool hasLocal(String conversationId);

  /// Emits the current thread at once (from the vault only: works offline and with the flag off), then on every
  /// change. Listening counts as "the conversation is open" (R8 delete-for-me check, R9 self-update, sync). Errors
  /// are never emitted; a failure is a state. There is NO "not encrypted" state: for a ThreadRef the pipeline knows
  /// nothing about, the stream emits an empty thread with `state == ready`, `canSend` true and no entries. Whether
  /// a conversation is encrypted is decided by the caller (the header's `encryption`, local rows, `hasLocal`), never
  /// by this stream. A `ThreadRef.recipientOf` stream keeps emitting after the conversation id becomes known, with
  /// `conversationId` set.
  Stream<EncryptedThread> watchThread(ThreadRef ref);

  /// Widens the window of [watchThread] by one page (50 rows) from the vault; the stream re-emits.
  Future<void> loadOlder(ThreadRef ref);

  /// Saves the text on this device (R7 stage plain) and sends it when the pipeline may. [localId] is the caller's
  /// id for the row (a UUID); it stays the row's [ThreadEntry.id] until the message is delivered. NOT instant for a
  /// conversation that is not encrypted yet: it awaits one device lookup and, when encryption starts, a claim (network,
  /// 30 s deadline each) before it answers; for an existing encrypted conversation it returns without waiting for the
  /// network. Callers show their normal sending state while the future is pending. It answers `notEncrypted` only
  /// when the conversation was never known as encrypted on this device AND either the peer's device list was read
  /// and is empty or this device may not start encryption (the flag is not on); see [SendOutcome] (security read
  /// C1, H1). The idempotency key on the wire is
  /// the pipeline's own, never [localId]. Throws ArgumentError for a text over the content limit or a [localId] that
  /// is already an unsent row (programming errors: the composer's own length limit keeps text under it).
  Future<SendOutcome> send({
    required ThreadRef to,
    required String localId,
    required String text,
    String sharedPostId = '',
  });

  /// The user tapped a "Not sent. Tap to retry" row. An unknown id is a no-op.
  Future<void> retrySend(String localId);

  /// R6 step 5 / M5 / stuck member: replaces the conversation's group. Throws FeatureDisabledException with the flag
  /// not on, RateLimitedException at a daily cap (reset, commit or claim), the server's typed AppException for any
  /// other server refusal, and ResetRefusedException(notAccepted | peerHasNoDevice) for the two refusals above.
  Future<void> resetConversation(String conversationId);

  // ----- security code (R4) -----
  Future<SecurityCode> securityCode(String conversationId);

  // ----- inbox and search (R14: computed from the vault in memory) -----
  Future<Map<String, ConversationPreview>> previews(
    Iterable<String> conversationIds,
  );

  /// Ids of conversations whose newest row changed.
  Stream<String> get previewChanged;

  /// Case-insensitive substring search over visible, check-ok messages; newest first. Unaccepted incoming
  /// requests are excluded. [conversationId] null: every conversation.
  Future<List<EncryptedSearchHit>> search(
    String query, {
    String? conversationId,
    int limit = 200,
  });

  // ----- reports (R13) -----
  /// The exact decrypted MessageContent bytes of the peer's message, or null when they are no longer on this device.
  Future<Uint8List?> reportPayload(String conversationId, String messageId);

  // ----- own devices (R4, R17) -----
  /// The directory list merged with the membership stored in the vault. A rate limit returns the last known list
  /// (directoryKnown stays true); offline or a failure returns vault membership with directoryKnown == false.
  Future<OwnDeviceList> ownDevices();

  /// RemoveKeyDevice, then the removal commits in the background (the persisted queue). Completes when the
  /// directory removal answered; rethrows its failure and queues nothing then. Works with the flag off (R1).
  /// ArgumentError for this device's own ref (the screen never offers it).
  Future<void> removeDevice(String ref);

  /// Conversations still waiting for a removal commit (parked ones included).
  ValueListenable<int> get removalsPending;
}
