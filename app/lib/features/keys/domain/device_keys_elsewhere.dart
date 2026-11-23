part of 'device_keys_service.dart';

/// Plan 5a Task 12 (R17, R12) with lane D PR 2: a device removed elsewhere.
///
/// **Detection (brief amendment 1, lane D audit SA M1 + CR Minor 7).** Only
/// the key directory's DEVICE_REMOVED answer to RegisterKeyDevice or
/// UploadKeyPackages sets it, on the first such answer. An absence from a
/// successful ListMyKeyDevices answer is never proof: the device registers
/// again under the same id and key (a thief holding a live session can
/// delete an honest device's doc with a SIGN_OUT removal, which needs no
/// recent sign-in, but cannot mark it without one; counting absences would
/// let the thief push honest devices into "set up again"). A really
/// removed id then answers that Register with DEVICE_REMOVED.
///
/// **While removed elsewhere** every run reads ListMyKeyDevices and nothing
/// else. Nothing is deleted. The status rests on the server's answer: a
/// lying server can stop a device, and only the user's choice changes
/// anything.
///
/// **Listed again (security read M5).** [kRemovedElsewhereListedAgain]
/// consecutive successful answers that list this device with its key
/// clear the marker (one transaction); an answer that lacks it resets the
/// count; a failed call neither counts nor resets. While the server's mark
/// lives the id is never listed, so in practice "set up again" is the way
/// out.
extension _Elsewhere on DeviceKeysService {
  void _setRemoved(SecureVault? vault) {
    _removedVault = vault;
    _listedAgain = 0;
    _removedFact.value = vault != null;
  }

  /// The vault's marker reads 0x01. Throws [VaultCorruptException] when it
  /// does not open.
  static Future<bool> _readRemoved(SecureVault vault) async {
    final bytes = await vault.setting(kVaultSettingRemovedElsewhere);
    return bytes != null && bytes.length == 1 && bytes[0] == 0x01;
  }

  /// At vault ready: the memory follows the stored marker of a vault this
  /// service has not seen yet. A marker that does not open is left to the
  /// run (which fails closed on it).
  Future<void> _loadRemoved(SecureVault vault) async {
    if (identical(_removedVault, vault)) return;
    bool marked;
    try {
      marked = await _readRemoved(vault);
    } on Object {
      marked = false;
    }
    if (_disposed || !identical(_session.vault, vault)) return;
    _setRemoved(marked ? vault : null);
  }

  /// In a run: the stored marker, read fresh, decides; the memory follows
  /// it (the listed count is kept while it stays set).
  Future<bool> _syncRemoved(SecureVault vault) async {
    final marked = await _readRemoved(vault);
    if (marked && !identical(_removedVault, vault)) _setRemoved(vault);
    if (!marked && identical(_removedVault, vault)) _setRemoved(null);
    return marked;
  }

  /// The FIRST DEVICE_REMOVED answer: the marker 0x01, the phase, and the
  /// hour's throttle (a run within the hour sends nothing). Memory follows
  /// even when the write fails (reported): the next run's Register then
  /// meets the same answer and writes it again.
  Future<void> _markRemoved(
    SecureVault vault,
    String uid,
    bool Function() live,
  ) async {
    if (!live()) {
      _status.value = DeviceKeysStatus.idle;
      return;
    }
    try {
      await _persist(
        vault,
        uid,
        (tx) => tx.putSetting(
          kVaultSettingRemovedElsewhere,
          Uint8List.fromList(const [0x01]),
        ),
      );
    } on _Cancelled {
      _status.value = DeviceKeysStatus.idle;
      return;
    } catch (_, stack) {
      _report('removedElsewhereWrite', stack);
    }
    if (!live()) {
      _status.value = DeviceKeysStatus.idle;
      return;
    }
    _setRemoved(vault);
    _forceRegister = false;
    _successVault = vault;
    _lastSuccess = _now();
    _status.value = DeviceKeysStatus.removedElsewhere;
  }

  /// A read-only run: one ListMyKeyDevices, counted toward clearing (M5).
  /// No register, no upload, no create. A failed call (offline, refused,
  /// past the deadline) changes nothing; RATE_LIMITED backs off as usual.
  /// Throws only [_Cancelled], [_DeviceUnusable] and what a vault read
  /// throws.
  Future<void> _checkListed(
    SecureVault vault,
    String uid,
    bool Function() live,
  ) async {
    _status.value = DeviceKeysStatus.removedElsewhere;
    final id = DeviceKeysService._decodeId(await vault.deviceId());
    final key = await vault.setting(kVaultSettingDeviceSignatureKey);
    if (id == null || key == null || key.length != 32) {
      throw const _DeviceUnusable();
    }
    final pb.ListMyKeyDevicesResponse list;
    try {
      list = await _deadline(_repo.listMine());
    } on RateLimitedException catch (e) {
      _notBefore = _now().add(e.retryAfter ?? kDeviceKeysRateLimitFallback);
      return;
    } on AppException {
      return;
    }
    if (!live()) throw const _Cancelled();
    final listed = list.devices.any(
      (d) => d.deviceId == id && _sameKey(d.signaturePublicKey, key),
    );
    _successVault = vault;
    _lastSuccess = _now();
    if (!listed) {
      _listedAgain = 0;
      return;
    }
    if (++_listedAgain < kRemovedElsewhereListedAgain) return;
    await _persist(
      vault,
      uid,
      (tx) => tx.putSetting(
        kVaultSettingRemovedElsewhere,
        Uint8List.fromList(const [0x00]),
      ),
    );
    if (!live()) throw const _Cancelled();
    // Nothing was deleted, so nothing is restored: the next ordinary
    // trigger runs the ordinary upkeep.
    _setRemoved(null);
    _successVault = null;
    _lastSuccess = null;
    _status.value = DeviceKeysStatus.idle;
  }

  Future<void> _recreateDevice() async {
    final vault = _session.vault;
    if (_disposed || vault == null) throw StateError('No vault is open.');
    if (!_repo.enabled || !_session.mayStart) {
      throw StateError('Setting a device up needs e2ee_dm on.');
    }
    if (!removedElsewhere) throw StateError('Not removed elsewhere.');
    final uid = vault.uid;
    // A run in flight (a read-only list) ends first; it never throws.
    final running = _run;
    if (running != null) await running;
    await _session.runWrite((v) async {
      if (!identical(v, vault) || _currentUid() != uid) {
        throw StateError('The vault changed.');
      }
      final engine = _engine();
      final id = DeviceKeysService._hex(await engine.randomBytes(16));
      final idBytes = Uint8List.fromList(utf8.encode(id));
      final created = await engine.createDevice(idBytes);
      await v.transaction((tx) async {
        await tx.putDevice(idBytes, created.deviceState);
        await tx.putSetting(
          kVaultSettingDeviceSignatureKey,
          created.signaturePublicKey,
        );
        await tx.putSetting(
          kVaultSettingDeviceLastSeen,
          DeviceKeysService._micros(0),
        );
        await tx.putSetting(
          kVaultSettingLastResortAt,
          DeviceKeysService._micros(0),
        );
        await tx.putSetting(
          kVaultSettingRegisteredOnce,
          Uint8List.fromList(const [0x00]),
        );
        await tx.putSetting(
          kVaultSettingRemovedElsewhere,
          Uint8List.fromList(const [0x00]),
        );
        await tx.putSetting(
          kVaultSettingPendingUpload,
          PendingUpload.empty.encode(),
        );
      });
    });
    _setRemoved(null);
    _forceRegister = false;
    _successVault = null;
    _lastSuccess = null;
    if (identical(_latchedVault, vault)) {
      _latchedVault = null;
      _latchedForLimit = false;
    }
    await _start(force: true);
  }

  static bool _sameKey(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
