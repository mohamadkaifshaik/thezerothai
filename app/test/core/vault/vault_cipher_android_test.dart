import 'dart:convert';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_cipher_android.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_crypto_engine.dart';

const _channel = MethodChannel('dzeroth/vault_key');

/// A stand-in for VaultKeyChannel.kt: a map alias -> wrapped key, where
/// "wrapping" is a reversible transform so the stored bytes differ from the
/// data key. [failUnwrap] / [failWrap] / [failDelete] answer with that error
/// code instead.
class _FakeKeystore {
  final stored = <String, Uint8List>{};
  final calls = <MethodCall>[];
  String? failUnwrap;
  String? failWrap;
  String? failDelete;
  Uint8List? unwrapOverride;

  static Uint8List _flip(Uint8List b) =>
      Uint8List.fromList([for (final x in b) x ^ 0x5a]);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = (call.arguments as Map<Object?, Object?>?) ?? const {};
    final alias = args['alias']! as String;
    switch (call.method) {
      case 'wrap':
        if (failWrap != null) {
          throw PlatformException(code: failWrap!, message: 'wrap failed');
        }
        stored[alias] = _flip(args['dataKey']! as Uint8List);
        return null;
      case 'unwrap':
        if (failUnwrap != null) {
          throw PlatformException(code: failUnwrap!, message: 'unwrap failed');
        }
        if (unwrapOverride != null) return unwrapOverride;
        final wrapped = stored[alias];
        if (wrapped == null) {
          throw PlatformException(code: 'no_key', message: 'no stored key');
        }
        return _flip(wrapped);
      case 'delete':
        if (failDelete != null) {
          throw PlatformException(code: failDelete!, message: 'delete failed');
        }
        stored.remove(alias);
        return null;
    }
    throw MissingPluginException();
  }
}

/// Keeps the list randomBytes returns, so a test can see it zeroed.
class _CapturingEngine extends FakeCryptoEngine {
  final keys = <Uint8List>[];

  @override
  Future<Uint8List> randomBytes(int length) async {
    final b = await super.randomBytes(length);
    keys.add(b);
    return b;
  }
}

/// seal/open fail with internal, as when the native library is missing.
class _BrokenEngine extends _CapturingEngine {
  bool fail = false;

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List aad, Uint8List plaintext) {
    if (fail) throw const MlsException(MlsErrorCode.internal, 'no library');
    return super.seal(key, aad, plaintext);
  }

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) {
    if (fail) throw const MlsException(MlsErrorCode.internal, 'no library');
    return super.open(key, aad, sealed);
  }
}

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

Future<VaultCipher> _open(FakeCryptoEngine engine, {String uid = 'user-1'}) =>
    openIoVaultCipher(uid: uid, engine: engine, isAndroid: true);

Matcher _keyFailure(VaultKeyFailure f) =>
    throwsA(isA<VaultKeyException>().having((e) => e.failure, 'failure', f));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeKeystore keystore;
  late _CapturingEngine engine;

  setUp(() {
    keystore = _FakeKeystore();
    engine = _CapturingEngine();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, keystore.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  test('alias is dzeroth.vault. + the first 32 hex of SHA-256(uid)', () {
    // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a3...
    expect(
      vaultKeyAlias('abc'),
      'dzeroth.vault.ba7816bf8f01cfea414140de5dae2223',
    );
  });

  test(
    'first open creates and wraps a 32-byte key; seal/open round trip',
    () async {
      final cipher = await _open(engine);
      expect(cipher.freshlyCreated, isTrue);
      expect(keystore.calls.map((c) => c.method), ['unwrap', 'wrap']);
      final wrapArgs = keystore.calls[1].arguments as Map<Object?, Object?>;
      expect(wrapArgs['alias'], vaultKeyAlias('user-1'));
      expect((wrapArgs['dataKey']! as Uint8List).length, 32);

      final sealed = await cipher.seal('messages', 'r1', _b('hello'));
      expect(sealed.length, 5 + 28);
      expect(await cipher.open('messages', 'r1', sealed), _b('hello'));
    },
  );

  test('a second open unwraps the same key and reads earlier rows', () async {
    final first = await _open(engine);
    final sealed = await first.seal('messages', 'r1', _b('kept'));

    keystore.calls.clear();
    final second = await _open(engine);
    expect(second.freshlyCreated, isFalse);
    expect(keystore.calls.map((c) => c.method), ['unwrap']);
    expect(await second.open('messages', 'r1', sealed), _b('kept'));
  });

  test('a row sealed for one (table, rowKey) does not open under another', () async {
    final cipher = await _open(engine);
    final sealed = await cipher.seal('messages', 'r1', _b('secret'));
    await expectLater(
      cipher.open('messages', 'r2', sealed),
      throwsA(isA<VaultRowException>()),
    );
    await expectLater(
      cipher.open('drafts', 'r1', sealed),
      throwsA(isA<VaultRowException>()),
    );
    // "a|b" + "c" and "a" + "b|c" would share an AAD; the separator is refused.
    await expectLater(cipher.seal('a|b', 'c', _b('x')), throwsArgumentError);
    await expectLater(cipher.open('a|b', 'c', sealed), throwsArgumentError);
  });

  test('a row sealed under another uid does not open', () async {
    final a = await _open(engine);
    final b = await _open(engine, uid: 'user-2');
    final sealed = await a.seal('messages', 'r1', _b('secret'));
    await expectLater(
      b.open('messages', 'r1', sealed),
      throwsA(isA<VaultRowException>()),
    );
  });

  test('unwrap key_lost is keyLost and never mints a new key', () async {
    await _open(engine);
    keystore.failUnwrap = 'key_lost';
    keystore.calls.clear();
    await expectLater(_open(engine), _keyFailure(VaultKeyFailure.keyLost));
    expect(keystore.calls.map((c) => c.method), ['unwrap']);
  });

  test('an unwrapped key of the wrong length is keyLost', () async {
    keystore.unwrapOverride = Uint8List(16);
    await expectLater(_open(engine), _keyFailure(VaultKeyFailure.keyLost));
  });

  test(
    'unavailable, unknown codes and a missing plugin are unavailable',
    () async {
      for (final code in ['unavailable', 'something_new']) {
        keystore.failUnwrap = code;
        await expectLater(
          _open(engine),
          _keyFailure(VaultKeyFailure.unavailable),
        );
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      await expectLater(
        _open(engine),
        _keyFailure(VaultKeyFailure.unavailable),
      );
    },
  );

  test('a failed wrap returns no cipher and zeroes the new key', () async {
    keystore.failWrap = 'unavailable';
    await expectLater(_open(engine), _keyFailure(VaultKeyFailure.unavailable));
    expect(engine.keys.single, everyElement(0));
    expect(keystore.stored, isEmpty);
  });

  test(
    'destroy zeroes the key, deletes the platform key, ends the cipher',
    () async {
      final cipher = await _open(engine);
      final sealed = await cipher.seal('messages', 'r1', _b('old'));
      await cipher.destroy();

      expect(engine.keys.single, everyElement(0));
      expect(keystore.calls.last.method, 'delete');
      expect(
        (keystore.calls.last.arguments as Map<Object?, Object?>)['alias'],
        vaultKeyAlias('user-1'),
      );
      expect(keystore.stored, isEmpty);
      await expectLater(
        cipher.seal('messages', 'r2', _b('x')),
        throwsStateError,
      );
      await expectLater(
        cipher.open('messages', 'r1', sealed),
        throwsStateError,
      );
      await expectLater(cipher.destroy(), throwsStateError);

      // Reopening makes a fresh key; old rows no longer authenticate. The vault
      // reads freshlyCreated plus existing rows as key loss.
      final again = await _open(engine);
      expect(again.freshlyCreated, isTrue);
      await expectLater(
        again.open('messages', 'r1', sealed),
        throwsA(isA<VaultRowException>()),
      );
    },
  );

  test(
    'a failed delete still ends the cipher and reports unavailable',
    () async {
      final cipher = await _open(engine);
      keystore.failDelete = 'unavailable';
      await expectLater(
        cipher.destroy(),
        _keyFailure(VaultKeyFailure.unavailable),
      );
      expect(engine.keys.single, everyElement(0));
      await expectLater(
        cipher.seal('messages', 'r1', _b('x')),
        throwsStateError,
      );
    },
  );

  test('errors and the cipher print no key bytes', () async {
    final cipher = await _open(engine);
    final key = engine.keys.single;
    final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    for (final s in [
      cipher.toString(),
      const VaultKeyException(VaultKeyFailure.keyLost).toString(),
      const VaultRowException().toString(),
    ]) {
      expect(s, isNot(contains(hex)));
      expect(s, isNot(contains(key.join(', '))));
    }
    expect(
      const VaultKeyException(VaultKeyFailure.unavailable).toString(),
      'VaultKeyException(unavailable)',
    );
  });

  test('an engine that fails (not authentication) is unavailable', () async {
    final broken = _BrokenEngine();
    final cipher = await _open(broken);
    broken.fail = true;
    await expectLater(
      cipher.seal('messages', 'r1', _b('x')),
      _keyFailure(VaultKeyFailure.unavailable),
    );
    await expectLater(
      cipher.open('messages', 'r1', Uint8List(40)),
      _keyFailure(VaultKeyFailure.unavailable),
    );
  });

  test('a plaintext over the engine limit is an ArgumentError', () async {
    final cipher = await _open(engine);
    await expectLater(
      cipher.seal('messages', 'r1', Uint8List(1048577)),
      throwsArgumentError,
    );
  });

  test('off Android the io factory throws UnsupportedError', () async {
    expect(
      () => openIoVaultCipher(uid: 'u', engine: engine, isAndroid: false),
      throwsUnsupportedError,
    );
    // The VM test host is never Android.
    expect(
      () => openVaultCipher(uid: 'u', engine: engine),
      throwsUnsupportedError,
    );
  });
}
