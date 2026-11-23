import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/vault_status.dart';

/// Vault setting: the removal queue runner's own record (Task 11 review M1
/// and concern 1), next to the F-7 queue (`kVaultSettingRemovalQueue`).
/// Sealed `{"v":1,"intents":[{"id":deviceId,"at":micros,"key":b64,
/// "reauth":true}],"removed":[{"id":deviceId,"at":micros,"key":b64}]}`;
/// `key` and `reauth` are optional.
const String kVaultSettingRemovalRecord = 'messages.e2ee.removalRecord';

/// The most intents kept, and the most removed devices remembered (the
/// contract's 5 own devices, times 4). At the intent cap a new removal is
/// refused and no intent is dropped (Task 11 fix round 2, ruling 6). The
/// removed-mark cap never refuses a removal: the oldest mark no queue entry
/// or pin needs makes room, else the device is queued without a mark (fix
/// round 4, ruling 10).
const int kMaxRemovalIntents = 20;

/// An intent older than this is dropped (it was retried at every pass);
/// never one waiting for a re-sign-in ([RemovalMark.reauth]).
const Duration kRemovalIntentLimit = Duration(days: 30);

/// How long a device removed by the user is remembered as such (Task 11
/// review, concern 1).
const Duration kRemovedByUserLimit = Duration(days: 30);

/// A device id with a time. In [RemovalRecord.intents]: a removal the user
/// asked for whose `RemoveKeyDevice` outcome is not known yet, written
/// BEFORE the call (review M1). In [RemovalRecord.removed]: a device the
/// user removed, with the time RemoveKeyDevice succeeded (concern 1).
/// [deviceId] is the server's device id string. [signatureKey]: the key the
/// fresh own list showed for the device when the user removed it (fix round
/// 2, ruling 1): a pin of the id left `unattributed` with this very key is
/// the user's removed device. Null for a mark written without one. No
/// `toString`.
class RemovalMark {
  const RemovalMark({
    required this.deviceId,
    required this.atMicros,
    this.signatureKey,
    this.reauth = false,
  });

  final String deviceId;
  final int atMicros;
  final Uint8List? signatureKey;

  /// Intents only (Task 12 fix wave 9, SA L5): the server answered
  /// REAUTH_REQUIRED. Such an intent waits for a re-sign-in, is never
  /// dropped for its age (the intent cap still bounds it) and keeps the
  /// runner's `needsReauth` raised, also after a restart.
  final bool reauth;

  RemovalMark withReauth() => RemovalMark(
    deviceId: deviceId,
    atMicros: atMicros,
    signatureKey: signatureKey,
    reauth: true,
  );
}

/// The runner's record. Values only; no `toString` (it holds device ids).
class RemovalRecord {
  const RemovalRecord({this.intents = const [], this.removed = const []});

  final List<RemovalMark> intents;
  final List<RemovalMark> removed;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'intents': [for (final i in intents) _json(i)],
        'removed': [for (final r in removed) _json(r)],
      }),
    ),
  );

  /// [VaultCorruptException] (`vault_settings`) for anything malformed.
  static RemovalRecord decode(Uint8List bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes));
      if (m is! Map<String, Object?> || m['v'] != 1) {
        throw const FormatException('shape');
      }
      return RemovalRecord(
        intents: [for (final i in _list(m['intents'])) _mark(i)],
        removed: [for (final r in _list(m['removed'])) _mark(r)],
      );
    } on Object {
      throw const VaultCorruptException('vault_settings');
    }
  }

  static Map<String, Object?> _json(RemovalMark m) => {
    'id': m.deviceId,
    'at': m.atMicros,
    if (m.signatureKey case final key?) 'key': base64Encode(key),
    if (m.reauth) 'reauth': true,
  };

  static List<Object?> _list(Object? v) {
    if (v is List<Object?>) return v;
    throw const FormatException('list');
  }

  static RemovalMark _mark(Object? v) {
    if (v is! Map<String, Object?>) throw const FormatException('mark');
    final id = v['id'];
    final at = v['at'];
    final key = v['key'];
    final reauth = v['reauth'];
    if (id is! String ||
        id.isEmpty ||
        at is! int ||
        at < 0 ||
        (key != null && key is! String) ||
        (reauth != null && reauth != true)) {
      throw const FormatException('mark');
    }
    return RemovalMark(
      deviceId: id,
      atMicros: at,
      signatureKey: key == null ? null : base64Decode(key as String),
      reauth: reauth == true,
    );
  }
}
