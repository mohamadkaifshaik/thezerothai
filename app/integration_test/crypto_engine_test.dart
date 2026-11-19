// Runs through `flutter drive` with the driver in test_driver/
// integration_test.dart, which serves the vectors file on port 8089 (see
// crypto/README.md). On web (real Chrome) it needs `make crypto-web` first; on
// an Android device it needs `adb reverse tcp:8089 tcp:8089` so the device's
// 127.0.0.1:8089 reaches the host. The same tests run against whichever engine
// createCryptoEngine() returns.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_engine_factory.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/crypto_platform.dart';

Uint8List _unhex(Object? value) {
  final s = value! as String;
  return Uint8List.fromList([
    for (var i = 0; i < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ]);
}

List<Uint8List> _unhexList(Object? value) => [
  for (final v in value! as List<dynamic>) _unhex(v),
];

Uint8List _bytes(int fill, int length) =>
    Uint8List.fromList(List.filled(length, fill));

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

Future<void> _fails(Future<Object?> future, MlsErrorCode code) async {
  try {
    await future;
  } on MlsException catch (e) {
    expect(e.code, code);
    return;
  }
  fail('expected MlsException ${code.wire}');
}

Future<Map<String, dynamic>> _loadVectors() async =>
    jsonDecode(await loadVectorsText()) as Map<String, dynamic>;

SecurityParty _party(Map<String, dynamic> p) => SecurityParty(
  userId: _unhex(p['user_id']),
  deviceKeys: _unhexList(p['device_keys']),
);

void _expectMembers(List<GroupMember> got, List<dynamic> want) {
  expect(got.length, want.length);
  for (var i = 0; i < want.length; i++) {
    final w = want[i] as Map<String, dynamic>;
    expect(got[i].deviceId, _unhex(w['device_id']));
    expect(got[i].signaturePublicKey, _unhex(w['signature_public_key']));
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Not setUp: a setUp that throws makes the web driver report "All tests
  // passed" without running anything.
  CryptoEngine newEngine() {
    final engine = createCryptoEngine();
    addTearDown(() => closeEngine(engine));
    return engine;
  }

  testWidgets('replays the frozen vectors, bytes made by Rust on the host', (
    tester,
  ) async {
    final engine = newEngine();
    final doc = await _loadVectors();
    final steps = doc['steps'] as List<dynamic>;
    var replayed = 0;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final input = step['in'] as Map<String, dynamic>;
      final out = step['out'] as Map<String, dynamic>;
      switch (step['op']) {
        case 'join_from_welcome':
          final j = await engine.joinFromWelcome(
            _unhex(input['device_state']),
            _unhex(input['welcome']),
          );
          expect(j.groupId, _unhex(out['group_id']), reason: 'step $i');
          expect(j.epoch, out['epoch'], reason: 'step $i');
          final info = await engine.describe(j.groupState);
          _expectMembers(info.members, out['members'] as List<dynamic>);
        case 'process':
          final call = engine.process(
            _unhex(input['device_state']),
            _unhex(input['group_state']),
            _unhex(input['wire']),
          );
          if (out.containsKey('error')) {
            await _fails(call, MlsErrorCode.parse(out['error'] as String));
            break;
          }
          final event = (await call).event;
          if (out['event'] == 'message') {
            final m = event as MlsMessageEvent;
            expect(m.plaintext, _unhex(out['plaintext']), reason: 'step $i');
            expect(
              m.senderDeviceId,
              _unhex(out['sender_device_id']),
              reason: 'step $i',
            );
          } else {
            final c = event as MlsCommitEvent;
            expect(c.epoch, out['epoch'], reason: 'step $i');
            expect(c.added, _unhexList(out['added']), reason: 'step $i');
            expect(c.removed, _unhexList(out['removed']), reason: 'step $i');
            expect(c.selfRemoved, out['self_removed'], reason: 'step $i');
          }
        case 'describe':
          final info = await engine.describe(_unhex(input['group_state']));
          expect(info.groupId, _unhex(out['group_id']), reason: 'step $i');
          expect(info.epoch, out['epoch'], reason: 'step $i');
          expect(
            info.hasPendingCommit,
            out['has_pending_commit'],
            reason: 'step $i',
          );
          _expectMembers(info.members, out['members'] as List<dynamic>);
        case 'wire_epoch':
          final call = engine.wireEpoch(_unhex(input['wire']));
          if (out.containsKey('error')) {
            await _fails(call, MlsErrorCode.parse(out['error'] as String));
          } else {
            expect(await call, out['epoch'], reason: 'step $i');
          }
        case 'security_code':
          expect(
            await engine.securityCode(
              _party(input['a'] as Map<String, dynamic>),
              _party(input['b'] as Map<String, dynamic>),
            ),
            out['code'],
            reason: 'step $i',
          );
        case 'create_device' ||
            'generate_key_packages' ||
            'create_group' ||
            'commit_change' ||
            'confirm_commit' ||
            'encrypt':
          continue;
        default:
          fail('step $i: unknown op ${step['op']}');
      }
      replayed++;
    }
    expect(replayed, greaterThan(20));

    // The final states say what the script left behind: the group id it used,
    // alice and carol at epoch 3 with only themselves as members, and bob
    // (removed by the commit that made epoch 3) on his own inactive state.
    // Every device state still loads. Mirrors crypto/dzmls/tests/vectors.rs.
    final finals = doc['final_states'] as Map<String, dynamic>;
    expect(finals, hasLength(3));
    final ids = doc['device_ids'] as Map<String, dynamic>;
    final aliceAndCarol = [_unhex(ids['alice']), _unhex(ids['carol'])];
    for (final (name, members) in [
      ('alice', aliceAndCarol),
      ('carol', aliceAndCarol),
      ('bob', null),
    ]) {
      final s = finals[name] as Map<String, dynamic>;
      final info = await engine.describe(_unhex(s['group_state']));
      expect(info.groupId, _bytes(0xAB, 32), reason: name);
      expect(info.epoch, 3, reason: name);
      expect(info.hasPendingCommit, isFalse, reason: name);
      if (members != null) {
        expect(
          [for (final m in info.members) m.deviceId],
          members,
          reason: name,
        );
      }
      final k = await engine.generateKeyPackages(
        _unhex(s['device_state']),
        count: 1,
        lastResort: false,
      );
      expect(k.keyPackages, hasLength(1), reason: name);
    }
  });

  testWidgets('three devices: add, message, add, message, remove, evicted', (
    tester,
  ) async {
    final engine = newEngine();
    final aliceId = _bytes(1, 16);
    final bobId = _bytes(2, 16);
    final carolId = _bytes(3, 16);
    final alice = await engine.createDevice(aliceId);
    final bob = await engine.createDevice(bobId);
    final carol = await engine.createDevice(carolId);
    expect(alice.signaturePublicKey, hasLength(32));

    final bobKp = await engine.generateKeyPackages(
      bob.deviceState,
      count: 1,
      lastResort: false,
    );
    final carolKp = await engine.generateKeyPackages(
      carol.deviceState,
      count: 1,
      lastResort: true,
    );
    expect(carolKp.keyPackages, hasLength(2));

    // The caller's buffer is still usable after a call.
    final gid = _bytes(0xAB, 32);
    var aliceGroup = await engine.createGroup(alice.deviceState, gid);
    expect(gid, everyElement(0xAB));
    expect(gid, hasLength(32));

    // Alice adds Bob.
    final c1 = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      addKeyPackages: [bobKp.keyPackages.single],
    );
    expect(c1.epoch, 0);
    expect((await engine.describe(c1.groupState)).hasPendingCommit, isTrue);
    aliceGroup = await engine.confirmCommit(alice.deviceState, c1.groupState);
    final bobJoin = await engine.joinFromWelcome(
      bobKp.deviceState,
      c1.welcome!,
    );
    var bobGroup = bobJoin.groupState;
    final bobDevice = bobJoin.deviceState;
    expect(bobJoin.epoch, 1);
    expect(bobJoin.groupId, gid);

    // Alice -> Bob.
    final m1 = await engine.encrypt(
      alice.deviceState,
      aliceGroup,
      _utf8('hello bob'),
    );
    aliceGroup = m1.groupState;
    final p1 = await engine.process(bobDevice, bobGroup, m1.ciphertext);
    bobGroup = p1.groupState;
    final e1 = p1.event as MlsMessageEvent;
    expect(utf8.decode(e1.plaintext), 'hello bob');
    expect(e1.senderDeviceId, aliceId);
    expect(await engine.wireEpoch(m1.ciphertext), 1);

    // Alice adds Carol; Bob processes the commit.
    final c2 = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      addKeyPackages: [carolKp.keyPackages.first],
    );
    aliceGroup = await engine.confirmCommit(alice.deviceState, c2.groupState);
    final p2 = await engine.process(bobDevice, bobGroup, c2.commit);
    bobGroup = p2.groupState;
    final e2 = p2.event as MlsCommitEvent;
    expect(e2.epoch, 2);
    expect(e2.added.single, carolId);
    expect(e2.selfRemoved, isFalse);
    final carolJoin = await engine.joinFromWelcome(
      carolKp.deviceState,
      c2.welcome!,
    );
    var carolGroup = carolJoin.groupState;
    final carolDevice = carolJoin.deviceState;

    // Bob -> Carol and Alice.
    final m2 = await engine.encrypt(bobDevice, bobGroup, _utf8('hi all'));
    bobGroup = m2.groupState;
    final pc = await engine.process(carolDevice, carolGroup, m2.ciphertext);
    carolGroup = pc.groupState;
    expect(utf8.decode((pc.event as MlsMessageEvent).plaintext), 'hi all');
    final pa = await engine.process(
      alice.deviceState,
      aliceGroup,
      m2.ciphertext,
    );
    aliceGroup = pa.groupState;
    expect(utf8.decode((pa.event as MlsMessageEvent).plaintext), 'hi all');

    // Alice removes Bob; Carol and Bob process the commit.
    final c3 = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      removeDeviceIds: [bobId],
    );
    expect(c3.welcome, isNull);
    aliceGroup = await engine.confirmCommit(alice.deviceState, c3.groupState);
    final pcarol = await engine.process(carolDevice, carolGroup, c3.commit);
    carolGroup = pcarol.groupState;
    expect((pcarol.event as MlsCommitEvent).removed.single, bobId);
    final pbob = await engine.process(bobDevice, bobGroup, c3.commit);
    bobGroup = pbob.groupState;
    expect((pbob.event as MlsCommitEvent).selfRemoved, isTrue);
    await _fails(
      engine.encrypt(bobDevice, bobGroup, _utf8('x')),
      MlsErrorCode.evicted,
    );

    final info = await engine.describe(aliceGroup);
    expect(info.epoch, 3);
    expect([for (final m in info.members) m.deviceId], [aliceId, carolId]);
  });

  testWidgets('self-update: confirm, process, then a message both ways', (
    tester,
  ) async {
    final engine = newEngine();
    final aliceId = _bytes(1, 16);
    final bobId = _bytes(2, 16);
    final alice = await engine.createDevice(aliceId);
    final bob = await engine.createDevice(bobId);
    final bobKp = await engine.generateKeyPackages(
      bob.deviceState,
      count: 1,
      lastResort: false,
    );
    var aliceGroup = await engine.createGroup(alice.deviceState, _bytes(9, 32));
    final add = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      addKeyPackages: [bobKp.keyPackages.single],
    );
    aliceGroup = await engine.confirmCommit(alice.deviceState, add.groupState);
    final joined = await engine.joinFromWelcome(
      bobKp.deviceState,
      add.welcome!,
    );
    final bobDevice = joined.deviceState;
    var bobGroup = joined.groupState;

    final update = await engine.selfUpdate(alice.deviceState, aliceGroup);
    expect(update.epoch, 1);
    expect(update.welcome, isNull);
    expect((await engine.describe(update.groupState)).hasPendingCommit, isTrue);
    await _fails(
      engine.selfUpdate(alice.deviceState, update.groupState),
      MlsErrorCode.pendingCommit,
    );
    aliceGroup = await engine.confirmCommit(
      alice.deviceState,
      update.groupState,
    );
    final aliceInfo = await engine.describe(aliceGroup);
    expect(aliceInfo.epoch, 2);
    expect(
      [for (final m in aliceInfo.members) m.signaturePublicKey],
      [alice.signaturePublicKey, bob.signaturePublicKey],
    );

    final p = await engine.process(bobDevice, bobGroup, update.commit);
    bobGroup = p.groupState;
    final event = p.event as MlsCommitEvent;
    expect(event.epoch, 2);
    expect(event.added, isEmpty);
    expect(event.removed, isEmpty);
    expect(event.selfRemoved, isFalse);

    final toBob = await engine.encrypt(
      alice.deviceState,
      aliceGroup,
      _utf8('renewed'),
    );
    aliceGroup = toBob.groupState;
    final got = await engine.process(bobDevice, bobGroup, toBob.ciphertext);
    bobGroup = got.groupState;
    expect(utf8.decode((got.event as MlsMessageEvent).plaintext), 'renewed');
    final toAlice = await engine.encrypt(bobDevice, bobGroup, _utf8('back'));
    final back = await engine.process(
      alice.deviceState,
      aliceGroup,
      toAlice.ciphertext,
    );
    final m = back.event as MlsMessageEvent;
    expect(utf8.decode(m.plaintext), 'back');
    expect(m.senderDeviceId, bobId);
  });

  testWidgets('inspect + commit fields + own leaf', (tester) async {
    final engine = newEngine();
    final aliceId = _bytes(1, 16);
    final bobId = _bytes(2, 16);
    final carolId = _bytes(3, 16);
    final alice = await engine.createDevice(aliceId);
    final bob = await engine.createDevice(bobId);
    final carol = await engine.createDevice(carolId);
    final bobKp = await engine.generateKeyPackages(
      bob.deviceState,
      count: 1,
      lastResort: true,
    );
    final carolKp = await engine.generateKeyPackages(
      carol.deviceState,
      count: 1,
      lastResort: false,
    );

    // Inspection: one-time and last-resort, no state needed.
    for (final p in bobKp.keyPackages) {
      final info = await engine.inspectKeyPackage(p);
      expect(info.deviceId, bobId);
      expect(info.signaturePublicKey, bob.signaturePublicKey);
    }
    final flipped = Uint8List.fromList(bobKp.keyPackages.first);
    flipped[flipped.length - 1] ^= 0x01;
    await _fails(engine.inspectKeyPackage(flipped), MlsErrorCode.badInput);
    await _fails(
      engine.inspectKeyPackage(Uint8List(65537)),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.inspectKeyPackage(Uint8List.fromList([1, 2, 3])),
      MlsErrorCode.badInput,
    );

    var aliceGroup = await engine.createGroup(alice.deviceState, _bytes(7, 32));
    final c1 = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      addKeyPackages: [bobKp.keyPackages.first],
    );
    await _fails(engine.inspectKeyPackage(c1.welcome!), MlsErrorCode.badInput);
    // Own commit while pending is ownLeaf.
    await _fails(
      engine.process(alice.deviceState, c1.groupState, c1.commit),
      MlsErrorCode.ownLeaf,
    );
    aliceGroup = await engine.confirmCommit(alice.deviceState, c1.groupState);
    final bobJoin = await engine.joinFromWelcome(bob.deviceState, c1.welcome!);

    // Own echo of an application message is ownLeaf; a peer replay is not.
    final m = await engine.encrypt(
      alice.deviceState,
      aliceGroup,
      _utf8('mine'),
    );
    await _fails(
      engine.process(alice.deviceState, m.groupState, m.ciphertext),
      MlsErrorCode.ownLeaf,
    );
    final got = await engine.process(
      bob.deviceState,
      bobJoin.groupState,
      m.ciphertext,
    );
    await _fails(
      engine.process(bob.deviceState, got.groupState, m.ciphertext),
      MlsErrorCode.duplicate,
    );
    aliceGroup = m.groupState;

    // Commit attribution.
    final c2 = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      addKeyPackages: [carolKp.keyPackages.single],
    );
    final p2 = await engine.process(bob.deviceState, got.groupState, c2.commit);
    final e2 = p2.event as MlsCommitEvent;
    expect(e2.committerDeviceId, aliceId);
    expect(e2.added, [carolId]);
    expect(e2.addedSignatureKeys, [carol.signaturePublicKey]);
    final after = await engine.describe(p2.groupState);
    expect([
      for (final x in after.members) x.signaturePublicKey,
    ], containsAll(e2.addedSignatureKeys));
    aliceGroup = await engine.confirmCommit(alice.deviceState, c2.groupState);

    // The own self-update commit is ownLeaf; a remove-only commit has no keys.
    final su = await engine.selfUpdate(alice.deviceState, aliceGroup);
    await _fails(
      engine.process(alice.deviceState, su.groupState, su.commit),
      MlsErrorCode.ownLeaf,
    );
    await engine.discardCommit(alice.deviceState, su.groupState);
    final rm = await engine.commitChange(
      alice.deviceState,
      aliceGroup,
      removeDeviceIds: [carolId],
    );
    final p3 = await engine.process(bob.deviceState, p2.groupState, rm.commit);
    final e3 = p3.event as MlsCommitEvent;
    expect(e3.committerDeviceId, aliceId);
    expect(e3.addedSignatureKeys, isEmpty);
    expect(e3.removed, [carolId]);
  });

  testWidgets('garbage input fails with an MlsException', (tester) async {
    final engine = newEngine();
    final garbage = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
    await _fails(engine.wireEpoch(garbage), MlsErrorCode.badInput);
    await _fails(engine.describe(garbage), MlsErrorCode.corruptState);
    final device = await engine.createDevice(_bytes(1, 16));
    final group = await engine.createGroup(device.deviceState, _bytes(9, 32));
    await _fails(
      engine.process(device.deviceState, group, garbage),
      MlsErrorCode.badInput,
    );
    await _fails(engine.createDevice(_bytes(1, 3)), MlsErrorCode.badInput);
  });

  testWidgets('seal and open round-trip under a random key', (tester) async {
    final engine = newEngine();
    final key = await engine.randomBytes(32);
    expect(key.length, 32);
    expect(await engine.randomBytes(32), isNot(key));
    final aad = _utf8('messages:row-1');
    final plaintext = _utf8('in the vault');
    final sealed = await engine.seal(key, aad, plaintext);
    expect(sealed.length, plaintext.length + 28);
    expect(await engine.seal(key, aad, plaintext), isNot(sealed));
    expect(await engine.open(key, aad, sealed), plaintext);
    await _fails(
      engine.open(key, _utf8('messages:row-2'), sealed),
      MlsErrorCode.badInput,
    );
    await _fails(engine.randomBytes(65), MlsErrorCode.badInput);
  });

  testWidgets('a 1 MiB value seals and opens', (tester) async {
    final engine = newEngine();
    final key = await engine.randomBytes(32);
    final aad = _utf8('messages:row-big');
    final plaintext = Uint8List.fromList(
      List.generate(1048576, (i) => (i * 31) & 0xff),
    );
    final watch = Stopwatch()..start();
    final sealed = await engine.seal(key, aad, plaintext);
    final sealMs = watch.elapsedMilliseconds;
    expect(sealed.length, 1048576 + 28);
    final opened = await engine.open(key, aad, sealed);
    watch.stop();
    expect(opened, plaintext);
    final openMs = watch.elapsedMilliseconds - sealMs;
    // The device log shows the print; on the web the driver saves reportData
    // to build/integration_response_data.json.
    binding.reportData = {
      ...?binding.reportData,
      'seal1MiB': {'sealMs': sealMs, 'openMs': openMs},
    };
    // ignore: avoid_print
    print('SEAL1MIB sealMs=$sealMs openMs=$openMs');
  });

  testWidgets('open with a wrong key fails with badInput', (tester) async {
    final engine = newEngine();
    final key = await engine.randomBytes(32);
    final aad = _utf8('messages:row-1');
    final sealed = await engine.seal(key, aad, _utf8('in the vault'));
    final wrong = Uint8List.fromList(key)..[0] ^= 0x01;
    await _fails(engine.open(wrong, aad, sealed), MlsErrorCode.badInput);
  });

  testWidgets('opens the known-answer value from crypto/dzmls/tests/seal.rs', (
    tester,
  ) async {
    // Sealed by Node's crypto (OpenSSL), nonce a0..ab: checks this platform's
    // AES-GCM backend (software AES on arm and wasm) against another
    // implementation.
    final engine = newEngine();
    final key = _unhex(
      '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f',
    );
    final aad = _unhex('647a76313a6d657373616765733a726f772d3432');
    final sealed = _unhex(
      'a0a1a2a3a4a5a6a7a8a9aaab957d1d4120af22d90d17a7a76f1fe0a811d935644bdeda'
      '484ce25b8360a64f1b39e51a84',
    );
    final plaintext = _unhex('7365616c656420666f7220746865207661756c74');
    expect(await engine.open(key, aad, sealed), plaintext);
    expect(utf8.decode(plaintext), 'sealed for the vault');
  });

  testWidgets('50 encrypt calls complete while frames keep coming', (
    tester,
  ) async {
    final engine = newEngine();
    final alice = await engine.createDevice(_bytes(1, 16));
    var group = await engine.createGroup(alice.deviceState, _bytes(9, 32));
    final bob = await engine.createDevice(_bytes(2, 16));
    final kp = await engine.generateKeyPackages(
      bob.deviceState,
      count: 1,
      lastResort: false,
    );
    final c = await engine.commitChange(
      alice.deviceState,
      group,
      addKeyPackages: [kp.keyPackages.single],
    );
    group = await engine.confirmCommit(alice.deviceState, c.groupState);

    // Real frames, not only the ones the test pumps.
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    var frames = 0;
    var maxGapMicros = 0;
    var lastTick = Duration.zero;
    final firstFrame = Completer<void>();
    final ticker = Ticker((elapsed) {
      frames++;
      if (firstFrame.isCompleted) {
        final gap = (elapsed - lastTick).inMicroseconds;
        if (gap > maxGapMicros) maxGapMicros = gap;
      } else {
        firstFrame.complete();
      }
      lastTick = elapsed;
    })..start();
    await firstFrame.future.timeout(const Duration(seconds: 10));
    frames = 0;

    final watch = Stopwatch()..start();
    final plaintext = _utf8('the quick brown fox' * 20);
    for (var i = 0; i < 50; i++) {
      final r = await engine.encrypt(alice.deviceState, group, plaintext);
      group = r.groupState;
      expect(r.ciphertext, isNotEmpty);
    }
    final fiftyMs = watch.elapsedMilliseconds;
    // 50 calls finish in a few dozen milliseconds, shorter than a handful of
    // frames, so keep the engine busy for a full second to measure frames.
    while (watch.elapsedMilliseconds < 1000) {
      group = (await engine.encrypt(
        alice.deviceState,
        group,
        plaintext,
      )).groupState;
    }
    watch.stop();
    ticker.dispose();

    // ignore: avoid_print
    print(
      'ENCRYPT fiftyMs=$fiftyMs windowMs=${watch.elapsedMilliseconds} '
      'frames=$frames maxFrameGapMs=${maxGapMicros ~/ 1000}',
    );
    expect(frames, greaterThan(5), reason: 'frames kept coming');
    // Generous on purpose: this proves the engine does not freeze the UI thread, it is not a benchmark of a shared CI runner.
    const maxFrameGapMicros = 1000 * 1000;
    expect(
      maxGapMicros,
      lessThanOrEqualTo(maxFrameGapMicros),
      reason: 'a frame at least every second while the engine runs',
    );
  });

  // Flutter's own dev server sends COOP/COEP headers for --wasm builds, so the
  // page is isolated there; the hosting config sends neither, and the engine
  // does not depend on isolation either way.
  testWidgets('the page is not cross-origin isolated', (tester) async {
    final isolated = crossOriginIsolated;
    if (isolated == null) {
      markTestSkipped('web only');
      return;
    }
    if (const bool.fromEnvironment('dart.tool.dart2wasm')) {
      markTestSkipped('the wasm dev server sends COOP/COEP');
      return;
    }
    expect(isolated, isFalse);
  });
}
