import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/vault_status.dart';

/// Vault setting: the removal queue runner's own record (Task 11 review M1),
/// next to the F-7 queue (`kVaultSettingRemovalQueue`). Sealed
/// `{"v":1,"intents":[{"id":deviceId,"at":micros}]}`.
const String kVaultSettingRemovalRecord = 'messages.e2ee.removalRecord';

/// The most intents kept (the contract's 5 own devices, times 4).
const int kMaxRemovalIntents = 20;

/// An intent older than this is dropped (it was retried at every pass).
const Duration kRemovalIntentLimit = Duration(days: 30);

/// One removal the user asked for whose `RemoveKeyDevice` outcome is not
/// known yet: written BEFORE the call, so a crash or a vault change between
/// the call and the queue's write leaves it behind and the next pass runs
/// it again. [deviceId] is the server's device id string.
class RemovalIntent {
  const RemovalIntent({required this.deviceId, required this.atMicros});

  final String deviceId;
  final int atMicros;
}

/// The runner's record. Values only; no `toString` (it holds device ids).
class RemovalRecord {
  const RemovalRecord({this.intents = const []});

  final List<RemovalIntent> intents;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'intents': [
          for (final i in intents) {'id': i.deviceId, 'at': i.atMicros},
        ],
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
        intents: [for (final i in _list(m['intents'])) _intent(i)],
      );
    } on Object {
      throw const VaultCorruptException('vault_settings');
    }
  }

  static List<Object?> _list(Object? v) {
    if (v is List<Object?>) return v;
    throw const FormatException('list');
  }

  static RemovalIntent _intent(Object? v) {
    if (v is! Map<String, Object?>) throw const FormatException('intent');
    final id = v['id'];
    final at = v['at'];
    if (id is! String || id.isEmpty || at is! int || at < 0) {
      throw const FormatException('intent');
    }
    return RemovalIntent(deviceId: id, atMicros: at);
  }
}
