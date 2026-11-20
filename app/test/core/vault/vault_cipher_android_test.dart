import 'dart:async';
import 'dart:convert';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:dzeroth/core/vault/vault_cipher_android.dart';
import 'package:dzeroth/core/vault/vault_cipher_stub.dart' as stub;
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
  Uint8List? storeBeforeWrap;

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
        // Another writer got there first (an earlier process, a second
        // engine): it stores its key, so this wrap must change nothing.
        final other = storeBeforeWrap;
        if (other != null) {
          storeBeforeWrap = null;
          stored[alias] = _flip(other);
        }
        if (stored.containsKey(alias)) {
          throw PlatformException(code: 'exists', message: 'already stored');
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

/// seal/open (and randomBytes once [failRandom] is set) fail with [code], as
/// the guarded engine does on a timeout or when it is unavailable.
class _DeadlineEngine extends _CapturingEngine {
  _DeadlineEngine(this.code);

  final MlsErrorCode code;
  bool failRandom = false;

  @override
  Future<Uint8List> randomBytes(int length) {
    if (failRandom) throw MlsException(code, 'engine call timed out');
    return super.randomBytes(length);
  }

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List aad, Uint8List plaintext) =>
      Future.error(MlsException(code, 'engine call timed out'));

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) =>
      Future.error(MlsException(code, 'engine call timed out'));
}

/// randomBytes waits on [gate] (when set), so a test can interleave two
/// opens there.
class _GatedRandomEngine extends _CapturingEngine {
  Completer<void>? gate;
  int randomCalls = 0;

  @override
  Future<Uint8List> randomBytes(int length) async {
    randomCalls++;
    final g = gate;
    if (g != null) await g.future;
    return super.randomBytes(length);
  }
}

/// seal copies the key it is given, then waits on [sealGate] and only then
/// reads the key: an engine that reads its arguments late.
class _LateReadEngine extends _CapturingEngine {
  Completer<void>? sealGate;
  Uint8List? keySeenAtCall;

  @override
  Future<Uint8List> seal(
    Uint8List key,
    Uint8List aad,
    Uint8List plaintext,
  ) async {
    keySeenAtCall = Uint8List.fromList(key);
    final g = sealGate;
    if (g != null) await g.future;
    return super.seal(key, aad, plaintext);
  }
}

/// open waits on [openGate], then fails as an authentication failure does
/// (badInput): what a late call reading a zeroed key would produce.
class _LateFailingOpenEngine extends _CapturingEngine {
  Completer<void>? openGate;

  @override
  Future<Uint8List> open(Uint8List key, Uint8List aad, Uint8List sealed) async {
    final g = openGate;
    if (g != null) await g.future;
    throw const MlsException(MlsErrorCode.badInput, 'authentication failed');
  }
}

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));
String _s(Uint8List b) => utf8.decode(b);

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

  test('A-M2: a SUCCESS unwrap reply of the wrong length or null is an '
      'anomaly (unavailable), never keyLost, and mints no key', () async {
    await _open(engine); // a key is stored
    keystore.calls.clear();
    keystore.unwrapOverride = Uint8List(16);
    await expectLater(_open(engine), _keyFailure(VaultKeyFailure.unavailable));
    keystore.unwrapOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'unwrap') {
            keystore.calls.add(call);
            return null;
          }
          return keystore.handle(call);
        });
    await expectLater(_open(engine), _keyFailure(VaultKeyFailure.unavailable));
    expect(keystore.calls.map((c) => c.method), ['unwrap', 'unwrap']);
    expect(engine.keys, hasLength(1));
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

      // Reopening makes a fresh key; old rows no longer authenticate (the
      // vault's sentinel, not freshlyCreated, then reports key loss).
      final again = await _open(engine);
      expect(again.freshlyCreated, isTrue);
      await expectLater(
        again.open('messages', 'r1', sealed),
        throwsA(isA<VaultRowException>()),
      );
    },
  );

  test('after close seal and open throw StateError, no delete was sent, and a '
      'new open reads rows sealed before', () async {
    final cipher = await _open(engine);
    final sealed = await cipher.seal('messages', 'r1', _b('old'));
    await cipher.close();

    await expectLater(cipher.seal('messages', 'r2', _b('x')), throwsStateError);
    await expectLater(cipher.open('messages', 'r1', sealed), throwsStateError);
    expect(keystore.calls.where((c) => c.method == 'delete'), isEmpty);
    expect(keystore.stored, isNotEmpty);

    final again = await _open(engine);
    expect(again.freshlyCreated, isFalse);
    expect(_s(await again.open('messages', 'r1', sealed)), 'old');
  });

  test('close zeroes the key bytes', () async {
    final cipher = await _open(engine);
    expect(engine.keys.single, isNot(everyElement(0)));
    await cipher.close();
    expect(engine.keys.single, everyElement(0));
  });

  test('close waits for a seal in flight, then zeroes the key', () async {
    final late = _LateReadEngine()..sealGate = Completer<void>();
    final cipher = await _open(late);
    final sealing = cipher.seal('messages', 'r1', _b('x'));
    await pumpEventQueue();
    var closed = false;
    final closing = cipher.close().then((_) => closed = true);
    await pumpEventQueue();
    expect(closed, isFalse);
    expect(late.keys.single, isNot(everyElement(0)));
    late.sealGate!.complete();
    await sealing;
    await closing;
    expect(late.keys.single, everyElement(0));
  });

  test('close is idempotent and a no-op after destroy', () async {
    final cipher = await _open(engine);
    await cipher.close();
    await cipher.close();

    final other = await _open(engine, uid: 'user-2');
    await other.destroy();
    final deletes = keystore.calls.where((c) => c.method == 'delete').length;
    await other.close();
    expect(keystore.calls.where((c) => c.method == 'delete').length, deletes);
  });

  test('destroy after close still deletes the stored key', () async {
    final cipher = await _open(engine);
    await cipher.close();
    expect(keystore.stored, isNotEmpty);
    await cipher.destroy();
    expect(keystore.stored, isEmpty);
    expect(
      (keystore.calls.last.arguments as Map<Object?, Object?>)['alias'],
      vaultKeyAlias('user-1'),
    );
    await expectLater(cipher.destroy(), throwsStateError);
  });

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

  test('each unwrap error code maps to one outcome', () async {
    // no_key creates a key; key_lost is keyLost; everything else (Kotlin
    // answers unavailable after its own retry) is unavailable.
    final cases = <String, VaultKeyFailure>{
      'key_lost': VaultKeyFailure.keyLost,
      'unavailable': VaultKeyFailure.unavailable,
      'exists': VaultKeyFailure.unavailable, // never sent by unwrap
      'something_new': VaultKeyFailure.unavailable,
    };
    for (final c in cases.entries) {
      keystore.failUnwrap = c.key;
      keystore.calls.clear();
      await expectLater(_open(engine), _keyFailure(c.value), reason: c.key);
      expect(keystore.calls.map((m) => m.method), ['unwrap'], reason: c.key);
    }
    keystore.failUnwrap = null;
    final created = await _open(engine);
    expect(created.freshlyCreated, isTrue);
  });

  test(
    'wrap answering exists adopts the stored key, not the new one',
    () async {
      final theirs = Uint8List.fromList(List.generate(32, (i) => 200 - i));
      keystore.storeBeforeWrap = theirs;
      final cipher = await _open(engine);
      expect(cipher.freshlyCreated, isFalse);
      expect(keystore.calls.map((c) => c.method), ['unwrap', 'wrap', 'unwrap']);
      // The key we generated is not used, so it is zeroed.
      expect(engine.keys.single, everyElement(0));
      final sealed = await cipher.seal('messages', 'r1', _b('x'));
      expect(
        await FakeCryptoEngine().open(
          theirs,
          vaultRowAad('messages', 'r1'),
          sealed,
        ),
        _b('x'),
      );
    },
  );

  test(
    'exists then a failing unwrap is reported, never a memory-only key',
    () async {
      keystore.storeBeforeWrap = Uint8List(32);
      keystore.calls.clear();
      var unwraps = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) {
            if (call.method == 'unwrap' && ++unwraps == 2) {
              throw PlatformException(code: 'key_lost');
            }
            return keystore.handle(call);
          });
      await expectLater(_open(engine), _keyFailure(VaultKeyFailure.keyLost));
      expect(engine.keys.single, everyElement(0));
    },
  );

  test('two concurrent opens share one key; exactly one is fresh', () async {
    final gated = _GatedRandomEngine()..gate = Completer<void>();
    final a = _open(gated);
    final b = _open(gated);
    // Let both opens run as far as they can: the first waits in randomBytes.
    await pumpEventQueue();
    gated.gate!.complete();
    final ciphers = await Future.wait([a, b]);

    expect(gated.randomCalls, 1);
    expect(keystore.stored.length, 1);
    expect(ciphers.where((c) => c.freshlyCreated).length, 1);
    final sealed = await ciphers[0].seal('messages', 'r1', _b('shared'));
    expect(await ciphers[1].open('messages', 'r1', sealed), _b('shared'));
    final back = await ciphers[1].seal('messages', 'r2', _b('back'));
    expect(await ciphers[0].open('messages', 'r2', back), _b('back'));
  });

  test('a failed open does not block the next open of the same uid', () async {
    var unwraps = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) {
          if (call.method == 'unwrap' && ++unwraps == 1) {
            throw PlatformException(code: 'unavailable');
          }
          return keystore.handle(call);
        });
    final first = _open(engine);
    final second = _open(engine);
    await expectLater(first, _keyFailure(VaultKeyFailure.unavailable));
    expect((await second).freshlyCreated, isTrue);
  });

  test('destroy waits for a seal in flight before zeroing the key', () async {
    final late = _LateReadEngine();
    final cipher = await _open(late);
    late.sealGate = Completer<void>();
    final sealing = cipher.seal('messages', 'r1', _b('in flight'));
    await pumpEventQueue();
    var destroyed = false;
    final destroying = cipher.destroy().then((_) => destroyed = true);
    await pumpEventQueue();

    // New calls are refused at once; the key is still intact.
    await expectLater(cipher.seal('messages', 'r2', _b('x')), throwsStateError);
    expect(destroyed, isFalse);
    expect(late.keys.single, isNot(everyElement(0)));
    expect(keystore.calls.where((c) => c.method == 'delete'), isEmpty);

    late.sealGate!.complete();
    final sealed = await sealing;
    await destroying;
    expect(
      await FakeCryptoEngine().open(
        late.keySeenAtCall!,
        vaultRowAad('messages', 'r1'),
        sealed,
      ),
      _b('in flight'),
    );
    expect(late.keys.single, everyElement(0));
    expect(keystore.calls.last.method, 'delete');
  });

  test('an unwrapped key in a read-only channel buffer is copied, so destroy '
      'can zero it', () async {
    // On a device the engine hands the reply over in a read-only buffer, and
    // the decoded Uint8List is a view of it (found by the device run).
    await _open(engine); // stores a key
    const codec = StandardMethodCodec();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(_channel.name, (message) async {
          final call = codec.decodeMethodCall(message);
          final Object? value;
          try {
            value = await keystore.handle(call);
          } on PlatformException catch (e) {
            return codec
                .encodeErrorEnvelope(code: e.code, message: e.message)
                .asUnmodifiableView();
          }
          return codec.encodeSuccessEnvelope(value).asUnmodifiableView();
        });
    final cipher = await _open(engine);
    expect(cipher.freshlyCreated, isFalse);
    await cipher.destroy(); // threw "Cannot modify an unmodifiable list"
    keystore.unwrapOverride = Uint8List(16);
    await expectLater(_open(engine), _keyFailure(VaultKeyFailure.unavailable));
  });

  test('A-M3: destroy waits for a hung seal at most its bound, then zeroes '
      'and deletes; the late seal returns no result', () async {
    final late = _LateReadEngine();
    final cipher = await openIoVaultCipher(
      uid: 'user-1',
      engine: late,
      isAndroid: true,
      destroyWait: const Duration(milliseconds: 50),
    );
    late.sealGate = Completer<void>(); // never answers until released
    final sealing = cipher.seal('messages', 'r1', _b('in flight'));
    await pumpEventQueue();
    await cipher.destroy().timeout(const Duration(seconds: 5));
    expect(late.keys.single, everyElement(0));
    expect(keystore.calls.last.method, 'delete');
    late.sealGate!.complete();
    await expectLater(sealing, throwsStateError);
  });

  test('a late open that fails after destroy zeroed the key reports the '
      'cipher as destroyed, not an undecryptable row', () async {
    final late = _LateFailingOpenEngine();
    final cipher = await openIoVaultCipher(
      uid: 'user-1',
      engine: late,
      isAndroid: true,
      destroyWait: const Duration(milliseconds: 50),
    );
    late.openGate = Completer<void>();
    final opening = cipher.open('messages', 'r1', _b('sealed'));
    await pumpEventQueue();
    await cipher.destroy().timeout(const Duration(seconds: 5));
    late.openGate!.complete();
    await expectLater(opening, throwsStateError);
  });

  test('deleteVaultKey deletes the stored key without creating one', () async {
    await _open(engine);
    keystore.calls.clear();
    await deleteIoVaultKey(uid: 'user-1', isAndroid: true);
    expect(keystore.calls.map((c) => c.method), ['delete']);
    expect(
      (keystore.calls.single.arguments as Map<Object?, Object?>)['alias'],
      vaultKeyAlias('user-1'),
    );
    expect(keystore.stored, isEmpty);

    // Idempotent, and never wraps.
    await deleteIoVaultKey(uid: 'nobody', isAndroid: true);
    expect(keystore.calls.where((c) => c.method == 'wrap'), isEmpty);

    keystore.failDelete = 'unavailable';
    await expectLater(
      deleteIoVaultKey(uid: 'user-1', isAndroid: true),
      _keyFailure(VaultKeyFailure.unavailable),
    );
    // Off Android the failure is a failed Future, like the web, never a
    // synchronous throw.
    final offAndroid = deleteIoVaultKey(uid: 'user-1', isAndroid: false);
    await expectLater(offAndroid, throwsUnsupportedError);
    // The VM test host is never Android.
    final onHost = deleteVaultKey(uid: 'user-1');
    await expectLater(onHost, throwsUnsupportedError);
  });

  test(
    'deleteVaultKeyForAlias deletes the same key by alias (no uid '
    'needed); a string that is not an alias is refused, asynchronously',
    () async {
      await _open(engine);
      keystore.calls.clear();
      await deleteIoVaultKeyForAlias(
        alias: vaultKeyAlias('user-1'),
        isAndroid: true,
      );
      expect(keystore.calls.map((c) => c.method), ['delete']);
      expect(
        (keystore.calls.single.arguments as Map<Object?, Object?>)['alias'],
        vaultKeyAlias('user-1'),
      );
      expect(keystore.stored, isEmpty);
      for (final bad in ['user-1', 'dzeroth.vault.xyz', '']) {
        final refused = deleteVaultKeyForAlias(alias: bad);
        await expectLater(refused, throwsArgumentError, reason: bad);
      }
      expect(isVaultKeyAlias(vaultKeyAlias('anyone')), isTrue);
      expect(isVaultKeyAlias('anyone'), isFalse);
      final onHost = deleteVaultKeyForAlias(alias: vaultKeyAlias('user-1'));
      await expectLater(onHost, throwsUnsupportedError);
    },
  );

  test('the stub deleteVaultKey fails asynchronously', () async {
    final pending = stub.platformDeleteVaultKey('user-1');
    await expectLater(pending, throwsUnsupportedError);
    await expectLater(
      stub.platformDeleteVaultKeyForAlias(vaultKeyAlias('user-1')),
      throwsUnsupportedError,
    );
    expect(await stub.platformVaultStoragePersisted(), isFalse);
  });

  test('vaultStoragePersisted is true on Android, false elsewhere', () async {
    expect(await ioVaultStoragePersisted(isAndroid: true), isTrue);
    expect(await ioVaultStoragePersisted(isAndroid: false), isFalse);
    expect(await vaultStoragePersisted(), isFalse);
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

  test('a deadline from the engine is unavailable, not keyLost and not a row '
      'failure', () async {
    for (final code in [MlsErrorCode.deadline, MlsErrorCode.unavailable]) {
      final cipher = await _open(_DeadlineEngine(code));
      await expectLater(
        cipher.seal('messages', 'r1', _b('x')),
        _keyFailure(VaultKeyFailure.unavailable),
      );
      await expectLater(
        cipher.open('messages', 'r1', Uint8List(40)),
        _keyFailure(VaultKeyFailure.unavailable),
      );
    }
    // Opening with no stored key asks the engine for random bytes.
    final fresh = _DeadlineEngine(MlsErrorCode.deadline)..failRandom = true;
    await expectLater(
      _open(fresh, uid: 'user-fresh'),
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
