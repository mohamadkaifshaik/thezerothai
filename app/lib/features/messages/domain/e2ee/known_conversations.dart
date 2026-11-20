import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';

/// Vault setting: the conversations this vault ever recorded ANY encryption
/// fact for, with the peer's user reference (security read C1). Sealed
/// `{"v":1,"ids":[...],"peers":{...}}`; the key holds no id.
const String kVaultSettingKnownConversations = 'messages.e2ee.known';

/// The in-memory image of [kVaultSettingKnownConversations] and the writes
/// that extend it. The setting is vault-wide while callers hold different
/// conversation locks, so every write reads the stored record FRESH inside the
/// caller's `runWrite` body (those bodies are serialised for the vault) and
/// writes the union: a record read before the body is never written back.
///
/// Never logs. No `toString`.
class KnownConversations {
  KnownConversations({required VaultSession session}) : _session = session;

  final VaultSession _session;
  SecureVault? _loadedFor;
  final List<String> _ids = [];
  final Map<String, String> _peers = {};

  // Additions made by `addIn` whose transaction has not returned yet.
  final List<String> _stagedIds = [];
  final Map<String, String> _stagedPeers = {};

  /// Loaded once when the vault becomes ready; in memory after that. Replaces
  /// the image (a vault that changed, L3). A record that cannot be read leaves
  /// the image empty and rethrows.
  Future<void> load(SecureVault vault) async {
    _loadedFor = null;
    _ids.clear();
    _peers.clear();
    _stagedIds.clear();
    _stagedPeers.clear();
    final record = await _read(vault);
    _ids.addAll(record.ids);
    _peers.addAll(record.peers);
    _loadedFor = vault;
  }

  /// Forgets everything (sign-out or a vault that closed).
  void clear() {
    _loadedFor = null;
    _ids.clear();
    _peers.clear();
    _stagedIds.clear();
    _stagedPeers.clear();
  }

  /// False before [load] returned.
  bool get loaded => _loadedFor != null;

  /// True when the image was loaded for [vault] (this exact vault object).
  bool isLoadedFor(SecureVault vault) => identical(_loadedFor, vault);

  bool contains(String conversationId) => _ids.contains(conversationId);

  /// The known ids, in the order they were first stored.
  List<String> get ids => List.unmodifiable(_ids);

  /// The peer reference stored for [conversationId], or null.
  String? peerOf(String conversationId) => _peers[conversationId];

  /// C1 3a: the conversation of a recipient, resolved against the stored peer
  /// refs; null when the ref is unknown. A ref stored for two or more ids
  /// resolves to the most recently active of them (newest stored message) that
  /// has a stored group, else the most recent of them; never null then. A tie
  /// keeps the id stored first. One candidate: no vault read.
  Future<String?> conversationForPeer(
    SecureVault vault,
    String peerUserId,
  ) async {
    final candidates = [
      for (final id in _ids)
        if (_peers[id] == peerUserId) id,
    ];
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.single;
    String? best;
    var bestHasGroup = false;
    var bestNewest = -1;
    for (final id in candidates) {
      final hasGroup = (await vault.groups(id)).any((g) => !g.provisional);
      final newest = await vault.messages(id, limit: 1);
      final at = newest.isEmpty ? 0 : newest.first.createdAtMicros;
      final better =
          best == null ||
          (hasGroup && !bestHasGroup) ||
          (hasGroup == bestHasGroup && at > bestNewest);
      if (better) {
        best = id;
        bestHasGroup = hasGroup;
        bestNewest = at;
      }
    }
    return best;
  }

  /// Adds the id (and the peer ref when given) INSIDE the caller's
  /// transaction, which must run in a `runWrite` body over [vault] (the vault
  /// that body checked). The stored record is read fresh here. Refuses (a
  /// [StateError], nothing written) when the image was loaded for another
  /// vault: a set of one vault is never written into another's transaction.
  /// The in-memory image changes only when the caller calls [commitStaged]
  /// after its transaction returned ([discardStaged] when it failed).
  Future<void> addIn(
    VaultTx tx,
    SecureVault vault,
    String conversationId, {
    String? peerUserId,
  }) async {
    if (!identical(vault, _loadedFor)) {
      throw StateError('The known conversations are not loaded.');
    }
    final record = await _read(vault);
    final ids = [...record.ids];
    final peers = {...record.peers};
    var changed = false;
    if (!ids.contains(conversationId)) {
      ids.add(conversationId);
      changed = true;
    }
    // First write wins: a stored ref is never replaced.
    if (peerUserId != null &&
        peerUserId.isNotEmpty &&
        !peers.containsKey(conversationId)) {
      peers[conversationId] = peerUserId;
      changed = true;
    }
    if (changed) {
      await tx.putSetting(kVaultSettingKnownConversations, _encode(ids, peers));
    }
    _stagedIds
      ..clear()
      ..addAll(ids);
    _stagedPeers
      ..clear()
      ..addAll(peers);
  }

  /// The caller's transaction returned: the image takes what [addIn] wrote.
  void commitStaged() {
    if (_stagedIds.isEmpty && _stagedPeers.isEmpty) return;
    _ids
      ..clear()
      ..addAll(_stagedIds);
    _peers
      ..clear()
      ..addAll(_stagedPeers);
    _stagedIds.clear();
    _stagedPeers.clear();
  }

  /// The caller's transaction failed: nothing was kept.
  void discardStaged() {
    _stagedIds.clear();
    _stagedPeers.clear();
  }

  /// Its own `runWrite` (the peer ref of a conversation learned later, and
  /// `noteEncrypted`): the same fresh-read rule. Never call it from inside a
  /// `runWrite` body or a transaction.
  Future<void> add(String conversationId, {String? peerUserId}) async {
    final loadedFor = _loadedFor;
    if (loadedFor == null) throw StateError('Not loaded.');
    await _session.runWrite((vault) async {
      if (!identical(vault, loadedFor)) {
        throw StateError('The vault changed.');
      }
      try {
        await vault.transaction((tx) async {
          await addIn(tx, vault, conversationId, peerUserId: peerUserId);
        });
      } on Object {
        discardStaged();
        rethrow;
      }
      commitStaged();
    });
  }

  static Future<({List<String> ids, Map<String, String> peers})> _read(
    SecureVault vault,
  ) async {
    final bytes = await vault.setting(kVaultSettingKnownConversations);
    if (bytes == null) return (ids: <String>[], peers: <String, String>{});
    try {
      final m = jsonDecode(utf8.decode(bytes));
      if (m is! Map<String, Object?> || m['v'] != 1) {
        throw const FormatException('shape');
      }
      final ids = m['ids'];
      final peers = m['peers'];
      if (ids is! List<Object?> || peers is! Map<String, Object?>) {
        throw const FormatException('shape');
      }
      return (
        ids: [
          for (final id in ids)
            if (id is String) id else throw const FormatException('id'),
        ],
        peers: {
          for (final e in peers.entries)
            e.key: e.value is String
                ? e.value! as String
                : throw const FormatException('peer'),
        },
      );
    } on FormatException {
      throw const VaultCorruptException('vault_settings');
    }
  }

  static Uint8List _encode(List<String> ids, Map<String, String> peers) =>
      Uint8List.fromList(
        utf8.encode(jsonEncode({'v': 1, 'ids': ids, 'peers': peers})),
      );
}
