import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting: the devices whose signature key changed under the same
/// device id, per conversation. Sealed
/// `{"v":1,"byConv":{conversationId:{deviceIdHex:newKeyBase64}}}`; the key
/// holds no id.
const String kVaultSettingKeyChanged = 'messages.e2ee.keyChanged';

/// The (device id, new key) pairs this device saw replace another key of the
/// same device id in a conversation (a commit's comparison, or a join against
/// the current or former pins), whatever the acceptance state. Attribution
/// never pins a marked (device id, key): it stays an unknown device; an
/// ordinary unknown device (not marked) is attributed once a list shows it.
///
/// Written in the transaction that sees the key differ. An entry goes only
/// when its device leaves the conversation's pins (removed by a commit,
/// `selfRemoved`, a later join that no longer holds it); nothing else clears
/// it. Every method takes the vault the caller's `runWrite` body checked and
/// reads the stored record FRESH (a vault-wide setting written under
/// per-conversation locks); call [updateIn] only inside that body's
/// transaction.
///
/// Fails closed: an unreadable value marks EVERY member of every
/// conversation (nobody is attributed from it), is reported once as
/// `E2eePipelineError('keyChanged.read')`, and is never overwritten (a write
/// would drop every mark it holds). Never logs. No `toString` here or on
/// [KeyChangedMarks] prints an id or a key.
class KeyChangedDevices {
  KeyChangedDevices({
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _onUnexpectedError = onUnexpectedError;

  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  bool _reportedUnreadable = false;

  /// [conversationId]'s marks.
  Future<KeyChangedMarks> of(SecureVault vault, String conversationId) async {
    final all = await _read(vault);
    if (all == null) return const KeyChangedMarks._unreadable();
    return KeyChangedMarks._(all[conversationId] ?? const {});
  }

  /// One edit of [conversationId]'s entry, in this order: [clear] drops it
  /// all; [keepOnly] (device id hex) drops every device not in it; [drop]
  /// (device id hex) drops those; [mark] (device id hex to new key) records
  /// those. Reads the stored record fresh; writes nothing when nothing
  /// changed or when the stored value is unreadable.
  Future<void> updateIn(
    VaultTx tx,
    SecureVault vault,
    String conversationId, {
    bool clear = false,
    Set<String>? keepOnly,
    Iterable<String> drop = const [],
    Map<String, Uint8List> mark = const {},
  }) async {
    final stored = await _read(vault);
    if (stored == null) return;
    final before = stored[conversationId] ?? const <String, String>{};
    final entry = clear ? <String, String>{} : {...before};
    if (keepOnly != null) {
      entry.removeWhere((hex, _) => !keepOnly.contains(hex));
    }
    for (final hex in drop) {
      entry.remove(hex);
    }
    for (final e in mark.entries) {
      entry[e.key] = base64Encode(e.value);
    }
    if (_sameEntry(before, entry)) return;
    final all = {...stored};
    if (entry.isEmpty) {
      all.remove(conversationId);
    } else {
      all[conversationId] = entry;
    }
    await tx.putSetting(kVaultSettingKeyChanged, _encode(all));
  }

  /// Null: the stored value cannot be read.
  Future<Map<String, Map<String, String>>?> _read(SecureVault vault) async {
    try {
      final bytes = await vault.setting(kVaultSettingKeyChanged);
      if (bytes == null) return {};
      return _decode(bytes);
    } on FormatException catch (_, stack) {
      _unreadable(stack);
    } on VaultCorruptException catch (_, stack) {
      _unreadable(stack);
    }
    return null;
  }

  void _unreadable(StackTrace stack) {
    if (_reportedUnreadable) return;
    _reportedUnreadable = true;
    _onUnexpectedError?.call(const E2eePipelineError('keyChanged.read'), stack);
  }

  static bool _sameEntry(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  static Map<String, Map<String, String>> _decode(Uint8List bytes) {
    final m = jsonDecode(utf8.decode(bytes));
    if (m is! Map<String, Object?> || m['v'] != 1) {
      throw const FormatException('shape');
    }
    final by = m['byConv'];
    if (by is! Map<String, Object?>) throw const FormatException('shape');
    final out = <String, Map<String, String>>{};
    for (final c in by.entries) {
      final devices = c.value;
      if (devices is! Map<String, Object?>) {
        throw const FormatException('entry');
      }
      final entry = <String, String>{};
      for (final d in devices.entries) {
        final key = d.value;
        if (d.key.isEmpty || key is! String || key.isEmpty) {
          throw const FormatException('entry');
        }
        // A key that is not base64 cannot be compared: unreadable.
        base64Decode(key);
        entry[d.key] = key;
      }
      out[c.key] = entry;
    }
    return out;
  }

  static Uint8List _encode(Map<String, Map<String, String>> all) =>
      Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'byConv': all})));
}

/// One conversation's marks, read for one decision. No `toString` prints an
/// id or a key.
class KeyChangedMarks {
  const KeyChangedMarks._(this._byHex) : unreadable = false;

  const KeyChangedMarks._unreadable() : _byHex = const {}, unreadable = true;

  /// The stored value could not be read: every member counts as marked.
  final bool unreadable;

  final Map<String, String> _byHex;

  /// True when ([deviceIdHex], [signatureKey]) is marked (always when
  /// [unreadable]).
  bool marks(String deviceIdHex, Uint8List signatureKey) {
    if (unreadable) return true;
    final key = _byHex[deviceIdHex];
    return key != null && key == base64Encode(signatureKey);
  }

  /// True when [deviceIdHex] is marked with a key other than [signatureKey]
  /// (the device changed its key again).
  bool marksOtherKey(String deviceIdHex, Uint8List signatureKey) {
    final key = _byHex[deviceIdHex];
    return key != null && key != base64Encode(signatureKey);
  }

  @override
  String toString() => 'KeyChangedMarks';
}
