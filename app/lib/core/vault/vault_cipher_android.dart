// The Android vault key, over the platform channel `dzeroth/vault_key`
// (android/app/src/main/kotlin/com/dzeroth/dzeroth/VaultKeyChannel.kt).
//
// Channel protocol (mirrors the Kotlin header; all arguments are a map):
//
//   wrap   {alias: String, dataKey: Uint8List(32)} -> null
//          Replaces any Keystore key under alias with a new AES-256-GCM key,
//          wraps dataKey with it and stores iv || ciphertext+tag (base64) in
//          the private SharedPreferences file dzeroth_vault_keys under alias.
//          Replies only after the write is on disk.
//   unwrap {alias: String} -> Uint8List (the data key)
//   delete {alias: String} -> null   (idempotent: deletes the Keystore key and
//          the stored wrapped key)
//
// Error codes (PlatformException.code; message is fixed text, details null):
//   no_key       unwrap: no stored wrapped key for alias (first use).
//   key_lost     unwrap: a stored key exists but cannot be unwrapped
//                (Keystore alias missing, key permanently invalidated,
//                unrecoverable key, bad tag, malformed stored bytes).
//   unavailable  anything else (Keystore or storage not usable).
import 'dart:io' show Platform;

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

const _channel = MethodChannel('dzeroth/vault_key');
const _dataKeyLength = 32;

/// The Android vault; other dart:io platforms (iOS, desktop) have none.
Future<VaultCipher> openPlatformVaultCipher({
  required String uid,
  required CryptoEngine engine,
}) =>
    openIoVaultCipher(uid: uid, engine: engine, isAndroid: Platform.isAndroid);

/// [openPlatformVaultCipher] with the platform check passed in, for tests.
@visibleForTesting
Future<VaultCipher> openIoVaultCipher({
  required String uid,
  required CryptoEngine engine,
  required bool isAndroid,
}) {
  if (!isAndroid) {
    throw UnsupportedError(
      'No encrypted vault on this platform; only web and Android have one.',
    );
  }
  return AndroidVaultCipher._open(uid: uid, engine: engine);
}

VaultKeyException _mapPlatform(Object e) {
  if (e is PlatformException && e.code == 'key_lost') {
    return const VaultKeyException(VaultKeyFailure.keyLost);
  }
  // unavailable, an unknown code, MissingPluginException or anything else.
  return const VaultKeyException(VaultKeyFailure.unavailable);
}

/// The vault cipher whose data key is wrapped by the Android Keystore.
class AndroidVaultCipher implements VaultCipher {
  AndroidVaultCipher._(
    this._alias,
    this._engine,
    this._key,
    this.freshlyCreated,
  );

  final String _alias;
  final CryptoEngine _engine;

  // The data key. Only here, never copied, printed or logged; zeroed by
  // destroy (and set to null so later calls fail).
  Uint8List? _key;

  @override
  final bool freshlyCreated;

  static Future<AndroidVaultCipher> _open({
    required String uid,
    required CryptoEngine engine,
  }) async {
    final alias = vaultKeyAlias(uid);
    try {
      final key = await _channel.invokeMethod<Uint8List>('unwrap', {
        'alias': alias,
      });
      if (key == null || key.length != _dataKeyLength) {
        key?.fillRange(0, key.length, 0);
        throw const VaultKeyException(VaultKeyFailure.keyLost);
      }
      return AndroidVaultCipher._(alias, engine, key, false);
    } on PlatformException catch (e) {
      if (e.code != 'no_key') throw _mapPlatform(e);
    } on VaultKeyException {
      rethrow;
    } on Object catch (e) {
      throw _mapPlatform(e);
    }

    // No stored key: first use for this user on this device.
    final Uint8List key;
    try {
      key = await engine.randomBytes(_dataKeyLength);
    } on Object {
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
    try {
      await _channel.invokeMethod<void>('wrap', {
        'alias': alias,
        'dataKey': key,
      });
    } on Object {
      // Never hand out a key that is not stored: rows sealed under it would
      // be lost on the next start.
      key.fillRange(0, key.length, 0);
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
    return AndroidVaultCipher._(alias, engine, key, true);
  }

  Uint8List _liveKey() {
    final key = _key;
    if (key == null) throw StateError('The vault cipher was destroyed.');
    return key;
  }

  // seal/open read the key and pass it to the engine with no await in
  // between: the engine copies its arguments when the call is made, so a
  // destroy that runs while a call is in flight cannot change its key.

  @override
  Future<Uint8List> seal(
    String table,
    String rowKey,
    Uint8List plaintext,
  ) async {
    // Errors (destroyed, a bad table) come back as a failed future.
    final key = _liveKey();
    try {
      return await _engine.seal(key, vaultRowAad(table, rowKey), plaintext);
    } on MlsException catch (e) {
      // With a 32-byte key, badInput can only be the plaintext size.
      if (e.code == MlsErrorCode.badInput) {
        throw ArgumentError.value(
          plaintext.length,
          'plaintext.length',
          'more than 1 MiB',
        );
      }
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
  }

  @override
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed) async {
    final key = _liveKey();
    final aad = vaultRowAad(table, rowKey);
    try {
      return await _engine.open(key, aad, sealed);
    } on MlsException catch (e) {
      // badInput is every authentication failure. Anything else (the native
      // library missing: internal) is not about this row: the engine is not
      // usable right now.
      if (e.code == MlsErrorCode.badInput) throw const VaultRowException();
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
  }

  @override
  Future<void> destroy() async {
    final key = _liveKey();
    key.fillRange(0, key.length, 0);
    _key = null;
    try {
      await _channel.invokeMethod<void>('delete', {'alias': _alias});
    } on Object {
      throw const VaultKeyException(VaultKeyFailure.unavailable);
    }
  }
}
