import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/mls_pair.dart' show kMaxPairComponent;
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_session.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting: the [DailyRecord] of the current IST day (sealed; the key
/// holds no id).
const String kVaultSettingE2eeDaily = 'messages.e2ee.daily';

/// The devices this device added to and removed from one conversation today
/// (lower-case hex ids), to recognise an undo (M5).
class DailyDevices {
  const DailyDevices({this.added = const {}, this.removed = const {}});

  final Set<String> added;
  final Set<String> removed;
}

/// The per-day counters of the pipeline, for one IST day. Immutable; no
/// `toString` (it holds conversation and device ids).
class DailyRecord {
  const DailyRecord({
    required this.day,
    this.undone = const {},
    this.did = const {},
    this.lostSendUpdate = const {},
    this.emptyClaim = const {},
    this.autoResets = const {},
    this.exhausted = false,
  });

  /// An empty record for [day] (`YYYY-MM-DD`, IST).
  const DailyRecord.empty(this.day)
    : undone = const {},
      did = const {},
      lostSendUpdate = const {},
      emptyClaim = const {},
      autoResets = const {},
      exhausted = false;

  /// The record that stands for a stored value that could not be read: every
  /// counter answers at its cap for [day].
  const DailyRecord.capped(this.day)
    : undone = const {},
      did = const {},
      lostSendUpdate = const {},
      emptyClaim = const {},
      autoResets = const {},
      exhausted = true;

  /// The IST day this record counts.
  final String day;

  /// Per conversation: how many times this device undid a change today (M5).
  final Map<String, int> undone;

  /// Per conversation: the devices added and removed today.
  final Map<String, DailyDevices> did;

  /// Conversations whose lost-send self-update ran today (R7).
  final Set<String> lostSendUpdate;

  /// Device ids (hex) tried today (R3): a claim that came back empty, or,
  /// with the same daily rule (Task 9 audit M1), a claimed package the
  /// checks dropped, or an add the engine could not build or the server
  /// refused. None of them is claimed again before the next IST day.
  final Set<String> emptyClaim;

  /// Per conversation: the automatic resets of today (security read M9,
  /// Task 10's `GroupStarter.repairIfStuck`), counted before the reset's
  /// first claim. Manual resets are not counted.
  final Map<String, int> autoResets;

  /// True when the value stored for this day could not be read: the ledger
  /// then answers as if every counter were at its cap until the next IST day.
  final bool exhausted;

  DailyRecord copyWith({
    Map<String, int>? undone,
    Map<String, DailyDevices>? did,
    Set<String>? lostSendUpdate,
    Set<String>? emptyClaim,
    Map<String, int>? autoResets,
  }) => DailyRecord(
    day: day,
    undone: undone ?? this.undone,
    did: did ?? this.did,
    lostSendUpdate: lostSendUpdate ?? this.lostSendUpdate,
    emptyClaim: emptyClaim ?? this.emptyClaim,
    autoResets: autoResets ?? this.autoResets,
    exhausted: exhausted,
  );

  /// The automatic resets of [conversationId] today (M9): at least
  /// [kAutoResetsPerDay] while the record is [exhausted] (PR 1 carryover:
  /// an unreadable record must not reopen the cap).
  int autoResetsIn(String conversationId) {
    final n = autoResets[conversationId] ?? 0;
    return exhausted && n < kAutoResetsPerDay ? kAutoResetsPerDay : n;
  }

  /// Security read (A3): whether reversing a change to [deviceId] in
  /// [conversationId] undoes a change this device made today: removing a
  /// device it added ([removing] true), or adding back one it removed. TRUE
  /// for every reversal while the record is [exhausted] (its [did] is then
  /// empty, and an empty [did] must not read as "not an undo": that would
  /// skip the undo cap and fail open). Task 9 decides through this method,
  /// never through [did] directly. Synchronous, so a caller holding a record
  /// from [DailyLedger.readLocked] can decide inside its `runWrite` body.
  bool isUndoOfOwnChange(
    String conversationId,
    Uint8List deviceId, {
    required bool removing,
  }) {
    if (exhausted) return true;
    final today = did[conversationId];
    if (today == null) return false;
    final hex = vaultDeviceIdHex(deviceId);
    return removing ? today.added.contains(hex) : today.removed.contains(hex);
  }

  /// How many own changes of today were undone in [conversationId] (M5):
  /// at least [kAntiFlapUndosPerDay] while the record is [exhausted].
  int undoneIn(String conversationId) {
    final n = undone[conversationId] ?? 0;
    return exhausted && n < kAntiFlapUndosPerDay ? kAntiFlapUndosPerDay : n;
  }

  /// M5: whether a commit by ANOTHER device that added [added] and removed
  /// [removed] in [conversationId] undoes a change this device made today,
  /// decided per device through [isUndoOfOwnChange] (so every reversal is an
  /// undo while the record is [exhausted]). A commit that adds and removes
  /// nothing undoes nothing.
  bool undoesOwnChange(
    String conversationId, {
    required List<Uint8List> added,
    required List<Uint8List> removed,
  }) =>
      removed.any(
        (d) => isUndoOfOwnChange(conversationId, d, removing: true),
      ) ||
      added.any((d) => isUndoOfOwnChange(conversationId, d, removing: false));

  /// This record with the own change of [conversationId] noted: this device
  /// added [added] and removed [removed] today. The LAST own change of a
  /// device is the one a reversal is measured against: an id added is taken
  /// out of the removed set, and the other way round.
  DailyRecord withOwnChange(
    String conversationId, {
    List<Uint8List> added = const [],
    List<Uint8List> removed = const [],
  }) {
    if (added.isEmpty && removed.isEmpty) return this;
    final today = did[conversationId] ?? const DailyDevices();
    final addedHex = {for (final d in added) vaultDeviceIdHex(d)};
    final removedHex = {for (final d in removed) vaultDeviceIdHex(d)};
    return copyWith(
      did: {
        ...did,
        conversationId: DailyDevices(
          added: {...today.added.difference(removedHex), ...addedHex},
          removed: {...today.removed.difference(addedHex), ...removedHex},
        ),
      },
    );
  }

  /// This record after a commit by ANOTHER device that added [added] and
  /// removed [removed] in [conversationId]: when it [undoesOwnChange], the
  /// undo count is one higher and the own changes it reversed are used up
  /// (the same reversal seen again is no second undo; a second undo needs
  /// this device to have made the change again). Otherwise this record.
  DailyRecord withUndoCounted(
    String conversationId, {
    required List<Uint8List> added,
    required List<Uint8List> removed,
  }) {
    if (!undoesOwnChange(conversationId, added: added, removed: removed)) {
      return this;
    }
    final today = did[conversationId];
    return copyWith(
      undone: {...undone, conversationId: (undone[conversationId] ?? 0) + 1},
      did: today == null
          ? null
          : {
              ...did,
              conversationId: DailyDevices(
                added: today.added.difference({
                  for (final d in removed) vaultDeviceIdHex(d),
                }),
                removed: today.removed.difference({
                  for (final d in added) vaultDeviceIdHex(d),
                }),
              ),
            },
    );
  }

  /// The sealed JSON. [ArgumentError] for a counter outside
  /// 0..[kMaxPairComponent] (what [decode] accepts).
  Uint8List encode() {
    for (final n in [...undone.values, ...autoResets.values]) {
      if (n < 0 || n > kMaxPairComponent) {
        throw ArgumentError('A daily counter is out of range.');
      }
    }
    return _encode();
  }

  Uint8List _encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'day': day,
        if (exhausted) 'exhausted': true,
        'undone': undone,
        'did': {
          for (final e in did.entries)
            e.key: {
              'added': e.value.added.toList(),
              'removed': e.value.removed.toList(),
            },
        },
        'lostSendUpdate': lostSendUpdate.toList(),
        'emptyClaim': emptyClaim.toList(),
        if (autoResets.isNotEmpty) 'autoResets': autoResets,
      }),
    ),
  );

  /// [VaultCorruptException] for a value that is not valid JSON, has another
  /// `v`, or is malformed (a `day` that is not a real `YYYY-MM-DD` date
  /// included).
  static DailyRecord decode(Uint8List bytes) {
    try {
      final m = _map(jsonDecode(utf8.decode(bytes)));
      if (m['v'] != 1) throw const FormatException('version');
      return DailyRecord(
        day: _day(m['day']),
        undone: {
          for (final e in _map(m['undone']).entries) e.key: _int(e.value),
        },
        did: {
          for (final e in _map(m['did']).entries)
            e.key: DailyDevices(
              added: _strings(_map(e.value)['added']),
              removed: _strings(_map(e.value)['removed']),
            ),
        },
        lostSendUpdate: _strings(m['lostSendUpdate']),
        emptyClaim: _strings(m['emptyClaim']),
        // Absent in a record written before Task 10: none today.
        autoResets: m['autoResets'] == null
            ? const {}
            : {
                for (final e in _map(m['autoResets']).entries)
                  e.key: _int(e.value),
              },
        exhausted: m['exhausted'] == null ? false : _bool(m['exhausted']),
      );
    } catch (_) {
      throw const VaultCorruptException('vault_settings');
    }
  }

  static Map<String, Object?> _map(Object? v) {
    if (v is Map<String, Object?>) return v;
    throw const FormatException('object');
  }

  static String _string(Object? v) {
    if (v is String) return v;
    throw const FormatException('string');
  }

  static final RegExp _dayShape = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  /// A `YYYY-MM-DD` string naming a real calendar day (as [istDay] writes).
  static String _day(Object? v) {
    final s = _string(v);
    final m = _dayShape.firstMatch(s);
    if (m == null) throw const FormatException('day');
    final y = int.parse(m[1]!);
    final mo = int.parse(m[2]!);
    final d = int.parse(m[3]!);
    final date = DateTime.utc(y, mo, d);
    if (mo < 1 || date.year != y || date.month != mo || date.day != d) {
      throw const FormatException('day');
    }
    return s;
  }

  static bool _bool(Object? v) {
    if (v is bool) return v;
    throw const FormatException('bool');
  }

  static int _int(Object? v) {
    if (v is int && v >= 0 && v <= kMaxPairComponent) return v;
    throw const FormatException('int');
  }

  static Set<String> _strings(Object? v) {
    if (v is! List<Object?>) throw const FormatException('list');
    return {for (final s in v) _string(s)};
  }
}

/// Undos of this device's own changes allowed a day in one conversation (M5).
const int kAntiFlapUndosPerDay = 2;

/// Security read M9 (owner-approved): automatic resets allowed a day in one
/// conversation. Every `stuck` cause can be produced by a server answer
/// alone, so the server's own caps are no bound on them; at the limit the
/// conversation stays `stuck` with the manual offer.
const int kAutoResetsPerDay = 2;

/// The counters that limit what this device does in one IST day (R3, R7, M5),
/// kept in one sealed vault setting. Everything goes through
/// `session.runWrite` and one vault transaction.
///
/// **Fails closed.** These counters bound automatic resets, undos, lost-send
/// self-updates and empty-claim retries. A stored value that cannot be read
/// (corrupt, or another `v`) must not reopen them: for the rest of that IST
/// day every counter answers at its cap ([kAntiFlapUndosPerDay] undos, the
/// lost-send update and every empty claim done), the failure is reported once
/// as `E2eePipelineError('daily.read')`, and a record carrying the
/// [DailyRecord.exhausted] marker is stored so the answer survives a restart.
/// The next IST day starts an empty record. A stored record dated at most one
/// day AFTER today (clock skew, the IST boundary) is kept and its counters
/// apply; one dated further ahead is replaced by a capped record for today
/// (fails closed, bounded to one day); an older one is replaced by an empty
/// one. A `day` that is not a `YYYY-MM-DD` date is an unreadable value.
///
/// Never call a method here other than [readLocked] and [writeIn] from inside
/// a `runWrite` body (the mutex is not re-entrant): read before the body
/// ([read]) or inside it ([readLocked]), and write atomically with a commit's
/// result through [writeIn], which re-reads the record inside the caller's
/// transaction.
class DailyLedger {
  DailyLedger({
    required VaultSession session,
    required DateTime Function() now,
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _session = session,
       _now = now,
       _onUnexpectedError = onUnexpectedError;

  final VaultSession _session;
  final DateTime Function() _now;
  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  bool _reportedUnreadable = false;

  Future<int> undone(String conversationId) async =>
      (await read()).undoneIn(conversationId);

  // M5: this device's own change is recorded only by its commit's own
  // transaction, through [writeIn] with [DailyRecord.withOwnChange] (review
  // m-5: no separate entry outside a commit, which a later caller could
  // pick instead and leave the record apart from the commit).

  Future<void> addUndone(String conversationId) => _update(
    (r) => r.copyWith(
      undone: {
        ...r.undone,
        conversationId: (r.undone[conversationId] ?? 0) + 1,
      },
    ),
  );

  /// M9: the automatic resets of [conversationId] today (at least
  /// [kAutoResetsPerDay] while the record is exhausted).
  Future<int> autoResets(String conversationId) async =>
      (await read()).autoResetsIn(conversationId);

  /// M9: one more automatic reset of [conversationId] today. Written BEFORE
  /// the reset's first claim (Task 10), so a crash or a failed reset never
  /// undercounts.
  Future<void> addAutoReset(String conversationId) => _update(
    (r) => r.copyWith(
      autoResets: {
        ...r.autoResets,
        conversationId: (r.autoResets[conversationId] ?? 0) + 1,
      },
    ),
  );

  Future<bool> lostSendUpdateDone(String conversationId) async {
    final r = await read();
    return r.exhausted || r.lostSendUpdate.contains(conversationId);
  }

  Future<void> markLostSendUpdate(String conversationId) => _update(
    (r) => r.copyWith(lostSendUpdate: {...r.lostSendUpdate, conversationId}),
  );

  Future<bool> emptyClaimTried(Uint8List deviceId) async {
    final r = await read();
    return r.exhausted || r.emptyClaim.contains(vaultDeviceIdHex(deviceId));
  }

  Future<void> markEmptyClaim(Uint8List deviceId) => _update(
    (r) =>
        r.copyWith(emptyClaim: {...r.emptyClaim, vaultDeviceIdHex(deviceId)}),
  );

  /// The record of today: an empty one when none is stored or the stored one
  /// is of an earlier IST day; the stored one when it is dated today or at
  /// most one day after (clock skew, the IST boundary); a capped record for
  /// today (stored) when it is dated further ahead; a record with
  /// [DailyRecord.exhausted] set (and stored) when the value cannot be read
  /// (reported once). Throws [StateError] when the vault is not ready. Not for
  /// a `runWrite` body ([readLocked] is).
  ///
  /// Decide through the accessors ([undone], [lostSendUpdateDone],
  /// [emptyClaimTried], [DailyRecord.isUndoOfOwnChange]), which apply
  /// [DailyRecord.exhausted], never through the raw fields: an exhausted
  /// record has empty counters that answer "at its cap".
  Future<DailyRecord> read() => _session.runWrite((vault) async {
    _checkVault(vault);
    return _load(vault);
  });

  /// [read] for a caller already inside a `runWrite` body (the caller checked
  /// that [vault] is the session's). Opens no `runWrite` and no transaction:
  /// a replacement record (unreadable value, far-future day) is stored only
  /// through [tx] when one is given, otherwise it is just returned (the next
  /// write stores it). Safe inside or outside the caller's transaction.
  Future<DailyRecord> readLocked(SecureVault vault, {VaultTx? tx}) =>
      _load(vault, tx: tx, persist: tx != null);

  /// For a caller already inside a `runWrite` body and transaction: reads the
  /// record FRESH inside that transaction and applies [change] to it through
  /// [tx]. The record is shared by every conversation while only
  /// per-conversation locks are held, so another conversation's write may
  /// have landed since the caller read: [current] (the record the caller read
  /// before the body, [read] or [readLocked]) is for the caller's decision
  /// only and is NOT what gets written. A record of an earlier day is
  /// replaced by an empty one, an unreadable one by a capped one (stored
  /// through [tx]); a stale copy never clears [DailyRecord.exhausted]. Decide
  /// through the accessors, never the raw fields (see [read]).
  ///
  /// [change] must build its result from its parameter ONLY (never from a
  /// record captured earlier, [current] included) and should use
  /// [DailyRecord.copyWith]. Whatever it returns, the exhausted marker of
  /// the fresh record is kept: a result without it is written with it.
  Future<void> writeIn(
    VaultTx tx,
    DailyRecord current,
    DailyRecord Function(DailyRecord) change,
  ) async {
    final vault = _session.vault;
    if (vault == null) throw StateError('The vault is not ready.');
    final fresh = await _load(vault, tx: tx);
    await tx.putSetting(
      kVaultSettingE2eeDaily,
      _applied(fresh, change).encode(),
    );
  }

  /// [change] applied to [fresh], with [DailyRecord.exhausted] enforced in
  /// code: a result that dropped the marker of an exhausted record (a newly
  /// built record) gets it back, on [fresh]'s day, so every counter keeps
  /// reading at its cap.
  DailyRecord _applied(
    DailyRecord fresh,
    DailyRecord Function(DailyRecord) change,
  ) {
    final result = change(fresh);
    if (!fresh.exhausted || (result.exhausted && result.day == fresh.day)) {
      return result;
    }
    return DailyRecord(
      day: fresh.day,
      undone: result.undone,
      did: result.did,
      lostSendUpdate: result.lostSendUpdate,
      emptyClaim: result.emptyClaim,
      autoResets: result.autoResets,
      exhausted: true,
    );
  }

  /// [DailyRecord.isUndoOfOwnChange] on today's record (true for every
  /// reversal while the ledger is exhausted). Not for a `runWrite` body: there,
  /// call it on the record [readLocked] returned.
  Future<bool> isUndoOfOwnChange(
    String conversationId,
    Uint8List deviceId, {
    required bool removing,
  }) async => (await read()).isUndoOfOwnChange(
    conversationId,
    deviceId,
    removing: removing,
  );

  Future<void> _update(DailyRecord Function(DailyRecord) change) =>
      _session.runWrite((vault) async {
        _checkVault(vault);
        final current = await _load(vault);
        await vault.transaction(
          (tx) => tx.putSetting(
            kVaultSettingE2eeDaily,
            _applied(current, change).encode(),
          ),
        );
      });

  void _checkVault(SecureVault vault) {
    if (!identical(_session.vault, vault)) {
      throw StateError('The vault is not ready.');
    }
  }

  /// Reads the stored record. A replacement (capped) record is stored through
  /// [tx] when given (the caller's transaction; never a nested one), else in a
  /// transaction of its own; with [persist] false it is only returned.
  Future<DailyRecord> _load(
    SecureVault vault, {
    VaultTx? tx,
    bool persist = true,
  }) async {
    final now = _now();
    final today = istDay(now);
    DailyRecord? stored;
    try {
      final bytes = await vault.setting(kVaultSettingE2eeDaily);
      if (bytes != null) stored = DailyRecord.decode(bytes);
    } on VaultCorruptException catch (_, stack) {
      if (!_reportedUnreadable) {
        _reportedUnreadable = true;
        _onUnexpectedError?.call(const E2eePipelineError('daily.read'), stack);
      }
      // Fail closed, and keep it so for the rest of the day (and a restart).
      return _capped(vault, today, tx: tx, persist: persist);
    }
    // 'YYYY-MM-DD' strings order like the days they name.
    if (stored == null || stored.day.compareTo(today) < 0) {
      return DailyRecord.empty(today);
    }
    if (stored.day.compareTo(istDay(now.add(const Duration(days: 1)))) > 0) {
      // Dated more than one day ahead (a clock once set far forward): kept as
      // it is, it would freeze recovery until that day. Still fails closed,
      // but only for today.
      return _capped(vault, today, tx: tx, persist: persist);
    }
    return stored;
  }

  Future<DailyRecord> _capped(
    SecureVault vault,
    String today, {
    required VaultTx? tx,
    required bool persist,
  }) async {
    final capped = DailyRecord.capped(today);
    if (!persist) return capped;
    if (tx != null) {
      await tx.putSetting(kVaultSettingE2eeDaily, capped.encode());
    } else {
      await vault.transaction(
        (t) => t.putSetting(kVaultSettingE2eeDaily, capped.encode()),
      );
    }
    return capped;
  }
}
