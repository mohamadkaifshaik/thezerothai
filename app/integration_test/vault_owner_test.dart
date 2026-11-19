// Single-tab vault ownership on a real browser's Web Locks. In Chrome, JS and
// --wasm builds, with ChromeDriver on a free port (see crypto/README.md
// "Browser tests"; the driver also serves the MLS vectors, so MLS_VECTORS_PORT
// moves it off a busy 8089):
//   cd app && MLS_VECTORS_PORT=8095 flutter drive
//     --driver=test_driver/integration_test.dart
//     --target=integration_test/vault_owner_test.dart -d web-server
//     --browser-name=chrome --driver-port=<port> --headless [--wasm]
// The group is skipped off the web. Assertions are in the test bodies:
// flutter drive does not report a failure in setUp or tearDown.
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/web_lock_platform.dart';

const _wait = Duration(seconds: 10);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Web Lock vault ownership', skip: !kIsWeb, () {
    late VaultOwner owner;
    late String uid;
    late String name;
    var serial = 0;
    final raw = <RawLockHolder>[];

    setUp(() {
      owner = createVaultOwner();
      // A fresh uid per test: every test shares one page and one lock table.
      uid = 'vault-owner-${DateTime.now().microsecondsSinceEpoch}-${serial++}';
      name = vaultLockName(uid);
    });

    tearDown(() async {
      // Cleanup only (assertions are in the test bodies).
      try {
        await owner.release().timeout(_wait);
      } on Object {
        // Nothing to release.
      }
      for (final h in raw) {
        try {
          await h.release().timeout(_wait);
        } on Object {
          // Already released.
        }
      }
      raw.clear();
    });

    Future<RawLockHolder?> rawRequest({
      bool ifAvailable = false,
      bool steal = false,
    }) async {
      final h = await rawLockRequest(
        name,
        ifAvailable: ifAvailable,
        steal: steal,
      ).timeout(_wait);
      if (h != null) raw.add(h);
      return h;
    }

    testWidgets('the lock name is built from the vault key alias', (
      tester,
    ) async {
      expect(name, startsWith('dzeroth-vault-dzeroth.vault.'));
      expect(owner.supported, isTrue);
    });

    testWidgets('acquire takes a free lock', (tester) async {
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
    });

    testWidgets('another holder is refused while owned, and gets it after', (
      tester,
    ) async {
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
      expect(await rawRequest(ifAvailable: true), isNull);
      await owner.release().timeout(_wait);
      final other = await rawRequest(ifAvailable: true);
      expect(other, isNotNull);
    });

    testWidgets('acquire is refused while another holder has it', (
      tester,
    ) async {
      final other = await rawRequest(ifAvailable: true);
      expect(other, isNotNull);
      expect(await owner.acquire(uid).timeout(_wait), isFalse);
      // A refused owner holds nothing; a second try is a fresh request.
      expect(await owner.acquire(uid).timeout(_wait), isFalse);
      await other!.release().timeout(_wait);
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
    });

    testWidgets('a second acquire for the same uid is true without asking', (
      tester,
    ) async {
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
      // A second request would be refused by our own hold: true proves none.
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
    });

    testWidgets('acquire for another uid while owning throws StateError', (
      tester,
    ) async {
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
      expect(() => owner.acquire('$uid-other'), throwsStateError);
      await owner.release().timeout(_wait);
      expect(await owner.acquire('$uid-other').timeout(_wait), isTrue);
    });

    testWidgets('two concurrent acquires for one uid share one request', (
      tester,
    ) async {
      final both = await Future.wait([owner.acquire(uid), owner.acquire(uid)])
          .timeout(_wait);
      expect(both, [true, true]);
    });

    testWidgets('release when not owning is a no-op', (tester) async {
      await owner.release().timeout(_wait);
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
      await owner.release().timeout(_wait);
      await owner.release().timeout(_wait);
    });

    testWidgets('lost fires when another context steals the lock', (
      tester,
    ) async {
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
      final lost = owner.lost.first.timeout(_wait);
      final thief = await rawRequest(steal: true);
      expect(thief, isNotNull);
      await lost;
      // The owner treats the lock as gone: a new attempt is a new request,
      // refused while the thief holds it, granted after.
      expect(await owner.acquire(uid).timeout(_wait), isFalse);
      await thief!.release().timeout(_wait);
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
    });

    testWidgets('lost does not fire on a normal release', (tester) async {
      var lost = 0;
      final sub = owner.lost.listen((_) => lost++);
      expect(await owner.acquire(uid).timeout(_wait), isTrue);
      await owner.release().timeout(_wait);
      final other = await rawRequest(ifAvailable: true);
      expect(other, isNotNull);
      await other!.release().timeout(_wait);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(lost, 0);
      await sub.cancel();
    });
  });
}
