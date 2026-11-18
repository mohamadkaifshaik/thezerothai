// The vault cipher on a real platform key store. On an Android device:
//   cd app && flutter test integration_test/vault_cipher_test.dart -d <serial>
// In Chrome, JS and --wasm builds, with ChromeDriver on port 4455 (see
// crypto/README.md "Browser tests"; the driver also serves the MLS vectors,
// so MLS_VECTORS_PORT moves it off a busy 8089):
//   cd app && MLS_VECTORS_PORT=8095 flutter drive
//     --driver=test_driver/integration_test.dart
//     --target=integration_test/vault_cipher_test.dart -d web-server
//     --browser-name=chrome --driver-port=4455 --headless [--wasm]
// Groups are gated by platform; no dart:io import here, so it also compiles
// for the web.
import 'dart:convert';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/vault_platform.dart';

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

  // flutter drive reports only testWidgets results on the web, so this group
  // uses testWidgets (no widgets are pumped).
  group('WebCrypto vault key', skip: !kIsWeb, () {
    late CryptoEngine engine;
    late String uid;
    var serial = 0;
    final live = <VaultCipher>[];

    setUp(() {
      engine = createCryptoEngine();
      // A fresh uid per test (and per run), so reruns start clean.
      uid = 'vault-web-it-${DateTime.now().microsecondsSinceEpoch}-${serial++}';
    });

    tearDown(() async {
      for (final c in live) {
        try {
          await c.destroy();
        } on StateError {
          // Already destroyed by the test.
        }
      }
      live.clear();
      // Whatever the test left (a junk record, a key from a reopen).
      await deleteStoredVaultKey(uid);
      expect(await storedVaultKeyExists(uid), isFalse);
    });

    Future<VaultCipher> open() async {
      final c = await openVaultCipher(uid: uid, engine: engine);
      live.add(c);
      return c;
    }

    testWidgets('round trip; the nonce is fresh and random', (tester) async {
      final cipher = await open();
      expect(cipher.freshlyCreated, isTrue);
      final a = await cipher.seal('messages', 'r1', _b('hello'));
      final b = await cipher.seal('messages', 'r1', _b('hello'));
      expect(a.length, 5 + 12 + 16);
      expect(await cipher.open('messages', 'r1', a), _b('hello'));
      expect(await cipher.open('messages', 'r1', b), _b('hello'));
      // Two seals of one row differ in their nonce, which is not all zero.
      expect(a.sublist(0, 12), isNot(b.sublist(0, 12)));
      expect(a.sublist(0, 12).any((x) => x != 0), isTrue);
      expect(b.sublist(0, 12).any((x) => x != 0), isTrue);
      final empty = await cipher.seal('t', 'r', Uint8List(0));
      expect(await cipher.open('t', 'r', empty), isEmpty);
    });

    testWidgets('a row moved to another row or table, or altered, fails', (
      tester,
    ) async {
      final cipher = await open();
      final sealed = await cipher.seal('messages', 'r1', _b('pinned'));
      for (final (table, row) in [('messages', 'r2'), ('drafts', 'r1')]) {
        await expectLater(
          cipher.open(table, row, sealed),
          throwsA(isA<VaultRowException>()),
        );
      }
      final altered = Uint8List.fromList(sealed)..[20] ^= 1;
      await expectLater(
        cipher.open('messages', 'r1', altered),
        throwsA(isA<VaultRowException>()),
      );
      await expectLater(
        cipher.open('messages', 'r1', sealed.sublist(0, 27)),
        throwsA(isA<VaultRowException>()),
      );
      await expectLater(cipher.seal('a|b', 'r1', _b('x')), throwsArgumentError);
      await expectLater(
        cipher.seal('messages', 'r1', Uint8List(1024 * 1024 + 1)),
        throwsArgumentError,
      );
    });

    testWidgets('the stored key is non-extractable', (tester) async {
      await open();
      expect(await storedVaultKeyExists(uid), isTrue);
      expect(await storedVaultKeyExportRejects(uid), isTrue);
    });

    testWidgets('a reopen reads old rows and is not fresh', (tester) async {
      final first = await open();
      final sealed = await first.seal('messages', 'r1', _b('survives'));
      final second = await open();
      expect(second.freshlyCreated, isFalse);
      expect(await second.open('messages', 'r1', sealed), _b('survives'));
      final back = await second.seal('messages', 'r2', _b('back'));
      expect(await first.open('messages', 'r2', back), _b('back'));
    });

    testWidgets('a deleted record gives a fresh key; old rows fail', (
      tester,
    ) async {
      final first = await open();
      final sealed = await first.seal('messages', 'r1', _b('old'));
      await deleteStoredVaultKey(uid);
      final again = await open();
      expect(again.freshlyCreated, isTrue);
      await expectLater(
        again.open('messages', 'r1', sealed),
        throwsA(isA<VaultRowException>()),
      );
    });

    testWidgets('a stored record that is not a key is keyLost, and stays', (
      tester,
    ) async {
      await storeJunkVaultKey(uid);
      for (var i = 0; i < 2; i++) {
        // keyLost never replaces the record with a new key: a second open
        // still finds the same record.
        await expectLater(
          openVaultCipher(uid: uid, engine: engine),
          throwsA(
            isA<VaultKeyException>().having(
              (e) => e.failure,
              'failure',
              VaultKeyFailure.keyLost,
            ),
          ),
        );
      }
      expect(await storedVaultKeyExists(uid), isTrue);
    });

    testWidgets('two concurrent openers converge on one key', (tester) async {
      final both = await Future.wait([open(), open()]);
      expect(both.where((c) => c.freshlyCreated).length, 1);
      final [a, b] = both;
      final fromA = await a.seal('messages', 'r1', _b('a'));
      expect(await b.open('messages', 'r1', fromA), _b('a'));
      final fromB = await b.seal('messages', 'r2', _b('b'));
      expect(await a.open('messages', 'r2', fromB), _b('b'));
      final third = await open();
      expect(third.freshlyCreated, isFalse);
      expect(await third.open('messages', 'r1', fromA), _b('a'));
    });

    testWidgets('destroy deletes the record; later calls throw StateError', (
      tester,
    ) async {
      final cipher = await open();
      final sealed = await cipher.seal('messages', 'r1', _b('gone'));
      await cipher.destroy();
      expect(await storedVaultKeyExists(uid), isFalse);
      await expectLater(
        cipher.open('messages', 'r1', sealed),
        throwsStateError,
      );
      await expectLater(
        cipher.seal('messages', 'r1', _b('x')),
        throwsStateError,
      );
      await expectLater(cipher.destroy(), throwsStateError);

      final again = await open();
      expect(again.freshlyCreated, isTrue);
      await expectLater(
        again.open('messages', 'r1', sealed),
        throwsA(isA<VaultRowException>()),
      );
    });

    testWidgets('destroy waits for calls in flight; none gets a wrong result', (
      tester,
    ) async {
      final cipher = await open();
      final value = Uint8List.fromList(List.generate(4096, (i) => i & 0xff));
      final sealed = await cipher.seal('messages', 'r0', value);
      // A second cipher on the same key keeps it in memory after the record
      // is deleted, so it can check what the in-flight seals produced.
      final reader = await open();
      expect(reader.freshlyCreated, isFalse);
      // Started before destroy and not awaited yet.
      final seals = [
        for (var i = 0; i < 20; i++) cipher.seal('messages', 'r$i', value),
      ];
      final opens = [
        for (var i = 0; i < 20; i++) cipher.open('messages', 'r0', sealed),
      ];
      final destroyed = cipher.destroy();
      // Started after destroy: refused.
      await expectLater(cipher.seal('messages', 'x', value), throwsStateError);
      await expectLater(
        cipher.open('messages', 'r0', sealed),
        throwsStateError,
      );
      await destroyed;
      expect(await storedVaultKeyExists(uid), isFalse);
      for (var i = 0; i < seals.length; i++) {
        try {
          final out = await seals[i];
          expect(await reader.open('messages', 'r$i', out), value);
        } on StateError {
          // Refused, never a wrong result.
        }
      }
      for (final o in opens) {
        try {
          expect(await o, value);
        } on StateError {
          // Refused, never a wrong result.
        }
      }
    });

    testWidgets('200 seal + open of 1 KB values take under 2 s', (
      tester,
    ) async {
      final cipher = await open();
      final value = Uint8List.fromList(List.generate(1024, (i) => i & 0xff));
      final watch = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        final sealed = await cipher.seal('messages', 'row-$i', value);
        expect(await cipher.open('messages', 'row-$i', sealed), value);
      }
      watch.stop();
      debugPrint(
        'web vault 200 x 1 KB seal+open: ${watch.elapsedMilliseconds} ms',
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    testWidgets('storage persistence is asked for and answered as a bool', (
      tester,
    ) async {
      final cipher = await open();
      expect(webCipherPersisted(cipher), isA<bool>());
      expect(await webStoragePersisted(), isA<bool>());
    });
  });
}
