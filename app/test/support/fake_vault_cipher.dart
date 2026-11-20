import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dzeroth/core/vault/vault_cipher.dart';

/// A [VaultCipher] for VM tests. NOT secure, but it keeps the contract that
/// matters to the vault: the output is `nonce(12) || body || tag(16)`, the
/// body is the plaintext XORed with a SHA-256 keystream (so no plaintext
/// substring is visible), and the tag is an HMAC over the key, the
/// associated data `"$table|$rowKey"`, the nonce and the body. A value moved
/// to another table, column or row, altered, or opened under another key
/// throws [VaultRowException].
class FakeVaultCipher implements VaultCipher {
  FakeVaultCipher({this.freshlyCreated = false, String key = 'key-1'})
    : _key = utf8.encode(key);

  @override
  final bool freshlyCreated;

  List<int> _key;
  final _random = Random(7);

  /// Every call throws [VaultKeyException] with
  /// [VaultKeyFailure.unavailable] while set.
  bool unavailable = false;

  /// Every call throws [StateError] while set (stands in for "anything").
  bool throwsEverything = false;

  /// How many times [destroy] ran, and a hook it runs first.
  int destroyCalls = 0;
  Future<void> Function()? onDestroy;
  bool _destroyed = false;

  /// When it answers true for a seal label (`table.column`), sealing a value
  /// under it throws [StateError] (a write that fails part-way through a
  /// transaction).
  bool Function(String label)? failSeal;

  int sealCalls = 0;
  int openCalls = 0;

  /// Simulates a lost key: from now on this cipher seals and opens under
  /// another key, so every value sealed before fails to open.
  void switchToWrongKey() => _key = utf8.encode('wrong-key');

  void _guard() {
    if (_destroyed || _closed) throw StateError('destroyed');
    if (throwsEverything) throw StateError('fake failure');
    if (unavailable) {
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
  }

  List<int> _stream(List<int> nonce, int length) {
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      out.addAll(crypto.sha256.convert([..._key, ...nonce, counter++]).bytes);
    }
    return out.sublist(0, length);
  }

  List<int> _tag(Uint8List aad, List<int> nonce, List<int> body) =>
      crypto.Hmac(crypto.sha256, _key)
          .convert([
            ...aad.length.toString().codeUnits,
            0,
            ...aad,
            ...nonce,
            ...body,
          ])
          .bytes
          .sublist(0, 16);

  @override
  Future<Uint8List> seal(
    String table,
    String rowKey,
    Uint8List plaintext,
  ) async {
    _guard();
    if (failSeal?.call(table) ?? false) throw StateError('fake seal failure');
    sealCalls++;
    final aad = vaultRowAad(table, rowKey);
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final ks = _stream(nonce, plaintext.length);
    final body = [
      for (var i = 0; i < plaintext.length; i++) plaintext[i] ^ ks[i],
    ];
    return Uint8List.fromList([...nonce, ...body, ..._tag(aad, nonce, body)]);
  }

  @override
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed) async {
    _guard();
    openCalls++;
    if (sealed.length < 28) throw const VaultRowException();
    final aad = vaultRowAad(table, rowKey);
    final nonce = sealed.sublist(0, 12);
    final body = sealed.sublist(12, sealed.length - 16);
    final tag = sealed.sublist(sealed.length - 16);
    final expected = _tag(aad, nonce, body);
    for (var i = 0; i < 16; i++) {
      if (tag[i] != expected[i]) throw const VaultRowException();
    }
    final ks = _stream(nonce, body.length);
    return Uint8List.fromList([
      for (var i = 0; i < body.length; i++) body[i] ^ ks[i],
    ]);
  }

  @override
  Future<void> destroy() async {
    if (_destroyed) throw StateError('destroyed');
    destroyCalls++;
    await onDestroy?.call();
    _destroyed = true;
  }

  /// How many times [close] ended this cipher (a no-op call is not counted).
  int closeCalls = 0;

  /// True once [close] or [destroy] ended this cipher.
  bool get closed => _closed || _destroyed;
  bool _closed = false;

  /// Ends the cipher without deleting the key: later calls throw
  /// [StateError], as the real ciphers do. A no-op after [destroy] or a
  /// second [close]. To reopen the same key in a test, make a new
  /// [FakeVaultCipher] with the same key string.
  @override
  Future<void> close() async {
    if (_destroyed || _closed) return;
    closeCalls++;
    _closed = true;
  }
}
