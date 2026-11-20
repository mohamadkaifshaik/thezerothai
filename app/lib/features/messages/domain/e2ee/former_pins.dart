import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';

/// Vault setting: the pins of conversations this device left (`selfRemoved`)
/// or whose group states "set up again" deleted (security read H2). Sealed
/// `{"v":1,"byConv":{convId:[{"id":hex,"key":base64,"side":...}]}}`.
const String kVaultSettingFormerPins = 'messages.e2ee.formerPins';

/// The former pins, read from and written to the vault. Every write reads the
/// stored record FRESH (vault-wide setting, per-conversation callers: no lost
/// update) and replaces only the one conversation's entry; call [putIn] and
/// [deleteIn] only inside a `runWrite` body's transaction.
///
/// Every method takes the vault the caller's `runWrite` body checked (never
/// the session's current one: across a sign-out and sign-in another user's
/// vault could be published while an old body still runs). Never logs. No
/// `toString`.
///
/// Any future writer of former pins must keep the conversation's key-changed
/// marks (`KeyChangedDevices`): a former pin holds a changed key's NEW key.
class FormerPins {
  const FormerPins();

  Future<List<MemberRecord>> of(
    SecureVault vault,
    String conversationId,
  ) async => (await _read(vault))[conversationId] ?? const [];

  /// Every own-side (device id hex, key base64) pair (this device excluded)
  /// pinned `mine` in an ACCEPTED conversation other than [excluding]: current
  /// pins plus former pins of conversations that were accepted. Pins made in an
  /// unaccepted conversation do not count. A known id with another key is NOT
  /// in the set (it alerts). Read inside the `runWrite` body that writes rows.
  Future<Set<({String deviceIdHex, String keyB64})>> everPinnedMine(
    SecureVault vault, {
    required String excluding,
  }) async {
    final thisDevice = await vault.deviceId();
    final thisHex = thisDevice == null ? null : vaultDeviceIdHex(thisDevice);
    final former = await _read(vault);
    final out = <({String deviceIdHex, String keyB64})>{};
    for (final id in await _candidates(vault, former)) {
      if (id == excluding) continue;
      if (!await _accepted(vault, id)) continue;
      for (final m in await vault.members(id)) {
        if (m.side != MemberSide.mine) continue;
        final hex = vaultDeviceIdHex(m.deviceId);
        if (hex == thisHex) continue;
        out.add((deviceIdHex: hex, keyB64: base64Encode(m.signatureKey)));
      }
      for (final m in former[id] ?? const <MemberRecord>[]) {
        if (m.side != MemberSide.mine) continue;
        final hex = vaultDeviceIdHex(m.deviceId);
        if (hex == thisHex) continue;
        out.add((deviceIdHex: hex, keyB64: base64Encode(m.signatureKey)));
      }
    }
    return out;
  }

  /// True only while this vault has never stored a group of an accepted
  /// conversation other than [excluding]: no other conversation has
  /// `requestAccepted` together with a stored group or former pins.
  Future<bool> brandNewVault(
    SecureVault vault, {
    required String excluding,
  }) async {
    final former = await _read(vault);
    for (final id in await _candidates(vault, former)) {
      if (id == excluding) continue;
      if (!await _accepted(vault, id)) continue;
      final hasGroup = (await vault.groups(id)).isNotEmpty;
      final hasFormer = (former[id] ?? const []).isNotEmpty;
      if (hasGroup || hasFormer) return false;
    }
    return true;
  }

  /// Replaces [conversationId]'s entry (the stored record is read fresh).
  Future<void> putIn(
    VaultTx tx,
    SecureVault vault,
    String conversationId,
    List<MemberRecord> pins,
  ) async {
    final all = {...await _read(vault)};
    all[conversationId] = [
      for (final p in pins)
        MemberRecord(
          conversationId: conversationId,
          deviceId: p.deviceId,
          signatureKey: p.signatureKey,
          side: p.side,
          since: const MlsPair(0, 0),
        ),
    ];
    await tx.putSetting(kVaultSettingFormerPins, _encode(all));
  }

  /// Deletes [conversationId]'s entry (the pins are current again).
  Future<void> deleteIn(
    VaultTx tx,
    SecureVault vault,
    String conversationId,
  ) async {
    final all = {...await _read(vault)};
    if (all.remove(conversationId) == null) return;
    await tx.putSetting(kVaultSettingFormerPins, _encode(all));
  }

  static Future<Set<String>> _candidates(
    SecureVault vault,
    Map<String, List<MemberRecord>> former,
  ) async => {...await vault.groupConversationIds(), ...former.keys};

  static Future<bool> _accepted(SecureVault vault, String id) async =>
      (await vault.conversation(id))?.sync.requestAccepted ?? false;

  static Future<Map<String, List<MemberRecord>>> _read(
    SecureVault vault,
  ) async {
    final bytes = await vault.setting(kVaultSettingFormerPins);
    if (bytes == null) return {};
    try {
      final m = jsonDecode(utf8.decode(bytes));
      if (m is! Map<String, Object?> || m['v'] != 1) {
        throw const FormatException('shape');
      }
      final by = m['byConv'];
      if (by is! Map<String, Object?>) throw const FormatException('shape');
      final out = <String, List<MemberRecord>>{};
      for (final e in by.entries) {
        final list = e.value;
        if (list is! List<Object?>) throw const FormatException('shape');
        out[e.key] = [for (final p in list) _pin(e.key, p)];
      }
      return out;
    } on FormatException {
      throw const VaultCorruptException('vault_settings');
    }
  }

  static MemberRecord _pin(String conversationId, Object? p) {
    if (p is! Map<String, Object?>) throw const FormatException('pin');
    final id = p['id'];
    final key = p['key'];
    final side = p['side'];
    if (id is! String || key is! String || side is! String) {
      throw const FormatException('pin');
    }
    if (side != MemberSide.mine &&
        side != MemberSide.theirs &&
        side != MemberSide.unattributed) {
      throw const FormatException('side');
    }
    if (id.length.isOdd || !RegExp(r'^[0-9a-f]*$').hasMatch(id)) {
      throw const FormatException('id');
    }
    return MemberRecord(
      conversationId: conversationId,
      deviceId: Uint8List.fromList([
        for (var i = 0; i < id.length; i += 2)
          int.parse(id.substring(i, i + 2), radix: 16),
      ]),
      signatureKey: base64Decode(key),
      side: side,
      since: const MlsPair(0, 0),
    );
  }

  static Uint8List _encode(Map<String, List<MemberRecord>> all) =>
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'byConv': {
              for (final e in all.entries)
                e.key: [
                  for (final p in e.value)
                    {
                      'id': vaultDeviceIdHex(p.deviceId),
                      'key': base64Encode(p.signatureKey),
                      'side': p.side,
                    },
                ],
            },
          }),
        ),
      );
}
