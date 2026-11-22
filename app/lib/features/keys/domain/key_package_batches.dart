part of 'device_keys_service.dart';

/// Sealed JSON
/// `{"v":1,"day":"YYYY-MM-DD","n":k,"reportedCap":bool,"reportedInvalid":bool}`:
/// the batches generated on that IST day and whether the cap (`batchCap`)
/// and an invalid counter (`batchDay`) were reported that day.
const String kVaultSettingKeyBatchDay = 'keys.device.batchDay';

/// The server reported a pool count outside [0, [kMaxKeyPackagePool]].
class _BadPoolCount implements Exception {
  const _BadPoolCount();
}

/// [kMaxKeyBatchesPerDay] batches were generated today: nothing more is
/// generated (reported once per IST day where the cap is found).
class _BatchCap implements Exception {
  const _BatchCap();
}

/// A reported pool count, refused outside [0, [kMaxKeyPackagePool]]: a
/// negative one would make every saved record unreadable (a fresh batch
/// each run), an oversize one is not a server we can trust.
int _poolCount(int count) {
  if (count < 0 || count > kMaxKeyPackagePool) throw const _BadPoolCount();
  return count;
}

/// Step 3's vault part (the saved batch, generation and the daily cap),
/// split from the service for size; same library, same behaviour.
extension _KeyPackageBatches on DeviceKeysService {
  /// Step 3's vault part: the saved batch when one may be sent again, or a
  /// fresh one (private parts and public packages in one transaction).
  /// Returns the batch to upload (empty: nothing), whether the saved
  /// batch's last outcome was unknown, and the cap to throw once the batch
  /// is sent (a last-resort-only batch generated at the cap, or a saved
  /// batch sent without the last-resort package the bound held back; else
  /// null).
  Future<(PendingUpload, bool, _BatchCap?)> _takeOrGenerateBatch(
    SecureVault vault,
    String uid, {
    required int count,
    required int oneTime,
    required bool lastResort,
    required bool hasLastResort,
  }) => _session.runWrite((v) async {
    if (!identical(v, vault) || _currentUid() != uid) {
      throw const _Cancelled();
    }
    final now = _now();
    final today = istDay(now);
    final tomorrow = istDay(now.add(const Duration(days: 1)));
    var saved = PendingUpload.empty;
    var unreadable = false;
    try {
      final bytes = await v.setting(kVaultSettingPendingUpload);
      if (bytes != null) {
        saved = PendingUpload.decode(
          bytes,
          nowMicros: now.microsecondsSinceEpoch,
        );
      }
    } on FormatException {
      unreadable = true;
    } on VaultCorruptException {
      unreadable = true;
    }
    if (unreadable && _reportedPending[v] != true) {
      _reportedPending[v] = true;
      _report('pendingUpload', StackTrace.current);
    }
    Future<void> store(PendingUpload pending) => v.transaction(
      (tx) => tx.putSetting(kVaultSettingPendingUpload, pending.encode()),
    );

    // The daily cap (ruling E), read again and written in the transaction
    // that commits each generation.
    Future<KeyBatchDay> batchDay() async {
      final Uint8List? bytes;
      try {
        bytes = await v.setting(kVaultSettingKeyBatchDay);
      } on VaultCorruptException {
        return KeyBatchDay.capped(today, kMaxKeyBatchesPerDay);
      }
      return KeyBatchDay.read(
        bytes,
        today: today,
        tomorrow: tomorrow,
        cap: kMaxKeyBatchesPerDay,
      );
    }

    // Marks [batches] as reported and reports it, once per IST day for each
    // kind: an invalid counter (`batchDay`) and a real cap (`batchCap`) have
    // their own flags, so both can show on the same day.
    Future<void> reportCap(KeyBatchDay batches) async {
      final invalid = batches.invalid;
      if (invalid ? batches.reportedInvalid : batches.reportedCap) return;
      final marked = KeyBatchDay(
        today,
        batches.count,
        reportedCap: batches.reportedCap || !invalid,
        reportedInvalid: batches.reportedInvalid || invalid,
      );
      await v.transaction(
        (tx) => tx.putSetting(kVaultSettingKeyBatchDay, marked.encode()),
      );
      _report(invalid ? 'batchDay' : 'batchCap', StackTrace.current);
    }

    // Ruling 1 (fix 3): a last-resort-only generation past the cap is
    // allowed only while the counter is below this; the runs that trigger
    // them are not throttled.
    const lastResortBound = kMaxKeyBatchesPerDay + kMaxLastResortOnlyPerDay;

    /// Generates [oneTimeCount] one-time packages (and a last-resort one
    /// when [withLastResort]) and commits the private state, the record
    /// ([keep] first, then the new one-time packages) and the counter in ONE
    /// transaction. Counted whatever the cap (the caller checks it).
    Future<PendingUpload> generate(
      int oneTimeCount, {
      required bool withLastResort,
      List<Uint8List> keep = const [],
    }) async {
      final state = await v.deviceState();
      if (state == null) throw StateError('No device state.');
      final r = await _engine().generateKeyPackages(
        state,
        count: oneTimeCount,
        lastResort: withLastResort,
      );
      final packages = r.keyPackages;
      final pending = PendingUpload(
        [
          ...keep,
          ...(withLastResort
              ? packages.sublist(0, packages.length - 1)
              : packages),
        ],
        withLastResort ? packages.last : null,
        count,
        lastResortMicros: withLastResort ? now.microsecondsSinceEpoch : 0,
      );
      await v.transaction((tx) async {
        final current = await batchDay();
        final counted = KeyBatchDay(
          today,
          current.count + 1,
          reportedCap: current.reportedCap,
          reportedInvalid: current.reportedInvalid,
        );
        await tx.putDeviceState(r.deviceState);
        await tx.putSetting(kVaultSettingPendingUpload, pending.encode());
        await tx.putSetting(kVaultSettingKeyBatchDay, counted.encode());
      });
      return pending;
    }

    if (!saved.isEmpty) {
      final previousUnknown = !saved.failed;
      // Decision (Task 14, ruling B): ANY change clears, not only a grown
      // count (the plan's `>`). A higher count means the batch landed; a
      // lower one can mean it landed and was then drained by claims, so a
      // re-upload could publish packages peers already consumed. Clearing
      // is the safe side. Cost: a batch that never landed is dropped after
      // any claim, and its private parts stay in the device state (the core
      // prune, Open question 9).
      if (previousUnknown && count != saved.countBefore) {
        // Ruling C: the last-resort package is replaced whole and never
        // consumed, so it alone is sent again (armed as a new attempt
        // before dispatch). No fresh batch in this run: generating on every
        // count change would double the growth a hostile server can cause.
        final last = saved.lastResort;
        if (last == null && !hasLastResort) {
          // N-3: nothing to resend and the server has no last-resort
          // package: a fresh one alone (counted, allowed past the cap up to
          // [lastResortBound]; past that, the cap).
          final batches = await batchDay();
          if (batches.count >= lastResortBound) {
            await reportCap(batches);
            throw const _BatchCap();
          }
          final fresh = await generate(0, withLastResort: true);
          return (fresh, false, null);
        }
        final lastOnly = last == null
            ? PendingUpload.empty
            : PendingUpload(
                const [],
                last,
                count,
                lastResortMicros: saved.lastResortMicros,
              );
        await store(lastOnly);
        return (lastOnly, false, null);
      }
      _BatchCap? cap;
      if (saved.lastResort == null && !hasLastResort) {
        // N-3: the saved one-time packages go again with a fresh last-resort
        // package (counted, allowed past the cap up to [lastResortBound]),
        // armed as a new attempt.
        final batches = await batchDay();
        if (batches.count < lastResortBound) {
          final withLast = await generate(
            0,
            withLastResort: true,
            keep: saved.oneTime,
          );
          return (withLast, previousUnknown, null);
        }
        // Past the bound: no fresh one. Decision: the saved one-time
        // packages (already generated) are still sent as they are, and the
        // cap is thrown after the upload, so the cap does not hold back a
        // batch that costs no new state.
        await reportCap(batches);
        cap = const _BatchCap();
      }
      if (previousUnknown) return (saved, previousUnknown, cap);
      // Arm the next attempt before dispatch so a killed run is unknown.
      final retry = PendingUpload(
        saved.oneTime,
        saved.lastResort,
        count,
        lastResortMicros: saved.lastResortMicros,
      );
      await store(retry);
      return (retry, previousUnknown, cap);
    }
    if (oneTime <= 0 && !lastResort) {
      if (unreadable) await store(PendingUpload.empty);
      return (PendingUpload.empty, false, null);
    }
    final batches = await batchDay();
    var generateOneTime = oneTime;
    var generateLastResort = lastResort;
    _BatchCap? cap;
    if (batches.count >= kMaxKeyBatchesPerDay) {
      // The cap holds something back (one-time packages, or a last-resort
      // rotation the server does not need), or the counter is invalid:
      // marked and reported once a day. `batchDay` (a counter that did not
      // open, decode, or is dated more than a day ahead) is kept apart from
      // `batchCap` (a real cap) so local corruption shows as such. Past
      // [lastResortBound] even a missing last-resort package is held back.
      final spent = batches.count >= lastResortBound;
      final blocks = hasLastResort || oneTime > 0 || spent;
      if (blocks || batches.invalid) await reportCap(batches);
      if (blocks) {
        cap = const _BatchCap();
        if (hasLastResort || spent) throw cap;
      }
      // Ruling 1: the server holds no last-resort package. Without one the
      // device is unreachable once the pool is empty, so a last-resort-only
      // batch is generated and counted past the cap, below
      // [lastResortBound].
      generateOneTime = 0;
      generateLastResort = true;
    }
    final pending = await generate(
      generateOneTime,
      withLastResort: generateLastResort,
    );
    return (pending, false, cap);
  });
}
