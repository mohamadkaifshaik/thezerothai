// The vault cipher on a real platform key store. On an Android device:
//   cd app && flutter test integration_test/vault_cipher_test.dart -d <serial>
// Groups are gated by platform so the web cases (a later task) join this file;
// no dart:io import here, so it also compiles for the web.
import 'dart:convert';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final bool _isAndroid =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Android Keystore vault key', skip: !_isAndroid, () {
    late CryptoEngine engine;
    late String uid;
    VaultCipher? live;

    setUp(() {
      engine = createCryptoEngine();
      // A fresh uid per test (and per run), so reruns start clean.
      uid = 'vault-it-${DateTime.now().microsecondsSinceEpoch}';
    });

    tearDown(() async {
      // Remove this test's Keystore key and stored value.
      final c = live ?? await openVaultCipher(uid: uid, engine: engine);
      live = null;
      try {
        await c.destroy();
      } on StateError {
        // Already destroyed by the test.
      }
    });

    test('a key survives a restart (a second open in the same run)', () async {
      final first = await openVaultCipher(uid: uid, engine: engine);
      expect(first.freshlyCreated, isTrue);
      final sealed = await first.seal('messages', 'r1', _b('survives'));

      // Drop the in-memory cipher as an app restart would, then reopen.
      final second = await openVaultCipher(uid: uid, engine: engine);
      live = second;
      expect(second.freshlyCreated, isFalse);
      expect(await second.open('messages', 'r1', sealed), _b('survives'));
      await expectLater(
        second.open('messages', 'r2', sealed),
        throwsA(isA<VaultRowException>()),
      );
    });

    test('200 seal + open of 1 KB values take under 2 s', () async {
      final cipher = await openVaultCipher(uid: uid, engine: engine);
      live = cipher;
      final value = Uint8List.fromList(List.generate(1024, (i) => i & 0xff));
      final watch = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        final sealed = await cipher.seal('messages', 'row-$i', value);
        expect(await cipher.open('messages', 'row-$i', sealed), value);
      }
      watch.stop();
      debugPrint('vault 200 x 1 KB seal+open: ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('destroy deletes the key; a reopen makes a new one', () async {
      final cipher = await openVaultCipher(uid: uid, engine: engine);
      final sealed = await cipher.seal('messages', 'r1', _b('gone'));
      await cipher.destroy();
      await expectLater(
        cipher.open('messages', 'r1', sealed),
        throwsStateError,
      );

      final again = await openVaultCipher(uid: uid, engine: engine);
      live = again;
      expect(again.freshlyCreated, isTrue);
      await expectLater(
        again.open('messages', 'r1', sealed),
        throwsA(isA<VaultRowException>()),
      );
    });
  });
}
