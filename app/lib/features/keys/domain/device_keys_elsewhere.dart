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
/// The removed-elsewhere fact for the open vault (fix wave 3, SA M3).
/// `unknown`: the vault's marker has not been read yet, or did not open,
/// or holds another value (the pipeline stays stopped); `removed`: the
/// server answered DEVICE_REMOVED (stored, or remembered when the write
/// failed); `notRemoved`: the marker was read and says so. Only
/// `notRemoved` lets the pipeline run ([DeviceKeysService.stopsPipeline]).
enum RemovedElsewhere { unknown, removed, notRemoved }

/// What the stored marker holds: absent or 0x00, 0x01, anything else.
enum _Marker { clear, set, malformed }

final Expando<bool> _markerReported = Expando('markerReported');

extension _Elsewhere on DeviceKeysService {
  void _setRemoved(SecureVault vault) {
    _removedVault = vault;
    _clearVault = null;
    _listedAgain = 0;
    _removedFact.value = true;
  }

  /// The marker was read and says "not removed" (or the listed-again path
  /// or recreateDevice cleared it).
  void _setClear(SecureVault vault) {
    _removedVault = null;
    _clearVault = vault;
    _listedAgain = 0;
    _removedFact.value = false;
  }

  /// Throws [VaultCorruptException] when the marker does not open.
  static Future<_Marker> _readMarker(SecureVault vault) async {
    final bytes = await vault.setting(kVaultSettingRemovedElsewhere);
    if (bytes == null) return _Marker.clear;
    if (bytes.length == 1 && bytes[0] == 0x00) return _Marker.clear;
    if (bytes.length == 1 && bytes[0] == 0x01) return _Marker.set;
    return _Marker.malformed;
  }

  /// An unreadable or malformed marker, reported once per vault.
  void _reportMarker(SecureVault vault, StackTrace stack) {
    if (_markerReported[vault] == true) return;
    _markerReported[vault] = true;
    _report('removedElsewhereMarker', stack);
  }

  /// At vault ready: the memory follows the stored marker of a vault this
  /// service has not decided yet. Until this read succeeds the fact is
  /// `unknown`, which stops the pipeline (fix wave 3, SA M3; it replaces
  /// review N2's "reads as false"): a marker that does not open, or holds
  /// another value, keeps it `unknown` (reported once), and the run fails
  /// closed on it.
  Future<void> _loadRemoved(SecureVault vault) async {
    if (_decided(vault)) return;
    _Marker? marker;
    try {
      marker = await _readMarker(vault);
    } on Object catch (_, stack) {
      _reportMarker(vault, stack);
    }
    if (_disposed || !identical(_session.vault, vault)) return;
    // A run decided it meanwhile: that decision stands.
    if (_decided(vault)) return;
    switch (marker) {
      case _Marker.set:
        _setRemoved(vault);
      case _Marker.clear:
        _setClear(vault);
      case _Marker.malformed:
        _reportMarker(vault, StackTrace.current);
        _removedFact.value = false;
      case null:
        _removedFact.value = false;
    }
  }

  bool _decided(SecureVault vault) =>
      identical(_removedVault, vault) || identical(_clearVault, vault);

  /// In a run: whether this device is removed elsewhere. A stored 0x01
  /// sets the memory. A stored "not removed" never clears a memory that
  /// says removed (fix wave 3, SA M3: the marker write failed); the marker
  /// is written again then. A malformed marker throws
  /// [VaultCorruptException] (the run fails closed; the fact stays
  /// `unknown`).
  Future<bool> _syncRemoved(SecureVault vault, String uid) async {
    final marker = await _readMarker(vault);
    if (marker == _Marker.malformed) {
      _reportMarker(vault, StackTrace.current);
      throw const VaultCorruptException('vault_settings');
    }
    if (marker == _Marker.set) {
      if (!identical(_removedVault, vault)) _setRemoved(vault);
      return true;
    }
    if (identical(_removedVault, vault)) {
      // Final round 2 (CR Minor D / SA L7): while "set up again" holds its
      // latch the clear marker is recreateDevice's own 0x00; never write
      // 0x01 over the new device's.
      if (identical(_settingUpVault, vault)) return true;
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
        rethrow;
      } catch (_, stack) {
        _report('removedElsewhereWrite', stack);
      }
      return true;
    }
    _setClear(vault);
    return false;
  }

  /// The FIRST DEVICE_REMOVED answer: the marker 0x01, the phase, and the
  /// hour's throttle (a run within the hour sends nothing). Memory follows
  /// even when the write fails (reported), and no later read clears it:
  /// the next run writes the marker again ([_syncRemoved]).
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
    // Fix wave 6 (CR Minor C): "set up again" is running; its cleared
    // vault needs the new id, so the clear waits (the count stays).
    if (identical(_settingUpVault, vault)) return;
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
    _setClear(vault);
    _successVault = null;
    _lastSuccess = null;
    _status.value = DeviceKeysStatus.idle;
  }

  bool _beginSetUpAgain() {
    final vault = _session.vault;
    if (_disposed || vault == null) return false;
    if (!removedElsewhere && !identical(_settingUpVault, vault)) return false;
    _settingUpVault = vault;
    return true;
  }

  Future<void> _recreateDevice() async {
    final vault = _session.vault;
    if (_disposed || vault == null) throw StateError('No vault is open.');
    if (!_repo.enabled || !_session.mayStart) {
      throw StateError('Setting a device up needs e2ee_dm on.');
    }
    if (!removedElsewhere && !identical(_settingUpVault, vault)) {
      throw StateError('Not removed elsewhere.');
    }
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
      // Final round 2 (CR Minor D / SA L7): the memory follows the commit
      // in this body, with no await between, so no marker read sees 0x00
      // while the memory still says removed. The latch goes with it.
      _setClear(vault);
      if (identical(_settingUpVault, vault)) _settingUpVault = null;
    });
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
