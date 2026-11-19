import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_markers.dart';
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';

/// One device for [VaultSession] tests: platform keys, vault files, markers
/// and locks that survive across "launches" (new sessions over the same
/// world), and one [calls] log of every collaborator call that changes or
/// opens something, in order. Marker READS are not logged (the session may
/// read its markers with the flag off); marker writes are.
///
/// Log tokens: `owner.create`, `acquire:<uid>`, `release`, `cipher:<uid>`,
/// `open:<uid>`, `wipeFile:<uid>`, `key:<uid>` (a platform key deleted, by
/// `deleteVaultKey` or `VaultCipher.destroy`), `vault.wipe:<uid>`,
/// `vault.close:<uid>`, `hook:<uid>`, `ready:<uid>`, `markers.known:<uid>`,
/// `markers.keyLost:<uid>`, `markers.keyLostClear:<uid>`,
/// `markers.owed:<uid>`, `markers.clear:<uid>`.
class FakeVaultWorld {
  FakeVaultWorld() {
    markers.log = calls;
  }

  final List<String> calls = [];

  /// Platform keys: uid -> key version.
  final Map<String, int> keys = {};
  var _nextKey = 1;

  /// Vault files: uid -> file.
  final Map<String, FakeVaultFile> files = {};

  /// Hidden copies a later open created a new vault beside.
  final List<FakeVaultFile> strandedCopies = [];

  /// The storage a new vault is created in (the web's current choice).
  String currentStorage = 'opfsLocks';

  /// Uids whose cipher open throws [VaultKeyException] (keyLost) while a
  /// stored key exists (Android: the wrapped key no longer unwraps). Once the
  /// key is deleted a new one is made.
  final Set<String> cipherKeyLost = {};

  /// Uids whose cipher open throws [VaultKeyException] (unavailable).
  final Set<String> cipherUnavailable = {};

  /// Uids whose vault open throws this status (before anything else).
  final Map<String, VaultStatus> openFails = {};

  /// Uids whose `wipeVaultFile` fails (unavailable).
  final Set<String> wipeFileFails = {};

  /// Uids whose key delete fails (unavailable).
  final Set<String> keyDeleteFails = {};

  /// Uids whose `SecureVault.wipe()` fails before deleting rows.
  final Set<String> vaultWipeFails = {};

  /// Uids held by another tab (acquire answers false).
  final Set<String> heldElsewhere = {};

  final FakeVaultMarkers markers = FakeVaultMarkers();

  /// The owners the sessions created, newest last.
  final List<FakeVaultOwner> owners = [];

  int _launches = 0;

  /// A new app launch on this device: a new session with a new launch id.
  VaultSession launch({
    bool supported = true,
    Future<void> Function(SecureVault vault)? onVaultReady,
    Future<void> Function(String uid)? beforeExplicitWipe,
    Duration hookTimeout = kVaultExplicitWipeHookTimeout,
    List<Object>? reported,
  }) {
    _launches++;
    return VaultSession(
      openCipher: _openCipher,
      openVault: _openVault,
      wipeVaultFile: _wipeFile,
      deleteVaultKey: _deleteKey,
      createOwner: () {
        calls.add('owner.create');
        final owner = FakeVaultOwner(this);
        owners.add(owner);
        return owner;
      },
      markers: markers,
      supported: supported,
      launchId: 'launch-$_launches',
      // An injected clock: only stored as the marker's createdAt.
      now: () => DateTime.fromMicrosecondsSinceEpoch(1000, isUtc: true),
      onVaultReady: onVaultReady,
      beforeExplicitWipe: beforeExplicitWipe,
      explicitWipeHookTimeout: hookTimeout,
      onUnexpectedError: (error, _) => reported?.add(error),
    );
  }

  /// The key of [uid] is gone (an invalidated keystore key, a cleared
  /// IndexedDB record): the next cipher open makes a NEW key and the vault
  /// sentinel no longer opens.
  void loseKey(String uid) => keys.remove(uid);

  Future<VaultCipher> _openCipher(String uid) async {
    calls.add('cipher:$uid');
    if (cipherKeyLost.contains(uid) && keys.containsKey(uid)) {
      throw const VaultKeyException(VaultKeyFailure.keyLost);
    }
    if (cipherUnavailable.contains(uid)) {
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
    final existing = keys[uid];
    final version = existing ?? (keys[uid] = _nextKey++);
    return FakeWorldCipher(
      this,
      uid,
      version,
      freshlyCreated: existing == null,
    );
  }

  Future<SecureVault> _openVault({
    required String uid,
    required VaultCipher cipher,
    String? expectedStorage,
  }) async {
    calls.add('open:$uid');
    final fail = openFails[uid];
    if (fail != null) throw VaultOpenException(fail);
    final key = (cipher as FakeWorldCipher).version;
    var file = files[uid];
    final listed = file != null && !file.hidden;
    if (expectedStorage != null) {
      // The real opener refuses BEFORE creating anything.
      if (!listed || _api(file.storage) != _api(expectedStorage)) {
        throw const VaultOpenException(VaultStatus.storageChanged);
      }
    }
    var created = false;
    if (!listed) {
      if (file != null) {
        // A hidden copy and no marker: drift creates a second copy beside
        // it (the hidden one is kept in [strandedCopies]).
        strandedCopies.add(file);
      }
      file = files[uid] = FakeVaultFile(currentStorage, key);
      created = true;
    } else if (!file.stamped) {
      // An empty database (no sentinel, no rows): a new vault in it.
      file
        ..key = key
        ..stamped = true;
      created = true;
    } else if (file.key != key) {
      throw const VaultOpenException(VaultStatus.keyLost);
    }
    return FakeWorldVault(this, uid, file, cipher, created: created);
  }

  static String _api(String storage) =>
      storage.startsWith('opfs') ? 'opfs' : storage;

  Future<void> _wipeFile({required String uid, String? expectedStorage}) async {
    calls.add('wipeFile:$uid');
    if (wipeFileFails.contains(uid)) {
      throw const VaultOpenException(VaultStatus.unavailable);
    }
    final file = files[uid];
    if (expectedStorage != null &&
        (file == null ||
            file.hidden ||
            _api(file.storage) != _api(expectedStorage))) {
      throw const VaultOpenException(VaultStatus.unavailable);
    }
    // Only a listed copy is erased (a hidden one survives, as on the web).
    if (file != null && !file.hidden) files.remove(uid);
  }

  Future<void> _deleteKey({required String uid}) async {
    calls.add('key:$uid');
    if (keyDeleteFails.contains(uid)) {
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
    keys.remove(uid);
  }
}

class FakeVaultFile {
  FakeVaultFile(this.storage, this.key);

  final String storage;
  int key;
  final Map<String, String> rows = {};

  /// False for an empty database (no sentinel): what `SecureVault.wipe()`
  /// leaves behind, since it deletes rows but not the file.
  bool stamped = true;

  /// No sentinel and no rows.
  bool get empty => !stamped && rows.isEmpty;

  /// The probe cannot list this copy (e.g. OPFS gone).
  bool hidden = false;
}

class FakeWorldCipher implements VaultCipher {
  FakeWorldCipher(
    this._world,
    this.uid,
    this.version, {
    required this.freshlyCreated,
  });

  final FakeVaultWorld _world;
  final String uid;
  final int version;
  bool destroyed = false;

  @override
  final bool freshlyCreated;

  @override
  Future<void> destroy() async {
    destroyed = true;
    await _world._deleteKey(uid: uid);
  }

  @override
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> seal(String table, String rowKey, Uint8List plaintext) =>
      throw UnimplementedError();
}

class FakeWorldVault implements SecureVault {
  FakeWorldVault(
    this._world,
    this.uid,
    this._file,
    this._cipher, {
    required bool created,
  }) : createdThisOpen = created;

  final FakeVaultWorld _world;
  final FakeVaultFile _file;
  final VaultCipher _cipher;
  bool closed = false;

  @override
  final String uid;

  @override
  final bool createdThisOpen;

  @override
  String get storageName => _file.storage;

  @override
  Future<T> transaction<T>(Future<T> Function(VaultTx tx) body) {
    if (closed) throw StateError('closed');
    return body(_FakeTx(_file));
  }

  @override
  Future<Uint8List?> setting(String key) async {
    if (closed) throw StateError('closed');
    final v = _file.rows[key];
    return v == null ? null : Uint8List.fromList(v.codeUnits);
  }

  @override
  Future<void> wipe() async {
    _world.calls.add('vault.wipe:$uid');
    if (_world.vaultWipeFails.contains(uid)) {
      throw const VaultOpenException(VaultStatus.unavailable);
    }
    closed = true;
    // Rows only: the (empty) database stays, as with the real vault.
    _file
      ..rows.clear()
      ..stamped = false;
    await _cipher.destroy();
  }

  @override
  Future<void> close() async {
    if (closed) return;
    _world.calls.add('vault.close:$uid');
    closed = true;
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class _FakeTx implements VaultTx {
  _FakeTx(this._file);

  final FakeVaultFile _file;

  @override
  Future<void> putSetting(String key, Uint8List value) async {
    _file.rows[key] = String.fromCharCodes(value);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class FakeVaultOwner implements VaultOwner {
  FakeVaultOwner(this._world);

  final FakeVaultWorld _world;
  final StreamController<void> _lost = StreamController<void>.broadcast();
  String? owned;

  @override
  bool get supported => true;

  @override
  Future<bool> acquire(String uid) async {
    if (owned != null && owned != uid) {
      throw StateError('acquire for another uid while owning');
    }
    _world.calls.add('acquire:$uid');
    if (_world.heldElsewhere.contains(uid)) return false;
    owned = uid;
    return true;
  }

  @override
  Future<void> release() async {
    if (owned == null) return;
    _world.calls.add('release');
    owned = null;
  }

  @override
  Stream<void> get lost => _lost.stream;

  /// Another tab stole the lock.
  void steal() {
    owned = null;
    _lost.add(null);
  }
}

/// [VaultMarkers] in memory (they survive "launches" of one world).
class FakeVaultMarkers implements VaultMarkers {
  FakeVaultMarkers({this.persistent = true});

  @override
  bool persistent;

  final Map<String, KnownVault> knownByUid = {};
  final Map<String, String> keyLostByUid = {};
  final Set<String> owed = {};

  /// Owed wipes whose file step is done.
  final Set<String> fileDone = {};

  /// Every marker write throws while set.
  bool failWrites = false;

  /// Only [writeKnown] throws while set.
  bool failKnownWrites = false;

  /// The world's log (set by the world that owns it).
  List<String>? log;

  void _write(String token) {
    log?.add(token);
    if (failWrites) throw StateError('markers down');
  }

  @override
  Future<KnownVault?> known(String uid) async => knownByUid[uid];

  @override
  Future<List<KnownVault>> knownVaults() async => [...knownByUid.values];

  @override
  Future<void> writeKnown(KnownVault vault) async {
    _write('markers.known:${vault.uid}');
    if (failKnownWrites) throw StateError('markers down');
    knownByUid[vault.uid] = vault;
  }

  @override
  Future<String?> keyLostSeen(String uid) async => keyLostByUid[uid];

  @override
  Future<void> writeKeyLostSeen(String uid, String launchId) async {
    _write('markers.keyLost:$uid');
    keyLostByUid[uid] = launchId;
  }

  @override
  Future<void> clearKeyLostSeen(String uid) async {
    if (!keyLostByUid.containsKey(uid)) return;
    _write('markers.keyLostClear:$uid');
    keyLostByUid.remove(uid);
  }

  @override
  Future<List<OwedWipe>> owedWipes() async => [
    for (final uid in owed) OwedWipe(uid, fileDone: fileDone.contains(uid)),
  ];

  @override
  Future<void> writeWipeOwed(String uid, {bool fileDone = false}) async {
    _write(fileDone ? 'markers.owedFileDone:$uid' : 'markers.owed:$uid');
    owed.add(uid);
    if (fileDone) {
      this.fileDone.add(uid);
    } else {
      this.fileDone.remove(uid);
    }
  }

  @override
  Future<void> clearAll(String uid) async {
    _write('markers.clear:$uid');
    knownByUid.remove(uid);
    keyLostByUid.remove(uid);
    owed.remove(uid);
    fileDone.remove(uid);
  }
}
