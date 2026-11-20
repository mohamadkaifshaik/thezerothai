import 'dart:convert';
import 'dart:typed_data';

import '../../../../core/crypto/mls_pair.dart';
import '../../../../core/vault/secure_vault.dart';
import '../../../../core/vault/vault_status.dart';
import 'e2ee_types.dart';

/// Vault setting: the first-join baseline per conversation. Sealed
/// `{"v":1,"byConv":{conversationId:[generation, epoch]}}`; the key holds no
/// id.
const String kVaultSettingJoinBaseline = 'messages.e2ee.baseline';

/// The `since` of the members a FIRST join of a conversation pinned (the
/// baseline: no peer-side `deviceAdded` rows; the own-device alert only per
/// security read H2), kept in the vault so a restart between the join and the
/// attribution (an unaccepted request accepted later) still knows it.
///
/// Written in the first-join transaction; an entry goes with any later join of
/// that conversation, with `selfRemoved`, and in the attribution transaction
/// once no member at that `since` is unattributed. Every method takes the
/// vault the caller's `runWrite` body checked and reads the stored record
/// FRESH (a vault-wide setting written under per-conversation locks); call
/// [putIn] and [deleteIn] only inside that body's transaction.
///
/// An unreadable value is "no baseline recorded" (it can only add alerts,
/// never suppress one), reported once as `E2eePipelineError('baseline.read')`;
/// the next write replaces it. Never logs. No `toString`.
class JoinBaselines {
  JoinBaselines({
    void Function(Object error, StackTrace stack)? onUnexpectedError,
  }) : _onUnexpectedError = onUnexpectedError;

  final void Function(Object error, StackTrace stack)? _onUnexpectedError;
  bool _reportedUnreadable = false;

  /// The baseline `since` of [conversationId], or null.
  Future<MlsPair?> of(SecureVault vault, String conversationId) async =>
      (await _read(vault))[conversationId];

  /// Records [since] for [conversationId] (the stored record is read fresh).
  Future<void> putIn(
    VaultTx tx,
    SecureVault vault,
    String conversationId,
    MlsPair since,
  ) async {
    final all = {...await _read(vault)};
    all[conversationId] = since;
    await tx.putSetting(kVaultSettingJoinBaseline, _encode(all));
  }

  /// Deletes [conversationId]'s entry; writes nothing when there is none.
  Future<void> deleteIn(
    VaultTx tx,
    SecureVault vault,
    String conversationId,
  ) async {
    final all = {...await _read(vault)};
    if (all.remove(conversationId) == null) return;
    await tx.putSetting(kVaultSettingJoinBaseline, _encode(all));
  }

  Future<Map<String, MlsPair>> _read(SecureVault vault) async {
    try {
      final bytes = await vault.setting(kVaultSettingJoinBaseline);
      if (bytes == null) return {};
      return _decode(bytes);
    } on FormatException catch (_, stack) {
      _unreadable(stack);
    } on VaultCorruptException catch (_, stack) {
      _unreadable(stack);
    }
    return {};
  }

  void _unreadable(StackTrace stack) {
    if (_reportedUnreadable) return;
    _reportedUnreadable = true;
    _onUnexpectedError?.call(const E2eePipelineError('baseline.read'), stack);
  }

  static Map<String, MlsPair> _decode(Uint8List bytes) {
    final m = jsonDecode(utf8.decode(bytes));
    if (m is! Map<String, Object?> || m['v'] != 1) {
      throw const FormatException('shape');
    }
    final by = m['byConv'];
    if (by is! Map<String, Object?>) throw const FormatException('shape');
    final out = <String, MlsPair>{};
    for (final e in by.entries) {
      final pair = e.value;
      if (pair is! List<Object?> || pair.length != 2) {
        throw const FormatException('pair');
      }
      final g = pair[0];
      final ep = pair[1];
      if (g is! int ||
          ep is! int ||
          g < 0 ||
          ep < 0 ||
          g > kMaxPairComponent ||
          ep > kMaxPairComponent) {
        throw const FormatException('pair');
      }
      out[e.key] = MlsPair(g, ep);
    }
    return out;
  }

  static Uint8List _encode(Map<String, MlsPair> all) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'byConv': {
          for (final e in all.entries)
            e.key: [e.value.generation, e.value.epoch],
        },
      }),
    ),
  );
}
