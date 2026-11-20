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
  });

  /// An empty record for [day] (`YYYY-MM-DD`, IST).
  const DailyRecord.empty(this.day)
    : undone = const {},
      did = const {},
      lostSendUpdate = const {},
      emptyClaim = const {};

  /// The IST day this record counts.
  final String day;

  /// Per conversation: how many times this device undid a change today (M5).
  final Map<String, int> undone;

  /// Per conversation: the devices added and removed today.
  final Map<String, DailyDevices> did;

  /// Conversations whose lost-send self-update ran today (R7).
  final Set<String> lostSendUpdate;

  /// Device ids (hex) whose empty claim was retried today (R3).
  final Set<String> emptyClaim;

  DailyRecord copyWith({
    Map<String, int>? undone,
    Map<String, DailyDevices>? did,
    Set<String>? lostSendUpdate,
    Set<String>? emptyClaim,
  }) => DailyRecord(
    day: day,
    undone: undone ?? this.undone,
    did: did ?? this.did,
    lostSendUpdate: lostSendUpdate ?? this.lostSendUpdate,
    emptyClaim: emptyClaim ?? this.emptyClaim,
  );

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'day': day,
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
      }),
    ),
  );

  /// [VaultCorruptException] for a value that is not valid JSON, has another
  /// `v`, or is malformed.
  static DailyRecord decode(Uint8List bytes) {
    try {
      final m = _map(jsonDecode(utf8.decode(bytes)));
      if (m['v'] != 1) throw const FormatException('version');
      return DailyRecord(
        day: _string(m['day']),
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

  static int _int(Object? v) {
    if (v is int && v >= 0 && v <= kMaxPairComponent) return v;
    throw const FormatException('int');
  }

  static Set<String> _strings(Object? v) {
    if (v is! List<Object?>) throw const FormatException('list');
    return {for (final s in v) _string(s)};
  }
}

/// The counters that limit what this device does in one IST day (R3, R7, M5),
/// kept in one sealed vault setting. Everything goes through
/// `session.runWrite` and one vault transaction.
///
/// Never call a method here from inside a `runWrite` body (the mutex is not
/// re-entrant): read before the body ([read]), and write atomically with a
/// commit's result through [writeIn].
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
      (await read()).undone[conversationId] ?? 0;

  Future<void> addUndone(String conversationId) => _update(
    (r) => r.copyWith(
      undone: {
        ...r.undone,
        conversationId: (r.undone[conversationId] ?? 0) + 1,
      },
    ),
  );

  Future<bool> lostSendUpdateDone(String conversationId) async =>
      (await read()).lostSendUpdate.contains(conversationId);

  Future<void> markLostSendUpdate(String conversationId) => _update(
    (r) => r.copyWith(lostSendUpdate: {...r.lostSendUpdate, conversationId}),
  );

  Future<bool> emptyClaimTried(Uint8List deviceId) async =>
      (await read()).emptyClaim.contains(vaultDeviceIdHex(deviceId));

  Future<void> markEmptyClaim(Uint8List deviceId) => _update(
    (r) =>
        r.copyWith(emptyClaim: {...r.emptyClaim, vaultDeviceIdHex(deviceId)}),
  );

  /// The record of today: an empty one when none is stored, when the stored
  /// one is of another IST day, or when it cannot be read (reported once).
  /// Throws [StateError] when the vault is not ready. Not for a `runWrite`
  /// body.
  Future<DailyRecord> read() => _session.runWrite((vault) async {
    _checkVault(vault);
    return _load(vault);
  });

  /// For a caller already inside a `runWrite` body and transaction: applies
  /// [change] to the record through [tx]. [current] is the record the caller
  /// read BEFORE entering the body ([read]); a record of another day is
  /// replaced by an empty one first.
  Future<void> writeIn(
    VaultTx tx,
    DailyRecord current,
    DailyRecord Function(DailyRecord) change,
  ) {
    final today = istDay(_now());
    final base = current.day == today ? current : DailyRecord.empty(today);
    return tx.putSetting(kVaultSettingE2eeDaily, change(base).encode());
  }

  Future<void> _update(DailyRecord Function(DailyRecord) change) =>
      _session.runWrite((vault) async {
        _checkVault(vault);
        final current = await _load(vault);
        await vault.transaction(
          (tx) =>
              tx.putSetting(kVaultSettingE2eeDaily, change(current).encode()),
        );
      });

  void _checkVault(SecureVault vault) {
    if (!identical(_session.vault, vault)) {
      throw StateError('The vault is not ready.');
    }
  }

  Future<DailyRecord> _load(SecureVault vault) async {
    final today = istDay(_now());
    DailyRecord? stored;
    try {
      final bytes = await vault.setting(kVaultSettingE2eeDaily);
      if (bytes != null) stored = DailyRecord.decode(bytes);
    } on VaultCorruptException catch (_, stack) {
      if (!_reportedUnreadable) {
        _reportedUnreadable = true;
        _onUnexpectedError?.call(const E2eePipelineError('daily.read'), stack);
      }
    }
    if (stored == null || stored.day != today) return DailyRecord.empty(today);
    return stored;
  }
}
