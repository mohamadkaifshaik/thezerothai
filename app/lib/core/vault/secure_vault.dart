import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';

import 'vault_cipher.dart';
import 'vault_database.dart';
import 'vault_status.dart';

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
class StoredMessage {
  const StoredMessage({
    required this.conversationId,
    required this.messageId,
    required this.createdAtMicros,
    required this.fromSelf,
    required this.state,
    required this.generation,
    required this.epoch,
    required this.content,
  });

  final String conversationId;
  final String messageId;
  final int createdAtMicros;
  final bool fromSelf;

  /// One of [StoredMessageState].
  final String state;
  final int generation;
  final int epoch;

  /// The decrypted `MessageContent` bytes; null unless [state] is
  /// [StoredMessageState.visible].
  final Uint8List? content;

  /// The key [SecureVault.messages] pages by (`beforeSortKey`).
  String get sortKey => vaultSortKey(createdAtMicros, messageId);

  @override
  String toString() => 'StoredMessage($conversationId, $messageId)';
}

/// A message encrypted for sending and not yet accepted by the server.
/// Exactly one of [conversationId] and [recipientUserId] is set.
/// [toString] shows the idempotency key only.
class OutboxItem {
  const OutboxItem({
    required this.idempotencyKey,
    this.conversationId,
    this.recipientUserId,
    required this.generation,
    required this.epoch,
    required this.ciphertext,
    required this.reportCommitment,
    required this.content,
    required this.createdAtMicros,
    this.attempts = 0,
    this.lastError,
  });

  final String idempotencyKey;
  final String? conversationId;
  final String? recipientUserId;
  final int generation;
  final int epoch;
  final Uint8List ciphertext;
  final Uint8List reportCommitment;
  final Uint8List content;
  final int createdAtMicros;
  final int attempts;
  final String? lastError;

  @override
  String toString() => 'OutboxItem($idempotencyKey)';
}

/// The MLS group state of one conversation. [toString] shows the id only.
class GroupRecord {
  const GroupRecord({
    required this.conversationId,
    required this.generation,
    required this.epoch,
    required this.state,
    required this.pendingCommit,
  });

  final String conversationId;
  final int generation;
  final int epoch;
  final Uint8List state;
  final bool pendingCommit;

  @override
  String toString() => 'GroupRecord($conversationId)';
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
/// The vault does NOT serialise its callers: two concurrent [transaction]s
/// run one after the other inside the database, but nothing orders a read
/// against a write, or two writers of one conversation. The vault session
/// (a later task) owns that, with a keyed mutex and, on the web, single-tab
/// ownership.
///
/// After [close] or [wipe], every call throws [StateError].
abstract interface class SecureVault {
  String get uid;

  /// Runs [body] in one database transaction: if [body] throws, nothing it
  /// wrote is kept. [tx] must only be used inside [body] (otherwise
  /// [StateError]). Transactions do not nest ([StateError]). Reads made
  /// through this vault inside [body] see [body]'s writes.
  Future<T> transaction<T>(Future<T> Function(VaultTx tx) body);

  /// This device's id, or null before the device was created.
  Future<Uint8List?> deviceId();

  /// This device's engine state, or null before the device was created.
  Future<Uint8List?> deviceState();

  Future<GroupRecord?> group(String conversationId);

  /// Up to [limit] messages of [conversationId], newest first, strictly
  /// older than [beforeSortKey] when given ([StoredMessage.sortKey]). There
  /// is no cap on history: page with the last returned sort key until the
  /// result is shorter than [limit]. A row that no longer opens under the
  /// vault key comes back as [StoredMessageState.undecryptable] with no
  /// content; it is never deleted.
  Future<List<StoredMessage>> messages(
    String conversationId, {
    int limit = 50,
    String? beforeSortKey,
  });

  Future<StoredMessage?> message(String conversationId, String messageId);

  /// Whether the message is stored (any state). Reads no sealed column, so
  /// it is the dedupe check before decrypting.
  Future<bool> hasMessage(String conversationId, String messageId);

  /// Pending items, oldest first, of one conversation or of all.
  Future<List<OutboxItem>> outbox({String? conversationId});

  /// A value stored with [VaultTx.putSetting], or null.
  Future<Uint8List?> setting(String key);

  /// Deletes every row (one transaction), then destroys the cipher (its
  /// platform key). If the rows cannot be deleted this throws, the cipher is
  /// left alone and the vault stays open (nothing was deleted). Once the
  /// rows are gone the vault is closed, even if destroying the cipher throws.
  Future<void> wipe();

  Future<void> close();
}

/// The writes of one [SecureVault.transaction].
abstract interface class VaultTx {
  /// Creates or replaces this device's id and state.
  Future<void> putDevice(Uint8List deviceId, Uint8List deviceState);

  /// Replaces this device's state; [StateError] when there is no device.
  Future<void> putDeviceState(Uint8List deviceState);

  Future<void> putGroup(GroupRecord record);
  Future<void> deleteGroup(String conversationId);

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
  /// those created at or before [upToCreatedAtMicros]. Group state and
  /// outbox items are not touched ([deleteGroup], [deleteOutbox]).
  Future<void> deleteConversation(
    String conversationId, {
    int? upToCreatedAtMicros,
  });

  Future<void> putOutbox(OutboxItem item);
  Future<void> deleteOutbox(String idempotencyKey);
  Future<void> putSetting(String key, Uint8List value);
}

/// Opens [uid]'s vault on [db] with [cipher]: the part of `openVault` that
/// does not depend on the platform. [db] is closed on every failure.
///
/// - No `vault_meta` row and no other rows: a new vault. The owner stamp
///   and the sealed sentinel are written in one transaction.
/// - The owner stamp names another uid: every row is deleted (the vault of
///   another user is never readable by, or mixed with, this one), then it
///   is a new vault.
/// - The sentinel opens to the expected value: ready.
/// - The sentinel does not authenticate, or holds another value, or there
///   are rows but no `vault_meta` row: [VaultOpenException] with
///   [VaultStatus.keyLost]. Nothing is changed: wiping after key loss is
///   decided by the caller (it needs the loss confirmed on two launches) and
///   done with `wipeVaultFile`.
/// - The cipher is unavailable, the storage fails, the open takes longer
///   than [openTimeout], or the file was stamped by a newer schema:
///   [VaultStatus.unavailable]. This open writes nothing of this user's
///   vault, with two exceptions: on the owner-mismatch path the other
///   owner's rows are already deleted before the sentinel is sealed, and
///   after a timeout the abandoned open may still finish in the background
///   (at most it stamps a new, empty vault for this uid).
Future<SecureVault> openVaultOnDatabase(
  VaultDatabase db, {
  required String uid,
  required VaultCipher cipher,
  Duration openTimeout = const Duration(seconds: 30),
}) async {
  try {
    await _claim(db, uid, cipher).timeout(openTimeout);
    return _DriftSecureVault(db, uid, cipher);
  } catch (error) {
    await db.closeQuietly();
    throw VaultOpenException(_statusFor(error));
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

Future<void> _claim(VaultDatabase db, String uid, VaultCipher cipher) async {
  // The first query opens the file (and, on the web, checks the storage).
  final meta = await (db.select(
    db.vaultMeta,
  )..where((t) => t.metaKey.equals(kVaultMetaKey))).getSingleOrNull();

  if (meta != null && meta.ownerUid == uid) {
    if (meta.schemaVersion > kVaultSchemaVersion) {
      // Written by a newer build (an app downgrade): leave it as it is.
      throw const VaultOpenException(VaultStatus.unavailable);
    }
    final opened = await cipher.open(
      _sentinelLabel,
      _sentinelRowKey,
      meta.sentinel,
    );
    if (utf8.decode(opened, allowMalformed: true) != kVaultSentinel) {
      throw const VaultOpenException(VaultStatus.keyLost);
    }
    return;
  }

  if (meta != null) {
    // Another user's stamp: never readable by, or mixed with, this user.
    await db.deleteAllRows();
  } else if (await db.hasDataRows()) {
    // Rows without a stamp and sentinel: inconsistent, treated as loss.
    throw const VaultOpenException(VaultStatus.keyLost);
  }

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
}

/// The zone value that marks code running inside a vault transaction body.
const Symbol _txZoneKey = #dzerothVaultTransaction;

const String _tDevice = 'vault_device';
const String _tGroups = 'vault_groups';
const String _tMessages = 'vault_messages';
const String _tOutbox = 'vault_outbox';
const String _tSettings = 'vault_settings';

Uint8List _flag(bool value) => Uint8List.fromList([value ? 1 : 0]);
bool _readFlag(Uint8List bytes) => bytes.length == 1 && bytes[0] == 1;
Uint8List _text(String value) => Uint8List.fromList(utf8.encode(value));
String _readText(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true);

class _DriftSecureVault implements SecureVault {
  _DriftSecureVault(this._db, this.uid, this._cipher);

  final VaultDatabase _db;
  final VaultCipher _cipher;
  bool _closed = false;

  @override
  final String uid;

  void _checkOpen() {
    if (_closed) throw StateError('The vault is closed.');
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
  Future<GroupRecord?> group(String conversationId) async {
    _checkOpen();
    final row = await (_db.select(
      _db.vaultGroups,
    )..where((t) => t.conversationId.equals(conversationId))).getSingleOrNull();
    if (row == null) return null;
    final key = [conversationId];
    return GroupRecord(
      conversationId: row.conversationId,
      generation: row.generation,
      epoch: row.epoch,
      state: await _openOrCorrupt(_tGroups, 'state', key, row.state),
      pendingCommit: _readFlag(
        await _openOrCorrupt(
          _tGroups,
          'pending_commit',
          key,
          row.pendingCommit,
        ),
      ),
    );
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
    var fromSelf = false;
    Uint8List? content;
    try {
      fromSelf = _readFlag(
        await _open(_tMessages, 'from_self', key, row.fromSelf),
      );
      final sealed = row.content;
      if (sealed != null) {
        content = await _open(_tMessages, 'content', key, sealed);
      }
    } on VaultRowException {
      state = StoredMessageState.undecryptable;
      fromSelf = false;
      content = null;
    }
    return StoredMessage(
      conversationId: row.conversationId,
      messageId: row.messageId,
      createdAtMicros: vaultSortKeyMicros(row.sortKey),
      fromSelf: fromSelf,
      state: state,
      generation: row.generation,
      epoch: row.epoch,
      content: content,
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
  Future<List<OutboxItem>> outbox({String? conversationId}) async {
    _checkOpen();
    final query = _db.select(_db.vaultOutbox)
      ..orderBy([(t) => OrderingTerm.asc(t.sortKey)]);
    if (conversationId != null) {
      query.where((t) => t.conversationId.equals(conversationId));
    }
    final rows = await query.get();
    final items = <OutboxItem>[];
    for (final row in rows) {
      final key = [row.idempotencyKey];
      Future<Uint8List> open(String column, Uint8List value) =>
          _openOrCorrupt(_tOutbox, column, key, value);
      final recipient = row.recipientUserId;
      final lastError = row.lastError;
      items.add(
        OutboxItem(
          idempotencyKey: row.idempotencyKey,
          conversationId: row.conversationId,
          recipientUserId: recipient == null
              ? null
              : _readText(await open('recipient_user_id', recipient)),
          generation: row.generation,
          epoch: row.epoch,
          ciphertext: await open('ciphertext', row.ciphertext),
          reportCommitment: await open(
            'report_commitment',
            row.reportCommitment,
          ),
          content: await open('content', row.content),
          createdAtMicros: vaultSortKeyMicros(row.sortKey),
          attempts: int.parse(_readText(await open('attempts', row.attempts))),
          lastError: lastError == null
              ? null
              : _readText(await open('last_error', lastError)),
        ),
      );
    }
    return items;
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
    // Rows first; if that fails the key stays, so nothing is half-gone.
    await _db.deleteAllRows();
    _closed = true;
    try {
      await _cipher.destroy();
    } finally {
      await _db.closeQuietly();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _db.close();
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
    final key = [record.conversationId];
    final state = await _vault._seal(_tGroups, 'state', key, record.state);
    final pending = await _vault._seal(
      _tGroups,
      'pending_commit',
      key,
      _flag(record.pendingCommit),
    );
    _check();
    await _db
        .into(_db.vaultGroups)
        .insertOnConflictUpdate(
          VaultGroupsCompanion.insert(
            conversationId: record.conversationId,
            generation: record.generation,
            epoch: record.epoch,
            state: state,
            pendingCommit: pending,
          ),
        );
  }

  @override
  Future<void> deleteGroup(String conversationId) async {
    _check();
    await (_db.delete(
      _db.vaultGroups,
    )..where((t) => t.conversationId.equals(conversationId))).go();
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
    final sortKey = vaultSortKey(m.createdAtMicros, m.messageId);
    final key = [m.conversationId, m.messageId];
    final fromSelf = await _vault._seal(
      _tMessages,
      'from_self',
      key,
      _flag(m.fromSelf),
    );
    final content = m.content;
    final sealedContent = content == null
        ? null
        : await _vault._seal(_tMessages, 'content', key, content);
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
      // Every key of a message created at or before the bound sorts below
      // the 20-digit prefix of the next microsecond.
      final below = (upToCreatedAtMicros + 1).toString().padLeft(20, '0');
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
    if ((item.conversationId == null) == (item.recipientUserId == null)) {
      throw ArgumentError(
        'An outbox item has a conversation id or a recipient, not both.',
      );
    }
    final key = [item.idempotencyKey];
    Future<Uint8List> seal(String column, Uint8List value) =>
        _vault._seal(_tOutbox, column, key, value);
    final recipient = item.recipientUserId;
    final lastError = item.lastError;
    final companion = VaultOutboxCompanion.insert(
      idempotencyKey: item.idempotencyKey,
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
