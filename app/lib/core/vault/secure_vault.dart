import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart'
    show expectedMessageId;
import 'package:dzeroth/core/crypto/mls_pair.dart';

import 'vault_cipher.dart';
import 'vault_database.dart';
import 'vault_records.dart';
import 'vault_status.dart';

export 'vault_records.dart';

/// The `state` values of a [StoredMessage].
abstract final class StoredMessageState {
  /// A readable message; the only state that has content.
  static const String visible = 'visible';

  /// Removed by its sender or a moderator; a tombstone without content.
  static const String removed = 'removed';

  /// Its sender's account was deleted; a tombstone without content.
  static const String deletedAccount = 'deletedAccount';

  /// It could not be decrypted (by the engine, or its sealed row no longer
  /// opens under the vault key); no content.
  static const String undecryptable = 'undecryptable';

  static const Set<String> all = {
    visible,
    removed,
    deletedAccount,
    undecryptable,
  };
}

/// One message of the decrypted history. [toString] shows ids only.
///
/// A message read back as [StoredMessageState.undecryptable] (its row did
/// not open, or its stored sort key is damaged) must never be passed to
/// [VaultTx.putMessage]: its content is null and [createdAtMicros] may be
/// 0, so writing it back would destroy the stored ciphertext and sort key.
class StoredMessage {
  const StoredMessage({
    required this.conversationId,
    required this.messageId,
    required this.createdAtMicros,
    required this.mine,
    required this.state,
    required this.generation,
    required this.epoch,
    required this.content,
    this.check = StoredMessageCheck.ok,
    this.kind = StoredMessageKind.message,
    this.senderDeviceId,
  }) : _storedSortKey = null;

  /// A message read back from the vault: [sortKey] is the stored one, so
  /// paging continues past a row whose clear sort key is damaged.
  const StoredMessage._read({
    required this.conversationId,
    required this.messageId,
    required this.createdAtMicros,
    required this.mine,
    required this.state,
    required this.generation,
    required this.epoch,
    required this.content,
    required this.check,
    required this.kind,
    required this.senderDeviceId,
    required String storedSortKey,
  }) : _storedSortKey = storedSortKey;

  final String conversationId;
  final String messageId;

  /// For a row whose stored sort key is damaged: 0 (and [state] is
  /// [StoredMessageState.undecryptable]).
  final int createdAtMicros;

  /// Whether the sender is one of this user's own devices (derived by the
  /// pipeline from the sender device's pinned side). Stored in clear; the
  /// legacy sealed `from_self` column is always written equal to it.
  final bool mine;

  /// One of [StoredMessageState].
  final String state;
  final int generation;
  final int epoch;

  /// The decrypted `MessageContent` bytes (for a system row, the encoded
  /// [SystemLineContent]); required for every [StoredMessageState.visible]
  /// row whatever its [check], null for any other state.
  final Uint8List? content;

  /// One of [StoredMessageCheck]; a value other than `ok` is allowed only on
  /// a visible message row.
  final String check;

  /// One of [StoredMessageKind].
  final String kind;

  /// The sender's device id, when known.
  final Uint8List? senderDeviceId;

  final String? _storedSortKey;

  /// The key [SecureVault.messages] pages by (`beforeSortKey`): the stored
  /// key for a message read from the vault.
  String get sortKey =>
      _storedSortKey ?? vaultSortKey(createdAtMicros, messageId);

  @override
  String toString() => 'StoredMessage($conversationId, $messageId)';
}

/// A message encrypted for sending and not yet accepted by the server.
/// Exactly one of [conversationId] and [recipientUserId] is set.
/// [toString] shows the idempotency key only.
class OutboxItem {
  const OutboxItem({
    required this.idempotencyKey,
    required this.localId,
    required this.expectedMessageId,
    this.conversationId,
    this.recipientUserId,
    required this.generation,
    required this.epoch,
    required this.ciphertext,
    required this.reportCommitment,
    required this.content,
    required this.createdAtMicros,
    this.stage = OutboxStage.encrypted,
    this.init,
    this.attempts = 0,
    this.lastError,
  });

  final String idempotencyKey;

  /// Stable across re-keying: the first idempotency key of this send.
  final String localId;

  /// The message id the server will give this send (`expectedMessageId`).
  final String expectedMessageId;
  final String? conversationId;

  /// The reference exactly as sent.
  final String? recipientUserId;
  final int generation;
  final int epoch;
  final Uint8List ciphertext;
  final Uint8List reportCommitment;
  final Uint8List content;
  final int createdAtMicros;

  /// One of [OutboxStage]. A `plain` item has no ciphertext, no report
  /// commitment, no init and pair (0, 0).
  final String stage;

  /// The serialized `MlsInit`, exact bytes.
  final Uint8List? init;
  final int attempts;
  final String? lastError;

  @override
  String toString() => 'OutboxItem($idempotencyKey)';
}

/// The MLS group state of one generation of one conversation. [toString]
/// shows the id only. (It stays here rather than in `vault_records.dart`
/// because the vault guard pins this `toString` to this file.)
class GroupRecord {
  const GroupRecord({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.state,
    this.pending,
    this.provisional = false,
    this.provisionalCreatedAtMicros,
  });

  final String conversationId;
  final int generation;
  final int epoch;
  final Uint8List state;

  /// The commit this device built and has not seen accepted yet.
  final PendingCommit? pending;

  /// True while the group was created locally and the server has not
  /// accepted it. No mark is ever written for a provisional group.
  final bool provisional;

  /// When a provisional group was created; required when [provisional].
  final int? provisionalCreatedAtMicros;

  bool get hasPending => pending != null;

  @override
  String toString() => 'GroupRecord($conversationId)';
}

/// What [SecureVault.outbox] could read: the readable [items], oldest first,
/// and the idempotency keys of rows that no longer open under the vault key
/// (or hold a malformed value). Those rows are kept; the caller decides,
/// for example `VaultTx.deleteOutbox(key)`. [toString] shows counts only.
class OutboxRead {
  const OutboxRead(this.items, this.unreadableKeys);

  final List<OutboxItem> items;
  final List<String> unreadableKeys;

  @override
  String toString() =>
      'OutboxRead(${items.length} items, ${unreadableKeys.length} unreadable)';
}

/// The encrypted, durable store of one user's end-to-end encryption state
/// and decrypted message history. Not a cache: nothing is trimmed, nothing
/// is dropped because a read failed, and nothing is wiped because of a key
/// problem (only [wipe] and `wipeVaultFile` delete rows).
///
/// Every value except ids, sort keys, message state, generation and epoch
/// is sealed with the user's [VaultCipher], bound to its table, column and
/// row key.
///
/// Rules for the code that uses it (the vault session and the messaging
/// engine):
///
/// - Write only inside [transaction] bodies, through the [VaultTx] they get.
///   A read made from outside the body while a transaction is open waits on
///   drift's lock until the transaction ends.
/// - The vault does NOT serialise its callers: two concurrent [transaction]s
///   run one after the other inside the database, but nothing orders a read
///   against a write, or two writers of one conversation. The vault session
///   owns that, with a keyed mutex and, on the web, single-tab ownership.
/// - On the web, after any failed write (a storage or worker error, not a
///   failure the body threw itself), close the vault and open it again
///   before writing more; do not keep using a connection that failed.
/// - Never call `wipeVaultFile` for a uid whose vault is open (it throws
///   [StateError] for a vault opened in this process). It erases every
///   copy the platform can find (on the web: every copy the storage probe
///   lists; one it cannot list survives): call it only for an explicit
///   user reset or
///   sign-out, a different user signing in, or a key loss the session has
///   confirmed. NEVER call it because of [VaultStatus.storageChanged]: that
///   would destroy the history the status is protecting.
/// - Setting keys ([VaultTx.putSetting]) are stored in clear: never put a
///   user id, a conversation id that is not already a clear column, or any
///   content in a key.
/// - [OutboxItem.lastError] is sealed but should still be a short error
///   code, never text returned by the server.
///
/// After [close] or [wipe], every call throws [StateError]; while [wipe]
/// runs, every new call does too.
abstract interface class SecureVault {
  String get uid;

  /// The storage this vault lives in: on the web the drift storage's name
  /// (`opfsShared`, `opfsLocks`, `sharedIndexedDb`), on Android `native`.
  /// The vault session records it outside the vault (the storage marker).
  String get storageName;

  /// True when this open found no vault and wrote a new owner stamp and
  /// sentinel; false when it opened an existing one.
  bool get createdThisOpen;

  /// Runs [body] in one database transaction: if [body] throws, nothing it
  /// wrote is kept. [tx] must only be used inside [body] (otherwise
  /// [StateError]). Transactions do not nest ([StateError]). Reads made
  /// through this vault inside [body] see [body]'s writes.
  Future<T> transaction<T>(Future<T> Function(VaultTx tx) body);

  /// This device's id, or null before the device was created.
  Future<Uint8List?> deviceId();

  /// This device's engine state, or null before the device was created.
  Future<Uint8List?> deviceState();

  /// The group state of one generation of [conversationId], or null.
  Future<GroupRecord?> group(String conversationId, int generation);

  /// Every generation of [conversationId], ascending generation.
  Future<List<GroupRecord>> groups(String conversationId);

  /// The conversations that have a group state: distinct, ascending.
  Future<List<String>> groupConversationIds();

  /// The marks and sync record of [conversationId], or null when it has none
  /// (an absent mark is below every pair: `MlsPair.above(pair, null)`).
  Future<ConversationRecord?> conversation(String conversationId);

  /// The devices pinned in [conversationId], ascending device id hex.
  Future<List<MemberRecord>> members(String conversationId);

  /// Whether an outbox item expects the message id [expectedMessageId].
  /// Reads no sealed column.
  Future<bool> hasOutboxExpecting(String expectedMessageId);

  /// Whether the commit digest ([digestHex], 64 hex) was recorded for [pair]
  /// with [VaultTx.addSent]. Reads no sealed column.
  Future<bool> hasSent(String conversationId, MlsPair pair, String digestHex);

  /// Up to [limit] messages of [conversationId], newest first, strictly
  /// older than [beforeSortKey] when given ([StoredMessage.sortKey]). There
  /// is no cap on history: page with the last returned sort key until the
  /// result is shorter than [limit]. A row that no longer opens under the
  /// vault key comes back as [StoredMessageState.undecryptable] with no
  /// content; it is never deleted. Never write such a message back with
  /// [VaultTx.putMessage]: its content is null and its time may be 0, so
  /// that would replace the stored ciphertext and sort key for good.
  Future<List<StoredMessage>> messages(
    String conversationId, {
    int limit = 50,
    String? beforeSortKey,
  });

  Future<StoredMessage?> message(String conversationId, String messageId);

  /// Whether the message is stored (any state). Reads no sealed column, so
  /// it is the dedupe check before decrypting.
  Future<bool> hasMessage(String conversationId, String messageId);

  /// Pending items, oldest first, of one conversation or of all. A row that
  /// cannot be read does not hide the others: its key is listed in
  /// [OutboxRead.unreadableKeys] and the row is left in place. A cipher that
  /// cannot run throws [VaultKeyException] (nothing is reported unreadable
  /// because of an outage).
  Future<OutboxRead> outbox({String? conversationId});

  /// A value stored with [VaultTx.putSetting], or null.
  Future<Uint8List?> setting(String key);

  /// Deletes every row (one transaction), compacts the file (`VACUUM`; with
  /// `secure_delete` on, freed pages are zeroed), then destroys the cipher
  /// (its platform key). From the start every other call is refused, so no
  /// transaction can commit rows under the key about to go. If the rows
  /// cannot be deleted this throws, the cipher is left alone and the vault
  /// is usable again (nothing was deleted). Once the rows are gone the vault
  /// is closed, even if compacting or destroying the cipher throws.
  Future<void> wipe();

  Future<void> close();
}

/// The writes of one [SecureVault.transaction].
abstract interface class VaultTx {
  /// Creates or replaces this device's id and state.
  Future<void> putDevice(Uint8List deviceId, Uint8List deviceState);

  /// Replaces this device's state; [StateError] when there is no device.
  Future<void> putDeviceState(Uint8List deviceState);

  /// Creates or replaces one generation's group state. A provisional record
  /// needs [GroupRecord.provisionalCreatedAtMicros] ([ArgumentError]). Never
  /// touches the marks.
  Future<void> putGroup(GroupRecord record);

  /// Deletes one generation's group state. Never touches the marks, so
  /// deleting a provisional group leaves the earlier marks as they were.
  Future<void> deleteGroup(String conversationId, int generation);

  /// Makes a provisional group final and writes the marks, all in this
  /// transaction. [StateError] when the group is absent or not provisional,
  /// or when a mark is not strictly above the stored one; [ArgumentError]
  /// when [afterPair] or [joinHighWater] is of another generation than
  /// [generation] (nothing is written then).
  Future<void> clearProvisional(
    String conversationId,
    int generation, {
    required MlsPair afterPair,
    MlsPair? joinHighWater,
  });

  /// Raises the after-pair mark. [StateError] when the stored group of
  /// `pair.generation` is provisional, or when [pair] is not strictly above
  /// the stored mark (marks never move back; an absent mark is below every
  /// pair).
  Future<void> setAfterPair(String conversationId, MlsPair pair);

  /// Raises the join high-water mark; the same rules as [setAfterPair].
  Future<void> setJoinHighWater(String conversationId, MlsPair pair);

  /// Replaces the sync record only; never touches the marks. [ArgumentError]
  /// for an integer or a completed epoch outside 0..2^53 - 1.
  Future<void> putConversationSync(
    String conversationId,
    ConversationSync sync,
  );

  Future<void> putMember(MemberRecord member);
  Future<void> deleteMember(String conversationId, Uint8List deviceId);

  /// Records a commit digest sent at [pair].
  Future<void> addSent(String conversationId, MlsPair pair, String digestHex);

  /// Deletes the digests of pairs below [pair]; the digests of [pair] stay.
  Future<void> clearSentBefore(String conversationId, MlsPair pair);

  /// Creates or replaces a message. A [StoredMessageState.visible] message
  /// needs content; every other state must have none ([ArgumentError]).
  Future<void> putMessage(StoredMessage m);

  /// Sets the state of a stored message and, for any state but
  /// [StoredMessageState.visible], clears its content (stores NULL). Setting
  /// [StoredMessageState.visible] this way is refused ([ArgumentError]: a
  /// readable message comes through [putMessage]). A message that is not
  /// stored is left absent.
  Future<void> setMessageState(
    String conversationId,
    String messageId,
    String state,
  );

  /// Delete-for-me: deletes the conversation's messages, all of them or
  /// those created at or before [upToCreatedAtMicros] (inclusive; a
  /// negative bound deletes nothing, the largest int deletes all). Group
  /// state and outbox items are not touched ([deleteGroup], [deleteOutbox]).
  Future<void> deleteConversation(
    String conversationId, {
    int? upToCreatedAtMicros,
  });

  /// [ArgumentError] for an empty local id or expected message id, among
  /// the stage rules.
  Future<void> putOutbox(OutboxItem item);
  Future<void> deleteOutbox(String idempotencyKey);
  Future<void> putSetting(String key, Uint8List value);
}

/// Opens [uid]'s vault on [db] with [cipher]: the part of `openVault` that
/// does not depend on the platform. [db] is closed on every failure.
///
/// It never deletes a row.
///
/// - No `vault_meta` row and no other rows: a new vault. The owner stamp
///   and the sealed sentinel are written in one transaction. With [create]
///   false (the flag is not on) nothing is written: [VaultStatus.unavailable].
/// - The sentinel opens to the expected value under [cipher]: ready. When
///   the owner stamp names another uid (the file is per user, so only
///   corruption can do that) and the sentinel still opens, the stamp is
///   rewritten to [uid] in a transaction.
/// - The sentinel does not authenticate, or holds another value, or there
///   are rows but no `vault_meta` row: [VaultOpenException] with
///   [VaultStatus.keyLost], whatever the owner stamp says. Nothing is
///   changed: wiping after key loss is decided by the caller (it needs the
///   loss confirmed on two launches) and done with `wipeVaultFile`.
/// - The cipher is unavailable, the storage fails, the open takes longer
///   than [openTimeout], or the file was stamped by a newer schema:
///   [VaultStatus.unavailable], nothing written. After a timeout the
///   abandoned open may still finish in the background; at most it stamps
///   a new, empty vault for [uid] or rewrites a corrupted owner stamp.
/// - A file below schema version 2 is migrated here: the additive SQL ran
///   when drift opened it; the sealed step (`_migrateSealedV1`) runs only
///   after the sentinel opened, under [openTimeout]. On a timeout the
///   database is closed, so the step never half-applies: it is one
///   transaction, which either commits whole or rolls back (the stamp stays
///   1) and starts over at the next open. It never deletes a row.
///
/// With [registerAs] (`openVault` passes the database name), the open vault
/// is counted in this isolate's registry until it is closed or wiped, and
/// `wipeVaultFile` refuses that name meanwhile ([isVaultOpenInProcess]).
/// [storageName] becomes [SecureVault.storageName] (`openVault` passes the
/// storage the platform chose).
Future<SecureVault> openVaultOnDatabase(
  VaultDatabase db, {
  required String uid,
  required VaultCipher cipher,
  Duration openTimeout = const Duration(seconds: 30),
  String? registerAs,
  String storageName = 'native',
  bool create = true,
}) async {
  final bool created;
  try {
    created = await _claim(db, uid, cipher, create).timeout(openTimeout);
  } catch (error) {
    await db.closeQuietly();
    throw VaultOpenException(_statusFor(error));
  }
  if (registerAs != null) {
    _openVaultNames[registerAs] = (_openVaultNames[registerAs] ?? 0) + 1;
  }
  return _DriftSecureVault(
    db,
    uid,
    cipher,
    registerAs,
    storageName: storageName,
    createdThisOpen: created,
  );
}

/// Vault database names open in this ISOLATE (a name can be open more than
/// once, e.g. a test opening a second instance), counted. A Dart top-level:
/// each isolate has its own copy.
final Map<String, int> _openVaultNames = {};

/// Whether a vault opened with `registerAs: name` is still open in THIS
/// ISOLATE (despite the name, not process-wide): another tab, or another
/// isolate of the same process (e.g. a background isolate), is not seen.
/// Only the UI isolate's vault session opens the vault.
bool isVaultOpenInProcess(String name) => (_openVaultNames[name] ?? 0) > 0;

void _releaseVaultName(String name) {
  final count = (_openVaultNames[name] ?? 0) - 1;
  if (count > 0) {
    _openVaultNames[name] = count;
  } else {
    _openVaultNames.remove(name);
  }
}

VaultStatus _statusFor(Object error) => switch (error) {
  VaultOpenException(:final status) => status,
  VaultRowException() => VaultStatus.keyLost,
  VaultKeyException(failure: VaultKeyFailure.keyLost) => VaultStatus.keyLost,
  // Key store, storage, worker, timeout or anything unexpected: fail closed
  // without touching the file.
  _ => VaultStatus.unavailable,
};

final _sentinelLabel = vaultSealLabel('vault_meta', 'sentinel');
final _sentinelRowKey = vaultRowKey([kVaultMetaKey]);

/// True when this claim created the vault (wrote the stamp and sentinel).
/// With [create] false it never creates one: no `vault_meta` row and no
/// rows is [VaultStatus.unavailable], before anything is sealed or written.
Future<bool> _claim(
  VaultDatabase db,
  String uid,
  VaultCipher cipher,
  bool create,
) async {
  // The first query opens the file (and, on the web, checks the storage).
  final meta = await (db.select(
    db.vaultMeta,
  )..where((t) => t.metaKey.equals(kVaultMetaKey))).getSingleOrNull();

  if (meta != null) {
    if (meta.schemaVersion > kVaultSchemaVersion) {
      // Written by a newer build (an app downgrade): leave it as it is.
      throw const VaultOpenException(VaultStatus.unavailable);
    }
    // Whatever the owner stamp says, only this user's key decides: a
    // sentinel that does not open is keyLost and nothing is touched.
    final opened = await cipher.open(
      _sentinelLabel,
      _sentinelRowKey,
      meta.sentinel,
    );
    if (utf8.decode(opened, allowMalformed: true) != kVaultSentinel) {
      throw const VaultOpenException(VaultStatus.keyLost);
    }
    if (meta.ownerUid != uid) {
      // The key opens it, so it is this user's vault with a damaged stamp.
      await db.transaction(() async {
        await (db.update(db.vaultMeta)
              ..where((t) => t.metaKey.equals(kVaultMetaKey)))
            .write(VaultMetaCompanion(ownerUid: Value(uid)));
      });
    }
    if (meta.schemaVersion < 2) {
      // The key opened the sentinel: the sealed part of the v1 -> v2 step.
      await _migrateSealedV1(db, uid, cipher);
    }
    return false;
  }

  if (await db.hasDataRows()) {
    // Rows without a stamp and sentinel: inconsistent, treated as loss.
    throw const VaultOpenException(VaultStatus.keyLost);
  }

  // No vault here and the caller may not start one (the flag is not on):
  // nothing is sealed, stamped or written.
  if (!create) throw const VaultOpenException(VaultStatus.unavailable);

  final sentinel = await cipher.seal(
    _sentinelLabel,
    _sentinelRowKey,
    Uint8List.fromList(utf8.encode(kVaultSentinel)),
  );
  await db.transaction(() async {
    if (await db.hasDataRows()) {
      throw const VaultOpenException(VaultStatus.keyLost);
    }
    // A plain insert: it fails rather than replace a sentinel that appeared
    // meanwhile (which may be sealed under a key now lost).
    await db
        .into(db.vaultMeta)
        .insert(
          VaultMetaCompanion.insert(
            metaKey: kVaultMetaKey,
            ownerUid: uid,
            schemaVersion: kVaultSchemaVersion,
            sentinel: sentinel,
          ),
          mode: InsertMode.insert,
        );
  });
  return true;
}

/// The sealed part of the schema v1 -> v2 migration (the additive SQL ran
/// when drift opened the file). Called from the open path only after the
/// sentinel opened and only while the `vault_meta` stamp is below 2. ONE
/// transaction that ends by stamping `schema_version = 2`: it either applies
/// completely or not at all.
///
/// It never deletes a row. A row that does not authenticate
/// ([VaultRowException]) is left exactly as it is and skipped (the stamp
/// still moves); a [VaultRowException] never leaves this function, because
/// the open maps it to key loss. A cipher that cannot run
/// ([VaultKeyException]) propagates: the transaction rolls back, the stamp
/// stays 1 and the open reports unavailable.
///
/// - Each `vault_groups` row that opens is copied to `vault_group_states`
///   (same pair, `state` re-sealed under the new label and row key, no
///   pending commit, not provisional). The v1 row stays, sealed and unread.
/// - Each `vault_messages` row with `mine` NULL gets `mine` from its sealed
///   `from_self`.
/// - Each `vault_outbox` row gets `local_id` = its idempotency key and the
///   K3 `expected_message_id`.
Future<void> _migrateSealedV1(
  VaultDatabase db,
  String uid,
  VaultCipher cipher,
) => db.transaction(() async {
  // (a) groups.
  for (final row in await db.select(db.vaultGroups).get()) {
    final Uint8List state;
    try {
      state = await cipher.open(
        vaultSealLabel(_tGroups, 'state'),
        vaultRowKey([row.conversationId]),
        row.state,
      );
    } on VaultRowException {
      continue;
    }
    final resealed = await cipher.seal(
      vaultSealLabel(_tGroupStates, 'state'),
      vaultRowKey([row.conversationId, '${row.generation}']),
      state,
    );
    await db
        .into(db.vaultGroupStates)
        .insert(
          VaultGroupStatesCompanion.insert(
            conversationId: row.conversationId,
            generation: row.generation,
            epoch: row.epoch,
            state: resealed,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  // (b) messages: only the columns the step needs are read.
  final messages = await db
      .customSelect(
        'SELECT conversation_id, message_id, from_self FROM vault_messages '
        'WHERE mine IS NULL',
        readsFrom: {db.vaultMessages},
      )
      .get();
  for (final row in messages) {
    final conversationId = row.read<String>('conversation_id');
    final messageId = row.read<String>('message_id');
    final Uint8List flag;
    try {
      flag = await cipher.open(
        vaultSealLabel(_tMessages, 'from_self'),
        vaultRowKey([conversationId, messageId]),
        row.read<Uint8List>('from_self'),
      );
    } on VaultRowException {
      continue;
    }
    await db.customUpdate(
      'UPDATE vault_messages SET mine = ? '
      'WHERE conversation_id = ? AND message_id = ? AND mine IS NULL',
      variables: [
        Variable.withInt(_readFlag(flag) ? 1 : 0),
        Variable.withString(conversationId),
        Variable.withString(messageId),
      ],
      updates: {db.vaultMessages},
    );
  }

  // (c) outbox: both ids are clear values derived from the clear idempotency
  // key, so EVERY row gets them (no sealed value is opened or changed, an
  // unreadable row included).
  for (final row in await db.select(db.vaultOutbox).get()) {
    if (row.localId != null && row.expectedMessageId != null) continue;
    await (db.update(
      db.vaultOutbox,
    )..where((t) => t.idempotencyKey.equals(row.idempotencyKey))).write(
      VaultOutboxCompanion(
        localId: Value(row.localId ?? row.idempotencyKey),
        expectedMessageId: Value(
          row.expectedMessageId ?? expectedMessageId(uid, row.idempotencyKey),
        ),
      ),
    );
  }

  // The stamp, in the same transaction.
  await (db.update(db.vaultMeta)..where((t) => t.metaKey.equals(kVaultMetaKey)))
      .write(const VaultMetaCompanion(schemaVersion: Value(2)));
});

/// The zone value that marks code running inside a vault transaction body.
const Symbol _txZoneKey = #dzerothVaultTransaction;

const String _tDevice = 'vault_device';
const String _tGroups = 'vault_groups';
const String _tGroupStates = 'vault_group_states';
const String _tConversations = 'vault_conversations';
const String _tMembers = 'vault_members';
const String _tMessages = 'vault_messages';
const String _tOutbox = 'vault_outbox';
const String _tSettings = 'vault_settings';

Uint8List _flag(bool value) => Uint8List.fromList([value ? 1 : 0]);
bool _readFlag(Uint8List bytes) => bytes.length == 1 && bytes[0] == 1;
Uint8List _text(String value) => Uint8List.fromList(utf8.encode(value));

/// [ArgumentError] unless [p] is within the wire limits: commit 1-16384
/// bytes; a welcome 1-65536 bytes with 1-10 device ids, and no device ids
/// without a welcome; `builtOn` within the pair range (the decoder refuses
/// anything else).
void _requirePendingLimits(PendingCommit p) {
  _requirePair(p.builtOn);
  final welcome = p.welcome;
  final ok =
      p.commit.isNotEmpty &&
      p.commit.length <= 16384 &&
      (welcome == null
          ? p.welcomeDeviceIds.isEmpty
          : welcome.isNotEmpty &&
                welcome.length <= 65536 &&
                p.welcomeDeviceIds.isNotEmpty &&
                p.welcomeDeviceIds.length <= 10);
  if (!ok) throw ArgumentError('A pending commit is outside its limits.');
}

bool _inPairRange(int v) => v >= 0 && v <= kMaxPairComponent;

/// [ArgumentError] unless every integer of [sync] is one its decoder accepts
/// (0..2^53 - 1), so a caller bug cannot store a record that never reads
/// back.
void _requireSync(ConversationSync sync) {
  for (final v in [
    sync.firstSawGeneration,
    sync.firstSawGenerationAtMicros,
    sync.lastSelfUpdateAtMicros,
    sync.clearedAtMicros,
    sync.commitCallsToday,
  ]) {
    if (v != null && !_inPairRange(v)) {
      throw ArgumentError('A sync value is out of range.');
    }
  }
  for (final p in sync.completedEpochs) {
    _requirePair(p);
  }
}

/// [ArgumentError] unless both components are within 0..2^53 - 1 (the asserts
/// of [MlsPair] are off in release builds, and the web cannot hold more).
void _requirePair(MlsPair pair) =>
    _requireComponents(pair.generation, pair.epoch);

/// [_requirePair] for two numbers that are not a pair yet (building an
/// [MlsPair] out of range would fail its assert in debug builds).
void _requireComponents(int generation, int epoch) {
  if (!_inPairRange(generation) || !_inPairRange(epoch)) {
    throw ArgumentError('A generation or epoch is out of range.');
  }
}

/// A pair read from two clear columns; [VaultCorruptException] for a value
/// out of range.
MlsPair _pairOf(int generation, int epoch, String table) {
  if (!_inPairRange(generation) || !_inPairRange(epoch)) {
    throw VaultCorruptException(table);
  }
  return MlsPair(generation, epoch);
}

/// A mark read from its two nullable columns: both set, or neither.
MlsPair? _markOf(int? generation, int? epoch) {
  if (generation == null && epoch == null) return null;
  if (generation == null || epoch == null) {
    throw const VaultCorruptException(_tConversations);
  }
  return _pairOf(generation, epoch, _tConversations);
}

final RegExp _hexPattern = RegExp(r'^(?:[0-9a-f]{2})*$');
final RegExp _digestPattern = RegExp(r'^[0-9a-f]{64}$');

Uint8List _deviceIdFromHex(String hex) {
  if (!_hexPattern.hasMatch(hex)) throw const VaultCorruptException(_tMembers);
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

String _readText(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

class _DriftSecureVault implements SecureVault {
  _DriftSecureVault(
    this._db,
    this.uid,
    this._cipher,
    this._registeredAs, {
    required this.storageName,
    required this.createdThisOpen,
  });

  @override
  final String storageName;

  @override
  final bool createdThisOpen;

  final VaultDatabase _db;
  final VaultCipher _cipher;
  String? _registeredAs;
  bool _closed = false;

  /// Releases the registry entry (once). Called only after the connection
  /// has finished closing, so `wipeVaultFile` started without awaiting
  /// [close] or [wipe] still sees the vault as open and refuses.
  void _releaseRegistration() {
    final name = _registeredAs;
    _registeredAs = null;
    if (name != null) _releaseVaultName(name);
  }

  bool _wiping = false;

  @override
  final String uid;

  void _checkOpen() {
    if (_closed) throw StateError('The vault is closed.');
    if (_wiping) throw StateError('The vault is being wiped.');
  }

  Future<Uint8List> _seal(
    String table,
    String column,
    List<String> key,
    Uint8List value,
  ) => _cipher.seal(vaultSealLabel(table, column), vaultRowKey(key), value);

  Future<Uint8List> _open(
    String table,
    String column,
    List<String> key,
    Uint8List value,
  ) => _cipher.open(vaultSealLabel(table, column), vaultRowKey(key), value);

  /// Opens a value of a table whose rows are not recoverable one by one: a
  /// row that does not authenticate is [VaultCorruptException]. A cipher
  /// that cannot run ([VaultKeyException]) propagates as it is.
  Future<Uint8List> _openOrCorrupt(
    String table,
    String column,
    List<String> key,
    Uint8List value,
  ) async {
    try {
      return await _open(table, column, key, value);
    } on VaultRowException {
      throw VaultCorruptException(table);
    }
  }

  @override
  Future<T> transaction<T>(Future<T> Function(VaultTx tx) body) async {
    _checkOpen();
    if (Zone.current[_txZoneKey] != null) {
      throw StateError('Vault transactions do not nest.');
    }
    final tx = _DriftVaultTx(this);
    try {
      return await _db.transaction(
        () => runZoned(() => body(tx), zoneValues: {_txZoneKey: tx}),
      );
    } finally {
      tx._ended = true;
    }
  }

  @override
  Future<Uint8List?> deviceId() async {
    _checkOpen();
    final row = await _deviceRow();
    if (row == null) return null;
    return _openOrCorrupt(_tDevice, 'device_id', [
      kVaultDeviceSlot,
    ], row.deviceId);
  }

  @override
  Future<Uint8List?> deviceState() async {
    _checkOpen();
    final row = await _deviceRow();
    if (row == null) return null;
    return _openOrCorrupt(_tDevice, 'device_state', [
      kVaultDeviceSlot,
    ], row.deviceState);
  }

  Future<VaultDeviceRow?> _deviceRow() => (_db.select(
    _db.vaultDevice,
  )..where((t) => t.slot.equals(kVaultDeviceSlot))).getSingleOrNull();

  @override
  Future<GroupRecord?> group(String conversationId, int generation) async {
    _checkOpen();
    final row = await _groupRow(conversationId, generation);
    return row == null ? null : _groupRecord(row);
  }

  Future<VaultGroupStateRow?> _groupRow(
    String conversationId,
    int generation,
  ) =>
      (_db.select(_db.vaultGroupStates)..where(
            (t) =>
                t.conversationId.equals(conversationId) &
                t.generation.equals(generation),
          ))
          .getSingleOrNull();

  Future<GroupRecord> _groupRecord(VaultGroupStateRow row) async {
    final key = [row.conversationId, '${row.generation}'];
    final state = await _openOrCorrupt(_tGroupStates, 'state', key, row.state);
    final sealedPending = row.pending;
    final pending = sealedPending == null
        ? null
        : PendingCommit.decode(
            await _openOrCorrupt(_tGroupStates, 'pending', key, sealedPending),
          );
    return GroupRecord(
      conversationId: row.conversationId,
      generation: row.generation,
      epoch: row.epoch,
      state: state,
      pending: pending,
      provisional: row.provisional == 1,
      provisionalCreatedAtMicros: row.provisionalCreatedAt,
    );
  }

  @override
  Future<List<GroupRecord>> groups(String conversationId) async {
    _checkOpen();
    final rows =
        await (_db.select(_db.vaultGroupStates)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.asc(t.generation)]))
            .get();
    return [for (final row in rows) await _groupRecord(row)];
  }

  @override
  Future<List<String>> groupConversationIds() async {
    _checkOpen();
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT conversation_id FROM vault_group_states '
          'ORDER BY conversation_id',
          readsFrom: {_db.vaultGroupStates},
        )
        .get();
    return [for (final row in rows) row.read<String>('conversation_id')];
  }

  @override
  Future<ConversationRecord?> conversation(String conversationId) async {
    _checkOpen();
    final row = await _conversationRow(conversationId);
    if (row == null) return null;
    final sealed = row.sync;
    return ConversationRecord(
      conversationId: row.conversationId,
      afterPair: _markOf(row.afterGeneration, row.afterEpoch),
      joinHighWater: _markOf(row.joinGeneration, row.joinEpoch),
      sync: sealed == null
          ? const ConversationSync()
          : ConversationSync.decode(
              await _openOrCorrupt(_tConversations, 'sync', [
                conversationId,
              ], sealed),
            ),
    );
  }

  Future<VaultConversationRow?> _conversationRow(String conversationId) =>
      (_db.select(_db.vaultConversations)
            ..where((t) => t.conversationId.equals(conversationId)))
          .getSingleOrNull();

  @override
  Future<List<MemberRecord>> members(String conversationId) async {
    _checkOpen();
    final rows =
        await (_db.select(_db.vaultMembers)
              ..where((t) => t.conversationId.equals(conversationId))
              ..orderBy([(t) => OrderingTerm.asc(t.deviceId)]))
            .get();
    return [
      for (final row in rows)
        MemberRecord(
          conversationId: row.conversationId,
          deviceId: _deviceIdFromHex(row.deviceId),
          signatureKey: await _openOrCorrupt(_tMembers, 'signature_key', [
            row.conversationId,
            row.deviceId,
          ], row.signatureKey),
          side: row.side,
          since: _pairOf(row.sinceGeneration, row.sinceEpoch, _tMembers),
        ),
    ];
  }

  @override
  Future<bool> hasOutboxExpecting(String expectedMessageId) async {
    _checkOpen();
    final row = await _db
        .customSelect(
          'SELECT 1 FROM vault_outbox WHERE expected_message_id = ? LIMIT 1',
          variables: [Variable.withString(expectedMessageId)],
          readsFrom: {_db.vaultOutbox},
        )
        .getSingleOrNull();
    return row != null;
  }

  @override
  Future<bool> hasSent(
    String conversationId,
    MlsPair pair,
    String digestHex,
  ) async {
    _checkOpen();
    _requirePair(pair);
    final row = await _db
        .customSelect(
          'SELECT 1 FROM vault_sent WHERE conversation_id = ? '
          'AND generation = ? AND epoch = ? AND digest = ?',
          variables: [
            Variable.withString(conversationId),
            Variable.withInt(pair.generation),
            Variable.withInt(pair.epoch),
            Variable.withString(digestHex),
          ],
          readsFrom: {_db.vaultSent},
        )
        .getSingleOrNull();
    return row != null;
  }

  @override
  Future<List<StoredMessage>> messages(
    String conversationId, {
    int limit = 50,
    String? beforeSortKey,
  }) async {
    _checkOpen();
    if (limit < 1) throw ArgumentError.value(limit, 'limit', 'must be >= 1');
    final query = _db.select(_db.vaultMessages)
      ..where((t) {
        final inConversation = t.conversationId.equals(conversationId);
        return beforeSortKey == null
            ? inConversation
            : inConversation & t.sortKey.isSmallerThanValue(beforeSortKey);
      })
      ..orderBy([(t) => OrderingTerm.desc(t.sortKey)])
      ..limit(limit);
    final rows = await query.get();
    return [for (final row in rows) await _message(row)];
  }

  @override
  Future<StoredMessage?> message(
    String conversationId,
    String messageId,
  ) async {
    _checkOpen();
    final row = await _messageRow(conversationId, messageId);
    return row == null ? null : _message(row);
  }

  Future<VaultMessageRow?> _messageRow(
    String conversationId,
    String messageId,
  ) =>
      (_db.select(_db.vaultMessages)..where(
            (t) =>
                t.conversationId.equals(conversationId) &
                t.messageId.equals(messageId),
          ))
          .getSingleOrNull();

  /// A row that no longer authenticates is returned as undecryptable, with
  /// no content, and left in place. A cipher that cannot run propagates: an
  /// outage must not turn a page into "undecryptable".
  Future<StoredMessage> _message(VaultMessageRow row) async {
    final key = [row.conversationId, row.messageId];
    var state = row.state;
    var mine = false;
    var check = row.checkState;
    var kind = row.kind;
    Uint8List? content;
    Uint8List? senderDeviceId;
    try {
      // `mine` is clear; it is NULL only for a version 1 row the migration
      // could not read, so the sealed legacy flag decides (and, when it does
      // not authenticate either, the row is undecryptable below).
      final stored = row.mine;
      mine = stored != null
          ? stored == 1
          : _readFlag(await _open(_tMessages, 'from_self', key, row.fromSelf));
      final sealed = row.content;
      if (sealed != null) {
        content = await _open(_tMessages, 'content', key, sealed);
      }
      final sealedSender = row.senderDeviceId;
      if (sealedSender != null) {
        senderDeviceId = await _open(
          _tMessages,
          'sender_device_id',
          key,
          sealedSender,
        );
      }
    } on VaultRowException {
      state = StoredMessageState.undecryptable;
      mine = false;
      content = null;
      senderDeviceId = null;
    }
    final createdAt = vaultSortKeyMicrosOrNull(row.sortKey);
    if (createdAt == null ||
        !StoredMessageCheck.all.contains(check) ||
        !StoredMessageKind.all.contains(kind)) {
      // A damaged clear sort key or marker: the row is kept and shown, not
      // trusted.
      state = StoredMessageState.undecryptable;
      mine = false;
      content = null;
      senderDeviceId = null;
    }
    if (state == StoredMessageState.undecryptable) {
      // A non-ok check belongs to a readable message only.
      check = StoredMessageCheck.ok;
      if (!StoredMessageKind.all.contains(kind)) {
        kind = StoredMessageKind.message;
      }
    }
    return StoredMessage._read(
      conversationId: row.conversationId,
      messageId: row.messageId,
      createdAtMicros: createdAt ?? 0,
      mine: mine,
      state: state,
      generation: row.generation,
      epoch: row.epoch,
      content: content,
      check: check,
      kind: kind,
      senderDeviceId: senderDeviceId,
      storedSortKey: row.sortKey,
    );
  }

  @override
  Future<bool> hasMessage(String conversationId, String messageId) async {
    _checkOpen();
    final row = await _db
        .customSelect(
          'SELECT 1 FROM vault_messages '
          'WHERE conversation_id = ? AND message_id = ?',
          variables: [
            Variable.withString(conversationId),
            Variable.withString(messageId),
          ],
          readsFrom: {_db.vaultMessages},
        )
        .getSingleOrNull();
    return row != null;
  }

  @override
  Future<OutboxRead> outbox({String? conversationId}) async {
    _checkOpen();
    final query = _db.select(_db.vaultOutbox)
      ..orderBy([(t) => OrderingTerm.asc(t.sortKey)]);
    if (conversationId != null) {
      query.where((t) => t.conversationId.equals(conversationId));
    }
    final rows = await query.get();
    final items = <OutboxItem>[];
    final unreadable = <String>[];
    for (final row in rows) {
      try {
        items.add(await _outboxItem(row));
      } on VaultCorruptException {
        unreadable.add(row.idempotencyKey);
      }
    }
    return OutboxRead(items, unreadable);
  }

  /// One outbox row; [VaultCorruptException] when a value does not open or
  /// is malformed (the exception names the table only, never the value).
  Future<OutboxItem> _outboxItem(VaultOutboxRow row) async {
    final key = [row.idempotencyKey];
    Future<Uint8List> open(String column, Uint8List value) =>
        _openOrCorrupt(_tOutbox, column, key, value);
    final recipient = row.recipientUserId;
    final lastError = row.lastError;
    final createdAt = vaultSortKeyMicrosOrNull(row.sortKey);
    if (createdAt == null) throw const VaultCorruptException(_tOutbox);
    final attempts = int.tryParse(
      _readText(await open('attempts', row.attempts)),
    );
    if (attempts == null) throw const VaultCorruptException(_tOutbox);
    final stage = row.stage;
    if (!OutboxStage.all.contains(stage)) {
      throw const VaultCorruptException(_tOutbox);
    }
    final sealedInit = row.init;
    return OutboxItem(
      idempotencyKey: row.idempotencyKey,
      // A row the sealed migration left alone (it did not authenticate) has
      // neither id; both are derived from the key, as the migration does.
      localId: row.localId ?? row.idempotencyKey,
      expectedMessageId:
          row.expectedMessageId ?? expectedMessageId(uid, row.idempotencyKey),
      stage: stage,
      init: sealedInit == null ? null : await open('init', sealedInit),
      conversationId: row.conversationId,
      recipientUserId: recipient == null
          ? null
          : _readText(await open('recipient_user_id', recipient)),
      generation: row.generation,
      epoch: row.epoch,
      ciphertext: await open('ciphertext', row.ciphertext),
      reportCommitment: await open('report_commitment', row.reportCommitment),
      content: await open('content', row.content),
      createdAtMicros: createdAt,
      attempts: attempts,
      lastError: lastError == null
          ? null
          : _readText(await open('last_error', lastError)),
    );
  }

  @override
  Future<Uint8List?> setting(String key) async {
    _checkOpen();
    final row = await (_db.select(
      _db.vaultSettings,
    )..where((t) => t.settingKey.equals(key))).getSingleOrNull();
    if (row == null) return null;
    return _openOrCorrupt(_tSettings, 'value', [key], row.value);
  }

  @override
  Future<void> wipe() async {
    _checkOpen();
    if (Zone.current[_txZoneKey] != null) {
      throw StateError('wipe() inside a vault transaction.');
    }
    // Refuse every other call from now on, so no transaction can commit
    // rows under the key that is about to be destroyed.
    _wiping = true;
    try {
      // Rows first; if that fails the key stays, so nothing is half-gone.
      await _db.deleteAllRows();
    } catch (_) {
      _wiping = false;
      rethrow;
    }
    _closed = true;
    try {
      // Rebuild the file so no freed page keeps old ids or sealed bytes.
      // A failed VACUUM does not keep the key: the rows are already gone
      // and secure_delete zeroed their cells.
      try {
        await _db.vacuum();
      } catch (_) {}
      await _cipher.destroy();
    } finally {
      await _db.closeQuietly();
      _releaseRegistration();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _db.close();
    } finally {
      try {
        // Ends the cipher, zeroing its in-memory key; the stored key stays
        // (only wipe() destroys it).
        await _cipher.close();
      } finally {
        _releaseRegistration();
      }
    }
  }
}

class _DriftVaultTx implements VaultTx {
  _DriftVaultTx(this._vault);

  final _DriftSecureVault _vault;
  bool _ended = false;

  VaultDatabase get _db => _vault._db;

  /// Refuses a call after the transaction ended, after the vault closed, or
  /// from outside the transaction body (where a write would land outside
  /// the transaction). Checked again after every seal, before writing.
  void _check() {
    _vault._checkOpen();
    if (_ended || !identical(Zone.current[_txZoneKey], this)) {
      throw StateError('VaultTx used outside its transaction.');
    }
  }

  @override
  Future<void> putDevice(Uint8List deviceId, Uint8List deviceState) async {
    _check();
    const key = [kVaultDeviceSlot];
    final id = await _vault._seal(_tDevice, 'device_id', key, deviceId);
    final state = await _vault._seal(
      _tDevice,
      'device_state',
      key,
      deviceState,
    );
    _check();
    await _db
        .into(_db.vaultDevice)
        .insertOnConflictUpdate(
          VaultDeviceCompanion.insert(
            slot: kVaultDeviceSlot,
            deviceId: id,
            deviceState: state,
          ),
        );
  }

  @override
  Future<void> putDeviceState(Uint8List deviceState) async {
    _check();
    final sealed = await _vault._seal(_tDevice, 'device_state', const [
      kVaultDeviceSlot,
    ], deviceState);
    _check();
    final updated =
        await (_db.update(_db.vaultDevice)
              ..where((t) => t.slot.equals(kVaultDeviceSlot)))
            .write(VaultDeviceCompanion(deviceState: Value(sealed)));
    if (updated == 0) {
      throw StateError('putDeviceState before putDevice.');
    }
  }

  @override
  Future<void> putGroup(GroupRecord record) async {
    _check();
    _requireComponents(record.generation, record.epoch);
    final createdAt = record.provisionalCreatedAtMicros;
    if (record.provisional && createdAt == null) {
      throw ArgumentError(
        'A provisional group needs provisionalCreatedAtMicros.',
      );
    }
    final pending = record.pending;
    if (pending != null) _requirePendingLimits(pending);
    // `clearProvisional` is the only way from provisional to final (it writes
    // the marks); nothing makes a final group provisional again.
    final stored = await _vault._groupRow(
      record.conversationId,
      record.generation,
    );
    if (stored != null && (stored.provisional == 1) != record.provisional) {
      throw StateError('putGroup never changes the provisional flag.');
    }
    final key = [record.conversationId, '${record.generation}'];
    final state = await _vault._seal(_tGroupStates, 'state', key, record.state);
    final sealedPending = pending == null
        ? null
        : await _vault._seal(_tGroupStates, 'pending', key, pending.encode());
    _check();
    // Only this table: the marks live in `vault_conversations` and are
    // written by clearProvisional, setAfterPair and setJoinHighWater alone.
    await _db
        .into(_db.vaultGroupStates)
        .insertOnConflictUpdate(
          VaultGroupStatesCompanion.insert(
            conversationId: record.conversationId,
            generation: record.generation,
            epoch: record.epoch,
            provisional: Value(record.provisional ? 1 : 0),
            provisionalCreatedAt: Value(record.provisional ? createdAt : null),
            state: state,
            pending: Value(sealedPending),
          ),
        );
  }

  @override
  Future<void> deleteGroup(String conversationId, int generation) async {
    _check();
    // The marks stay as they are: nothing wrote one for a provisional group.
    await (_db.delete(_db.vaultGroupStates)..where(
          (t) =>
              t.conversationId.equals(conversationId) &
              t.generation.equals(generation),
        ))
        .go();
  }

  /// The stored group of [generation] is provisional.
  Future<bool> _isProvisional(String conversationId, int generation) async {
    final row = await _vault._groupRow(conversationId, generation);
    return row != null && row.provisional == 1;
  }

  /// [StateError] unless [pair] is strictly above [mark] (an absent mark is
  /// below every pair), or when the stored group of its generation is
  /// provisional ([exceptGeneration]: a group being cleared right now).
  Future<void> _requireMarkable(
    String conversationId,
    MlsPair pair,
    MlsPair? mark, {
    int? exceptGeneration,
  }) async {
    _requirePair(pair);
    if (pair.generation != exceptGeneration &&
        await _isProvisional(conversationId, pair.generation)) {
      throw StateError('No mark is written for a provisional group.');
    }
    if (!MlsPair.above(pair, mark)) {
      throw StateError('A mark never moves back.');
    }
  }

  /// Makes sure a `vault_conversations` row exists (marks and sync NULL), so
  /// a later write can set only its own columns.
  Future<void> _ensureConversation(String conversationId) => _db
      .into(_db.vaultConversations)
      .insert(
        VaultConversationsCompanion.insert(conversationId: conversationId),
        mode: InsertMode.insertOrIgnore,
      );

  @override
  Future<void> clearProvisional(
    String conversationId,
    int generation, {
    required MlsPair afterPair,
    MlsPair? joinHighWater,
  }) async {
    _check();
    final group = await _vault._groupRow(conversationId, generation);
    if (group == null || group.provisional != 1) {
      throw StateError('There is no provisional group to clear.');
    }
    final stored = await _vault._conversationRow(conversationId);
    final storedAfter = stored == null
        ? null
        : _markOf(stored.afterGeneration, stored.afterEpoch);
    final storedJoin = stored == null
        ? null
        : _markOf(stored.joinGeneration, stored.joinEpoch);
    // Everything is checked before anything is written, so a refusal leaves
    // both the flag and the marks as they were.
    await _requireMarkable(
      conversationId,
      afterPair,
      storedAfter,
      exceptGeneration: generation,
    );
    if (joinHighWater != null) {
      await _requireMarkable(
        conversationId,
        joinHighWater,
        storedJoin,
        exceptGeneration: generation,
      );
    }
    // The marks of a cleared group are its own generation's: a pair of
    // another generation would move a mark past welcomes still to come.
    if (afterPair.generation != generation ||
        (joinHighWater != null && joinHighWater.generation != generation)) {
      throw ArgumentError('A mark is not of the cleared generation.');
    }
    await (_db.update(_db.vaultGroupStates)..where(
          (t) =>
              t.conversationId.equals(conversationId) &
              t.generation.equals(generation),
        ))
        .write(
          const VaultGroupStatesCompanion(
            provisional: Value(0),
            provisionalCreatedAt: Value(null),
          ),
        );
    await _ensureConversation(conversationId);
    await (_db.update(
      _db.vaultConversations,
    )..where((t) => t.conversationId.equals(conversationId))).write(
      VaultConversationsCompanion(
        afterGeneration: Value(afterPair.generation),
        afterEpoch: Value(afterPair.epoch),
        joinGeneration: joinHighWater == null
            ? const Value.absent()
            : Value(joinHighWater.generation),
        joinEpoch: joinHighWater == null
            ? const Value.absent()
            : Value(joinHighWater.epoch),
      ),
    );
  }

  @override
  Future<void> setAfterPair(String conversationId, MlsPair pair) async {
    _check();
    final stored = await _vault._conversationRow(conversationId);
    await _requireMarkable(
      conversationId,
      pair,
      stored == null
          ? null
          : _markOf(stored.afterGeneration, stored.afterEpoch),
    );
    await _ensureConversation(conversationId);
    await (_db.update(
      _db.vaultConversations,
    )..where((t) => t.conversationId.equals(conversationId))).write(
      VaultConversationsCompanion(
        afterGeneration: Value(pair.generation),
        afterEpoch: Value(pair.epoch),
      ),
    );
  }

  @override
  Future<void> setJoinHighWater(String conversationId, MlsPair pair) async {
    _check();
    final stored = await _vault._conversationRow(conversationId);
    await _requireMarkable(
      conversationId,
      pair,
      stored == null ? null : _markOf(stored.joinGeneration, stored.joinEpoch),
    );
    await _ensureConversation(conversationId);
    await (_db.update(
      _db.vaultConversations,
    )..where((t) => t.conversationId.equals(conversationId))).write(
      VaultConversationsCompanion(
        joinGeneration: Value(pair.generation),
        joinEpoch: Value(pair.epoch),
      ),
    );
  }

  @override
  Future<void> putConversationSync(
    String conversationId,
    ConversationSync sync,
  ) async {
    _check();
    _requireSync(sync);
    final sealed = await _vault._seal(_tConversations, 'sync', [
      conversationId,
    ], sync.encode());
    _check();
    await _ensureConversation(conversationId);
    // Only the sync column: never the marks.
    await (_db.update(_db.vaultConversations)
          ..where((t) => t.conversationId.equals(conversationId)))
        .write(VaultConversationsCompanion(sync: Value(sealed)));
  }

  @override
  Future<void> putMember(MemberRecord member) async {
    _check();
    if (member.side != MemberSide.mine &&
        member.side != MemberSide.theirs &&
        member.side != MemberSide.unattributed) {
      throw ArgumentError.value(member.side, 'side', 'unknown member side');
    }
    _requirePair(member.since);
    final hex = vaultDeviceIdHex(member.deviceId);
    final sealed = await _vault._seal(_tMembers, 'signature_key', [
      member.conversationId,
      hex,
    ], member.signatureKey);
    _check();
    await _db
        .into(_db.vaultMembers)
        .insertOnConflictUpdate(
          VaultMembersCompanion.insert(
            conversationId: member.conversationId,
            deviceId: hex,
            side: member.side,
            sinceGeneration: member.since.generation,
            sinceEpoch: member.since.epoch,
            signatureKey: sealed,
          ),
        );
  }

  @override
  Future<void> deleteMember(String conversationId, Uint8List deviceId) async {
    _check();
    await (_db.delete(_db.vaultMembers)..where(
          (t) =>
              t.conversationId.equals(conversationId) &
              t.deviceId.equals(vaultDeviceIdHex(deviceId)),
        ))
        .go();
  }

  @override
  Future<void> addSent(
    String conversationId,
    MlsPair pair,
    String digestHex,
  ) async {
    _check();
    _requirePair(pair);
    if (!_digestPattern.hasMatch(digestHex)) {
      throw ArgumentError.value(digestHex, 'digestHex', 'not 64 hex');
    }
    await _db
        .into(_db.vaultSent)
        .insert(
          VaultSentCompanion.insert(
            conversationId: conversationId,
            generation: pair.generation,
            epoch: pair.epoch,
            digest: digestHex,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  @override
  Future<void> clearSentBefore(String conversationId, MlsPair pair) async {
    _check();
    _requirePair(pair);
    await (_db.delete(_db.vaultSent)..where(
          (t) =>
              t.conversationId.equals(conversationId) &
              (t.generation.isSmallerThanValue(pair.generation) |
                  (t.generation.equals(pair.generation) &
                      t.epoch.isSmallerThanValue(pair.epoch))),
        ))
        .go();
  }

  @override
  Future<void> putMessage(StoredMessage m) async {
    _check();
    if (!StoredMessageState.all.contains(m.state)) {
      throw ArgumentError.value(m.state, 'state', 'unknown message state');
    }
    final visible = m.state == StoredMessageState.visible;
    if (visible != (m.content != null)) {
      throw ArgumentError(
        'A visible message needs content; any other state has none.',
      );
    }
    if (!StoredMessageCheck.all.contains(m.check)) {
      throw ArgumentError.value(m.check, 'check', 'unknown message check');
    }
    if (!StoredMessageKind.all.contains(m.kind)) {
      throw ArgumentError.value(m.kind, 'kind', 'unknown message kind');
    }
    if (m.check != StoredMessageCheck.ok &&
        !(visible && m.kind == StoredMessageKind.message)) {
      throw ArgumentError(
        'A check other than ok belongs to a visible message row only.',
      );
    }
    final sortKey = vaultSortKey(m.createdAtMicros, m.messageId);
    final key = [m.conversationId, m.messageId];
    // The legacy sealed flag is always written equal to `mine`.
    final fromSelf = await _vault._seal(
      _tMessages,
      'from_self',
      key,
      _flag(m.mine),
    );
    final content = m.content;
    final sealedContent = content == null
        ? null
        : await _vault._seal(_tMessages, 'content', key, content);
    final sender = m.senderDeviceId;
    final sealedSender = sender == null
        ? null
        : await _vault._seal(_tMessages, 'sender_device_id', key, sender);
    _check();
    await _db
        .into(_db.vaultMessages)
        .insertOnConflictUpdate(
          VaultMessagesCompanion.insert(
            conversationId: m.conversationId,
            messageId: m.messageId,
            sortKey: sortKey,
            state: m.state,
            generation: m.generation,
            epoch: m.epoch,
            fromSelf: fromSelf,
            content: Value(sealedContent),
            checkState: Value(m.check),
            kind: Value(m.kind),
            mine: Value(m.mine ? 1 : 0),
            senderDeviceId: Value(sealedSender),
          ),
        );
  }

  @override
  Future<void> setMessageState(
    String conversationId,
    String messageId,
    String state,
  ) async {
    _check();
    if (!StoredMessageState.all.contains(state) ||
        state == StoredMessageState.visible) {
      throw ArgumentError.value(state, 'state', 'not a tombstone state');
    }
    await (_db.update(_db.vaultMessages)..where(
          (t) =>
              t.conversationId.equals(conversationId) &
              t.messageId.equals(messageId),
        ))
        .write(
          VaultMessagesCompanion(
            state: Value(state),
            content: const Value(null),
            // A check other than ok belongs to a visible message only.
            checkState: const Value(StoredMessageCheck.ok),
          ),
        );
  }

  @override
  Future<void> deleteConversation(
    String conversationId, {
    int? upToCreatedAtMicros,
  }) async {
    _check();
    final query = _db.delete(_db.vaultMessages);
    if (upToCreatedAtMicros == null) {
      query.where((t) => t.conversationId.equals(conversationId));
    } else {
      // Inclusive: a message created at exactly the bound is deleted. Every
      // creation time is >= 0, so a negative bound deletes nothing. No
      // arithmetic on the bound (the largest int must not wrap): every key
      // of a message created at or before it starts with its 20 digits
      // followed by '|', which sorts below the same digits followed by '}';
      // any later time has a larger digit prefix.
      if (upToCreatedAtMicros < 0) return;
      final below = '${upToCreatedAtMicros.toString().padLeft(20, '0')}}';
      query.where(
        (t) =>
            t.conversationId.equals(conversationId) &
            t.sortKey.isSmallerThanValue(below),
      );
    }
    await query.go();
  }

  @override
  Future<void> putOutbox(OutboxItem item) async {
    _check();
    if (item.localId.isEmpty || item.expectedMessageId.isEmpty) {
      throw ArgumentError(
        'An outbox item needs a local id and an expected message id.',
      );
    }
    if ((item.conversationId == null) == (item.recipientUserId == null)) {
      throw ArgumentError(
        'An outbox item has a conversation id or a recipient, not both.',
      );
    }
    _requireComponents(item.generation, item.epoch);
    switch (item.stage) {
      case OutboxStage.plain:
        if (item.ciphertext.isNotEmpty ||
            item.reportCommitment.isNotEmpty ||
            item.generation != 0 ||
            item.epoch != 0 ||
            item.init != null) {
          throw ArgumentError(
            'A plain outbox item has no ciphertext, report commitment or '
            'init, and the pair (0, 0).',
          );
        }
      case OutboxStage.encrypted:
        if (item.ciphertext.isEmpty || item.ciphertext.length > 8192) {
          throw ArgumentError(
            'An encrypted outbox item needs a ciphertext of 1 to 8192 bytes.',
          );
        }
        if (item.reportCommitment.length != 32) {
          throw ArgumentError(
            'An encrypted outbox item needs a 32-byte report commitment.',
          );
        }
      default:
        throw ArgumentError.value(item.stage, 'stage', 'unknown outbox stage');
    }
    final key = [item.idempotencyKey];
    Future<Uint8List> seal(String column, Uint8List value) =>
        _vault._seal(_tOutbox, column, key, value);
    final recipient = item.recipientUserId;
    final lastError = item.lastError;
    final init = item.init;
    final companion = VaultOutboxCompanion.insert(
      idempotencyKey: item.idempotencyKey,
      stage: Value(item.stage),
      expectedMessageId: Value(item.expectedMessageId),
      localId: Value(item.localId),
      init: Value(init == null ? null : await seal('init', init)),
      conversationId: Value(item.conversationId),
      sortKey: vaultSortKey(item.createdAtMicros, item.idempotencyKey),
      generation: item.generation,
      epoch: item.epoch,
      recipientUserId: Value(
        recipient == null
            ? null
            : await seal('recipient_user_id', _text(recipient)),
      ),
      ciphertext: await seal('ciphertext', item.ciphertext),
      reportCommitment: await seal('report_commitment', item.reportCommitment),
      content: await seal('content', item.content),
      attempts: await seal('attempts', _text('${item.attempts}')),
      lastError: Value(
        lastError == null ? null : await seal('last_error', _text(lastError)),
      ),
    );
    _check();
    await _db.into(_db.vaultOutbox).insertOnConflictUpdate(companion);
  }

  @override
  Future<void> deleteOutbox(String idempotencyKey) async {
    _check();
    await (_db.delete(
      _db.vaultOutbox,
    )..where((t) => t.idempotencyKey.equals(idempotencyKey))).go();
  }

  @override
  Future<void> putSetting(String key, Uint8List value) async {
    _check();
    final sealed = await _vault._seal(_tSettings, 'value', [key], value);
    _check();
    await _db
        .into(_db.vaultSettings)
        .insertOnConflictUpdate(
          VaultSettingsCompanion.insert(settingKey: key, value: sealed),
        );
  }
}
