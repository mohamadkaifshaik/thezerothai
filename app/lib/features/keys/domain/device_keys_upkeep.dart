part of 'device_keys_service.dart';

/// One upkeep run's steps ([DeviceKeysService._runOnce] calls it): this
/// device created or loaded, registered when it must be, and its pool topped
/// up. Moved out of the library file to keep it under the size limit (Task
/// 12; a move, with the class's static helpers named by their class).
/// A ListMyKeyDevices answer that is a failed call of the run, not a
/// statement about this device (DEVICE_REMOVED there, fix wave 7).
class _ListFailed implements Exception {
  const _ListFailed();
}

extension _Upkeep on DeviceKeysService {
  Future<void> _upkeep(
    SecureVault vault,
    String uid,
    bool Function() live,
    int epoch,
  ) async {
    void check() {
      if (!live() || _removing || _removalEpoch != epoch) {
        throw const _Cancelled();
      }
    }

    // 1. This device, created (id, state and public key in one
    // transaction) when the vault has none.
    final local = await _session.runWrite((v) async {
      if (!identical(v, vault) || _currentUid() != uid) {
        throw const _Cancelled();
      }
      return _loadOrCreate(v);
    });
    final nowMicros = _now().microsecondsSinceEpoch;

    // 2. Registered? A new device registers at once; a known one is looked
    // up (missing: never registered, removed by a failed sign-out's hook).
    var mustRegister =
        local.created ||
        _forceRegister ||
        DeviceKeysService._olderThan(
          local.lastSeenMicros,
          nowMicros,
          kDeviceStayActiveAfter,
        );
    var count = 0;
    var hasLastResort = false;
    if (!local.created) {
      check();
      final pb.ListMyKeyDevicesResponse list;
      try {
        list = await _deadline(_repo.listMine());
      } on DeviceRemovedException {
        // Fix wave 7 (SA L1): only a Register or Upload answer marks this
        // device; on the list it is an ordinary failed call.
        throw const _ListFailed();
      }
      check();
      pb.KeyDevice? mine;
      for (final d in list.devices) {
        if (d.deviceId == local.id) mine = d;
      }
      if (mine == null) {
        mustRegister = true;
      } else {
        count = _poolCount(mine.keyPackageCount);
        hasLastResort = mine.hasLastResort;
      }
    }
    if (mustRegister) {
      check(); // never publish once a removal started
      final r = await _publish(
        local.id,
        epoch,
        () => _repo.registerDevice(
          deviceId: local.id,
          signaturePublicKey: local.signatureKey,
          idempotencyKey: _newKey(),
        ),
      );
      check();
      _forceRegister = false;
      count = _poolCount(r.device.keyPackageCount);
      hasLastResort = r.device.hasLastResort;
      await _persistRegistered(vault, uid, nowMicros);
    }

    // 3. The pool.
    final oneTime = count < kKeyPackageTopUpBelow
        ? kKeyPackagePoolTarget - count
        : 0;
    final lastResort =
        !hasLastResort ||
        DeviceKeysService._olderThan(
          local.lastResortMicros,
          nowMicros,
          kLastResortMaxAge,
        );
    check();
    final (batch, previousUnknown, cap) = await _takeOrGenerateBatch(
      vault,
      uid,
      count: count,
      oneTime: oneTime,
      lastResort: lastResort,
      hasLastResort: hasLastResort,
    );
    if (batch.isEmpty) return;
    check();
    final key = _newKey();
    Future<pb.UploadKeyPackagesResponse> upload() => _publish(
      local.id,
      epoch,
      () => _repo.uploadKeyPackages(
        deviceId: local.id,
        keyPackages: batch.oneTime,
        lastResortKeyPackage: batch.lastResort,
        idempotencyKey: key,
      ),
    );
    try {
      await upload();
    } on AppException catch (e) {
      // A typed refusal is rethrown BEFORE check(): a removal that started
      // mid-upload must not turn it into a cancel and lose the back-off
      // (RATE_LIMITED), the forced register or the latch. The "failed"
      // record is written only while no removal is under way.
      if (!DeviceKeysService._unknownOutcome(e)) {
        if (!previousUnknown && !_removing && _removalEpoch == epoch) {
          final refused = PendingUpload(
            batch.oneTime,
            batch.lastResort,
            batch.countBefore,
            failed: true,
            lastResortMicros: batch.lastResortMicros,
          );
          // Best effort: the typed refusal (back-off, forced register,
          // latch) must survive a failed write; the saved record then stays
          // "unknown", which only makes the next run read the count first.
          try {
            await _persist(
              vault,
              uid,
              (tx) =>
                  tx.putSetting(kVaultSettingPendingUpload, refused.encode()),
            );
          } on _Cancelled {
            // The vault or the user changed: the run is over, not a failed
            // write.
            rethrow;
          } catch (_, stack) {
            _report('pendingUploadWrite', stack);
          }
        }
        rethrow;
      }
      check();
      // A refusal on this retry cannot resolve the first attempt.
      await upload();
    }
    check();
    await _persist(vault, uid, (tx) async {
      await tx.putSetting(
        kVaultSettingPendingUpload,
        PendingUpload.empty.encode(),
      );
      await tx.putSetting(
        kVaultSettingDeviceLastSeen,
        DeviceKeysService._micros(nowMicros),
      );
      if (batch.lastResort != null) {
        // When it was generated, not now: a resend must not extend the
        // package's 30 days (SA L2).
        await tx.putSetting(
          kVaultSettingLastResortAt,
          DeviceKeysService._micros(batch.lastResortMicros),
        );
      }
    });
    // A last-resort-only batch sent at the cap: the pool is still capped.
    if (cap != null) throw cap;
  }

  Future<_Local> _loadOrCreate(SecureVault v) async {
    final idBytes = await v.deviceId();
    if (idBytes != null) {
      final id = DeviceKeysService._decodeId(idBytes);
      final state = await v.deviceState();
      final key = await v.setting(kVaultSettingDeviceSignatureKey);
      if (id != null && state != null && key != null && key.length == 32) {
        return _Local(
          id: id,
          signatureKey: key,
          created: false,
          lastSeenMicros: await DeviceKeysService._readMicros(
            v,
            kVaultSettingDeviceLastSeen,
          ),
          lastResortMicros: await DeviceKeysService._readMicros(
            v,
            kVaultSettingLastResortAt,
          ),
        );
      }
      // Cannot happen (written in one transaction). Fail closed: never
      // overwrite or rotate an existing device here.
      throw const _DeviceUnusable();
    }
    final engine = _engine();
    final random = await engine.randomBytes(16);
    final id = DeviceKeysService._hex(random);
    final idBytesNew = Uint8List.fromList(utf8.encode(id));
    final created = await engine.createDevice(idBytesNew);
    await v.transaction((tx) async {
      await tx.putDevice(idBytesNew, created.deviceState);
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
    });
    return _Local(
      id: id,
      signatureKey: created.signaturePublicKey,
      created: true,
      lastSeenMicros: 0,
      lastResortMicros: 0,
    );
  }
}
