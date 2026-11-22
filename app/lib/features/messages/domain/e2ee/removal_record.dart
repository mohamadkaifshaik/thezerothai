import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/vault_status.dart';

/// Vault setting: the removal queue runner's own record (Task 11 review M1
/// and concern 1), next to the F-7 queue (`kVaultSettingRemovalQueue`).
/// Sealed `{"v":1,"intents":[{"id":deviceId,"at":micros}],
/// "removed":[{"id":deviceId,"at":micros}]}`.
const String kVaultSettingRemovalRecord = 'messages.e2ee.removalRecord';

/// The most intents kept, and the most removed devices remembered (the
/// contract's 5 own devices, times 4). The oldest go first.
const int kMaxRemovalIntents = 20;

/// An intent older than this is dropped (it was retried at every pass).
const Duration kRemovalIntentLimit = Duration(days: 30);

/// How long a device removed by the user is remembered as such (Task 11
/// review, concern 1).
const Duration kRemovedByUserLimit = Duration(days: 30);

/// A device id with a time. In [RemovalRecord.intents]: a removal the user
/// asked for whose `RemoveKeyDevice` outcome is not known yet, written
/// BEFORE the call (review M1). In [RemovalRecord.removed]: a device the
/// user removed, with the time RemoveKeyDevice succeeded (concern 1).
/// [deviceId] is the server's device id string. No `toString`.
class RemovalMark {
  const RemovalMark({required this.deviceId, required this.atMicros});

  final String deviceId;
  final int atMicros;
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
  };

  static List<Object?> _list(Object? v) {
    if (v is List<Object?>) return v;
    throw const FormatException('list');
  }

  static RemovalMark _mark(Object? v) {
    if (v is! Map<String, Object?>) throw const FormatException('mark');
    final id = v['id'];
    final at = v['at'];
    if (id is! String || id.isEmpty || at is! int || at < 0) {
      throw const FormatException('mark');
    }
    return RemovalMark(deviceId: id, atMicros: at);
  }
}
