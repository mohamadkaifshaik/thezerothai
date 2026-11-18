// The Android vault key, over the platform channel `dzeroth/vault_key`
// (android/app/src/main/kotlin/com/dzeroth/dzeroth/VaultKeyChannel.kt).
//
// Channel protocol (mirrors the Kotlin header; all arguments are a map):
//
//   wrap   {alias: String, dataKey: Uint8List(32)} -> null
//          Create-if-absent. When a wrapped key is already stored for alias it
//          answers `exists` and changes nothing. Otherwise it generates a new
//          AES-256-GCM Keystore key under alias (replacing an unreachable key
//          left there without a stored value), wraps dataKey with it and then
//          stores iv || ciphertext+tag (base64) in the private
//          SharedPreferences file dzeroth_vault_keys under alias. Replies only
//          after the write is on disk.
//   unwrap {alias: String} -> Uint8List (the data key)
//          Kotlin retries once after a short delay before answering
//          `unavailable`, and when the Keystore returns no key.
//   delete {alias: String} -> null   (idempotent: removes the stored wrapped
//          key first, then the Keystore key)
//
// Kotlin runs wrap, unwrap and delete under one process-wide lock, so two
// FlutterEngines never interleave.
//
// Error codes (PlatformException.code; message is fixed text, details null):
//   no_key       unwrap: no stored wrapped key for alias (first use).
//   exists       wrap: a wrapped key is already stored; nothing changed.
//   key_lost     unwrap: a stored key exists but is gone for good: no Keystore
//                key on both attempts and the alias absent, bad tag,
//                malformed stored bytes, or a permanently invalidated /
//                permanently failed key (see the Kotlin header for the exact
//                exceptions and codes).
//   unavailable  anything else, transient failures included.
//
// Dart maps key_lost to VaultKeyFailure.keyLost and every other error
// (unavailable, unknown codes, MissingPluginException: for example in a
// background FlutterEngine, which has no channel) to unavailable. Only no_key
// creates a key.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

const _channel = MethodChannel('dzeroth/vault_key');
const _dataKeyLength = 32;
const _unavailable = VaultKeyException(VaultKeyFailure.unavailable);
const _keyLost = VaultKeyException(VaultKeyFailure.keyLost);

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
  _requireAndroid(isAndroid);
  final alias = vaultKeyAlias(uid);
  return _serialized(alias, () => AndroidVaultCipher._open(alias, engine));
}

/// [deleteVaultKey] on dart:io platforms.
Future<void> platformDeleteVaultKey(String uid) =>
    deleteIoVaultKey(uid: uid, isAndroid: Platform.isAndroid);

/// [platformDeleteVaultKey] with the platform check passed in, for tests.
@visibleForTesting
Future<void> deleteIoVaultKey({
  required String uid,
  required bool isAndroid,
}) async {
  _requireAndroid(
    isAndroid,
  ); // async: off Android a failed Future, like the web
  final alias = vaultKeyAlias(uid);
  return _serialized(alias, () => _deleteAlias(alias));
}

/// [vaultStoragePersisted] on dart:io platforms.
Future<bool> platformVaultStoragePersisted() =>
    ioVaultStoragePersisted(isAndroid: Platform.isAndroid);

/// Android keeps the wrapped key in app-private storage that the system never
/// evicts; other io platforms have no vault.
@visibleForTesting
Future<bool> ioVaultStoragePersisted({required bool isAndroid}) async =>
    isAndroid;

void _requireAndroid(bool isAndroid) {
  if (!isAndroid) {
    throw UnsupportedError(
      'No encrypted vault on this platform; only web and Android have one.',
    );
  }
}

// Opens and deletes of one alias run one at a time, so two concurrent opens
// end on the same stored key (the second unwraps what the first stored) and
// a delete never interleaves with an open. A failed task does not block the
// next one.
final Map<String, Future<void>> _tails = {};

Future<T> _serialized<T>(String alias, Future<T> Function() task) {
  final previous = _tails[alias] ?? Future<void>.value();
  final result = previous.then((_) => task());
  final tail = result.then<void>((_) {}, onError: (Object _) {});
  _tails[alias] = tail;
  unawaited(
    tail.whenComplete(() {
      if (identical(_tails[alias], tail)) _tails.remove(alias);
    }),
  );
  return result;
}

Future<void> _deleteAlias(String alias) async {
  try {
    await _channel.invokeMethod<void>('delete', {'alias': alias});
  } on Object {
    throw _unavailable;
  }
}

/// Unwraps the stored key: null when none is stored (`no_key`).
Future<Uint8List?> _unwrap(String alias) async {
  final Uint8List? key;
  try {
    key = await _channel.invokeMethod<Uint8List>('unwrap', {'alias': alias});
  } on PlatformException catch (e) {
    if (e.code == 'no_key') return null;
    if (e.code == 'key_lost') throw _keyLost;
    throw _unavailable;
  } on Object {
    throw _unavailable;
  }
  // The decoded reply can be a view of the engine's read-only message buffer,
  // which cannot be zeroed (Dart cannot clear that copy), so the cipher keeps
  // its own copy that destroy can zero.
  if (key == null || key.length != _dataKeyLength) throw _keyLost;
  return Uint8List.fromList(key);
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

  // The data key: the one long-lived copy in Dart, never printed or logged.
  // The channel codec makes short-lived copies when it is wrapped or
  // unwrapped (Kotlin zeroes its side). Zeroed by destroy once no call is in
  // flight.
  final Uint8List _key;

  // Set first by destroy: new calls are refused while in-flight ones finish.
  bool _closed = false;
  int _inFlight = 0;
  Completer<void>? _drained;

  @override
  final bool freshlyCreated;

  static Future<AndroidVaultCipher> _open(
    String alias,
    CryptoEngine engine,
  ) async {
    final stored = await _unwrap(alias);
    if (stored != null) {
      return AndroidVaultCipher._(alias, engine, stored, false);
    }

    // No stored key: first use for this user on this device.
    final Uint8List key;
    try {
      key = await engine.randomBytes(_dataKeyLength);
    } on Object {
      throw _unavailable;
    }
    try {
      await _channel.invokeMethod<void>('wrap', {
        'alias': alias,
        'dataKey': key,
      });
      return AndroidVaultCipher._(alias, engine, key, true);
    } on PlatformException catch (e) {
      // Never hand out a key that is not stored: rows sealed under it would
      // be lost on the next start.
      key.fillRange(0, key.length, 0);
      if (e.code != 'exists') throw _unavailable;
    } on Object {
      key.fillRange(0, key.length, 0);
      throw _unavailable;
    }

    // Another writer stored a key first: adopt it.
    final theirs = await _unwrap(alias);
    if (theirs == null) throw _unavailable;
    return AndroidVaultCipher._(alias, engine, theirs, false);
  }

  // The engine may read the key at any point until its future completes
  // (nothing promises a copy at call time), so seal/open count themselves in
  // flight and destroy zeroes the key only after they finish.
  Future<T> _run<T>(Future<T> Function(Uint8List key) body) async {
    if (_closed) throw StateError('The vault cipher was destroyed.');
    _inFlight++;
    try {
      return await body(_key);
    } finally {
      _inFlight--;
      if (_inFlight == 0) _drained?.complete();
    }
  }

  @override
  Future<Uint8List> seal(String table, String rowKey, Uint8List plaintext) =>
      _run((key) async {
        final aad = vaultRowAad(table, rowKey);
        try {
          return await _engine.seal(key, aad, plaintext);
        } on MlsException catch (e) {
          // With a 32-byte key, badInput can only be the plaintext size.
          if (e.code == MlsErrorCode.badInput) {
            throw ArgumentError.value(
              plaintext.length,
              'plaintext.length',
              'more than 1 MiB',
            );
          }
          throw _unavailable;
        }
      });

  @override
  Future<Uint8List> open(String table, String rowKey, Uint8List sealed) =>
      _run((key) async {
        final aad = vaultRowAad(table, rowKey);
        try {
          return await _engine.open(key, aad, sealed);
        } on MlsException catch (e) {
          // badInput is every authentication failure. Anything else (the
          // native library missing: internal) is not about this row: the
          // engine is not usable right now.
          if (e.code == MlsErrorCode.badInput) throw const VaultRowException();
          throw _unavailable;
        }
      });

  @override
  Future<void> destroy() async {
    if (_closed) throw StateError('The vault cipher was destroyed.');
    _closed = true;
    if (_inFlight > 0) {
      final drained = _drained = Completer<void>();
      await drained.future;
    }
    _key.fillRange(0, _key.length, 0);
    await _serialized(_alias, () => _deleteAlias(_alias));
  }
}
