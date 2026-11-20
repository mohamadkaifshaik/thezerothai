import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_crypto_engine.dart';

Uint8List _bytes(int fill, int length) =>
    Uint8List.fromList(List.filled(length, fill));

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// Expects [future] to fail with an [MlsException] carrying [code].
Future<void> _fails(Future<Object?> future, MlsErrorCode code) async {
  try {
    await future;
  } on MlsException catch (e) {
    expect(e.code, code);
    return;
  }
  fail('expected MlsException ${code.wire}');
}

/// [bytes] with the first length-prefixed 16-byte id [from] replaced by [to]:
/// a hostile peer's edit of a wire message.
Uint8List _swapId(Uint8List bytes, Uint8List from, Uint8List to) {
  final needle = [0, 0, 0, from.length, ...from];
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length && hit; j++) {
      hit = bytes[i + j] == needle[j];
    }
    if (hit) {
      return Uint8List.fromList(bytes)..setRange(i + 4, i + 4 + to.length, to);
    }
  }
  throw StateError('id not found');
}

class _Dev {
  _Dev(this.id, this.state, this.signatureKey);

  final Uint8List id;
  Uint8List state;
  final Uint8List signatureKey;
}

void main() {
  late FakeCryptoEngine engine;

  setUp(() => engine = FakeCryptoEngine());

  Future<_Dev> device(int n) async {
    final id = _bytes(n, 16);
    final created = await engine.createDevice(id);
    return _Dev(id, created.deviceState, created.signaturePublicKey);
  }

  Future<Uint8List> keyPackage(_Dev dev) async {
    final r = await engine.generateKeyPackages(
      dev.state,
      count: 1,
      lastResort: false,
    );
    dev.state = r.deviceState;
    return r.keyPackages.single;
  }

  /// Creates a group with [creator] and joins [others] one commit at a time.
  /// Returns the group state of each, creator first.
  Future<List<Uint8List>> groupOf(
    _Dev creator,
    List<_Dev> others,
    Uint8List groupId,
  ) async {
    var state = await engine.createGroup(creator.state, groupId);
    final joined = <Uint8List>[];
    for (final other in others) {
      final c = await engine.commitChange(
        creator.state,
        state,
        addKeyPackages: [await keyPackage(other)],
      );
      state = await engine.confirmCommit(creator.state, c.groupState);
      final j = await engine.joinFromWelcome(other.state, c.welcome!);
      other.state = j.deviceState;
      joined.add(j.groupState);
    }
    return [state, ...joined];
  }

  test('add, confirm and join agree on epoch and members', () async {
    final alice = await device(1);
    final bob = await device(2);
    final gid = _bytes(0xA1, 32);
    final g = await engine.createGroup(alice.state, gid);
    final c = await engine.commitChange(
      alice.state,
      g,
      addKeyPackages: [await keyPackage(bob)],
    );
    expect(c.epoch, 0);
    expect(c.welcome, isNotNull);
    expect((await engine.describe(c.groupState)).hasPendingCommit, isTrue);

    final a1 = await engine.confirmCommit(alice.state, c.groupState);
    final aliceInfo = await engine.describe(a1);
    expect(aliceInfo.epoch, 1);
    expect(aliceInfo.hasPendingCommit, isFalse);

    final j = await engine.joinFromWelcome(bob.state, c.welcome!);
    expect(j.epoch, 1);
    expect(j.groupId, gid);
    final bobInfo = await engine.describe(j.groupState);
    expect(bobInfo.epoch, 1);
    expect(bobInfo.groupId, gid);
    final both = [alice.id, bob.id];
    expect([for (final m in aliceInfo.members) m.deviceId], both);
    expect([for (final m in bobInfo.members) m.deviceId], both);
    expect(aliceInfo.members.first.signaturePublicKey, alice.signatureKey);
    expect(bobInfo.members.last.signaturePublicKey, bob.signatureKey);
  });

  test('a message round-trips with the sender device id', () async {
    final alice = await device(1);
    final bob = await device(2);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final plaintext = _utf8('hello bob');
    final sent = await engine.encrypt(alice.state, states[0], plaintext);
    expect(sent.epoch, 1);
    final p = await engine.process(bob.state, states[1], sent.ciphertext);
    final event = p.event as MlsMessageEvent;
    expect(event.plaintext, plaintext);
    expect(event.senderDeviceId, alice.id);
    expect(await engine.wireEpoch(sent.ciphertext), 1);
  });

  test(
    'a second commit or a message while one is pending is refused',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final carol = await device(3);
      final g = await engine.createGroup(alice.state, _bytes(0xA1, 32));
      final c = await engine.commitChange(
        alice.state,
        g,
        addKeyPackages: [await keyPackage(bob)],
      );
      await _fails(
        engine.commitChange(
          alice.state,
          c.groupState,
          addKeyPackages: [await keyPackage(carol)],
        ),
        MlsErrorCode.pendingCommit,
      );
      await _fails(
        engine.encrypt(alice.state, c.groupState, _utf8('x')),
        MlsErrorCode.pendingCommit,
      );
      await _fails(
        engine.confirmCommit(alice.state, g),
        MlsErrorCode.noPendingCommit,
      );
      await _fails(
        engine.discardCommit(alice.state, g),
        MlsErrorCode.noPendingCommit,
      );
    },
  );

  test(
    'racing commits: the loser discards, processes the winner and retries',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final carol = await device(3);
      final dave = await device(4);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));

      final carolKp = await keyPackage(carol);
      final daveKp = await keyPackage(dave);
      final ca = await engine.commitChange(
        alice.state,
        states[0],
        addKeyPackages: [carolKp],
      );
      final cb = await engine.commitChange(
        bob.state,
        states[1],
        addKeyPackages: [daveKp],
      );
      expect(ca.epoch, 1);
      expect(cb.epoch, 1);

      // The server accepts alice's commit and refuses bob's.
      final a2 = await engine.confirmCommit(alice.state, ca.groupState);
      expect((await engine.describe(a2)).epoch, 2);
      final b1 = await engine.discardCommit(bob.state, cb.groupState);
      final p = await engine.process(bob.state, b1, ca.commit);
      expect((await engine.describe(p.groupState)).epoch, 2);
      final event = p.event as MlsCommitEvent;
      expect(event.epoch, 2);
      expect(event.added.single, carol.id);
      expect(event.selfRemoved, isFalse);

      final retry = await engine.commitChange(
        bob.state,
        p.groupState,
        addKeyPackages: [daveKp],
      );
      expect(retry.epoch, 2);
    },
  );

  test(
    'a removed member sees selfRemoved, then every call is evicted',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final c = await engine.commitChange(
        alice.state,
        states[0],
        removeDeviceIds: [bob.id],
      );
      expect(c.welcome, isNull);
      final p = await engine.process(bob.state, states[1], c.commit);
      final event = p.event as MlsCommitEvent;
      expect(event.selfRemoved, isTrue);
      expect(event.removed.single, bob.id);

      await _fails(
        engine.encrypt(bob.state, p.groupState, _utf8('x')),
        MlsErrorCode.evicted,
      );
      await _fails(
        engine.process(bob.state, p.groupState, c.commit),
        MlsErrorCode.evicted,
      );
      await _fails(
        engine.commitChange(
          bob.state,
          p.groupState,
          addKeyPackages: [await keyPackage(await device(3))],
        ),
        MlsErrorCode.evicted,
      );
    },
  );

  test('a message from before the device joined is wrongEpoch', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final early = await engine.encrypt(alice.state, states[0], _utf8('old'));

    final c = await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [await keyPackage(carol)],
    );
    final a2 = await engine.confirmCommit(alice.state, c.groupState);
    final j = await engine.joinFromWelcome(carol.state, c.welcome!);
    await _fails(
      engine.process(carol.state, j.groupState, early.ciphertext),
      MlsErrorCode.wrongEpoch,
    );
    // A message from a later epoch is wrongEpoch for a member still behind.
    final late = await engine.encrypt(alice.state, a2, _utf8('new'));
    await _fails(
      engine.process(bob.state, states[1], late.ciphertext),
      MlsErrorCode.wrongEpoch,
    );
  });

  test('a replayed peer message is duplicate', () async {
    final alice = await device(1);
    final bob = await device(2);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final sent = await engine.encrypt(alice.state, states[0], _utf8('once'));
    final p = await engine.process(bob.state, states[1], sent.ciphertext);
    await _fails(
      engine.process(bob.state, p.groupState, sent.ciphertext),
      MlsErrorCode.duplicate,
    );
  });

  test('own echo is ownLeaf, not duplicate', () async {
    final alice = await device(1);
    final bob = await device(2);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final sent = await engine.encrypt(alice.state, states[0], _utf8('mine'));
    await _fails(
      engine.process(alice.state, sent.groupState, sent.ciphertext),
      MlsErrorCode.ownLeaf,
    );
  });

  test('an own commit is ownLeaf while pending and after a discard', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final c = await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [await keyPackage(carol)],
    );
    await _fails(
      engine.process(alice.state, c.groupState, c.commit),
      MlsErrorCode.ownLeaf,
    );
    final discarded = await engine.discardCommit(alice.state, c.groupState);
    await _fails(
      engine.process(alice.state, discarded, c.commit),
      MlsErrorCode.ownLeaf,
    );
  });

  test(
    'an own commit after confirm is wrongEpoch (epoch is checked first)',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final carol = await device(3);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final c = await engine.commitChange(
        alice.state,
        states[0],
        addKeyPackages: [await keyPackage(carol)],
      );
      final confirmed = await engine.confirmCommit(alice.state, c.groupState);
      await _fails(
        engine.process(alice.state, confirmed, c.commit),
        MlsErrorCode.wrongEpoch,
      );
    },
  );

  test('the own self-update commit is ownLeaf', () async {
    final alice = await device(1);
    final bob = await device(2);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final c = await engine.selfUpdate(alice.state, states[0]);
    await _fails(
      engine.process(alice.state, c.groupState, c.commit),
      MlsErrorCode.ownLeaf,
    );
  });

  test('inspectKeyPackage reads one-time and last-resort packages', () async {
    final alice = await device(1);
    final r = await engine.generateKeyPackages(
      alice.state,
      count: 1,
      lastResort: true,
    );
    expect(r.keyPackages, hasLength(2));
    for (final p in r.keyPackages) {
      final info = await engine.inspectKeyPackage(p);
      expect(info.deviceId, alice.id);
      expect(info.signaturePublicKey, alice.signatureKey);
    }
  });

  test(
    'inspectKeyPackage refuses damage, oversize, a welcome and garbage',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final kp = await keyPackage(bob);
      // The fake has no signature, so damage is a broken header, not any byte.
      final broken = Uint8List.fromList(kp)..[0] ^= 0xFF;
      await _fails(engine.inspectKeyPackage(broken), MlsErrorCode.badInput);
      await _fails(
        engine.inspectKeyPackage(Uint8List(65537)),
        MlsErrorCode.badInput,
      );
      await _fails(
        engine.inspectKeyPackage(_bytes(7, 5)),
        MlsErrorCode.badInput,
      );
      await _fails(
        engine.inspectKeyPackage(Uint8List(0)),
        MlsErrorCode.badInput,
      );
      final g = await engine.createGroup(alice.state, _bytes(0xA1, 32));
      final c = await engine.commitChange(alice.state, g, addKeyPackages: [kp]);
      await _fails(engine.inspectKeyPackage(c.welcome!), MlsErrorCode.badInput);
    },
  );

  test('a flipped last byte is badInput on the fake', () async {
    final bob = await device(2);
    final kp = await keyPackage(bob);
    final flipped = Uint8List.fromList(kp)..[kp.length - 1] ^= 0xFF;
    await _fails(engine.inspectKeyPackage(flipped), MlsErrorCode.badInput);
  });

  test('inspecting a key package changes nothing: it still joins', () async {
    final alice = await device(1);
    final bob = await device(2);
    final kp = await keyPackage(bob);
    final a = await engine.inspectKeyPackage(kp);
    final b = await engine.inspectKeyPackage(kp);
    expect(a.deviceId, b.deviceId);
    final g = await engine.createGroup(alice.state, _bytes(0xA1, 32));
    final c = await engine.commitChange(alice.state, g, addKeyPackages: [kp]);
    final j = await engine.joinFromWelcome(bob.state, c.welcome!);
    expect(j.epoch, 1);
  });

  test('a commit event names the committer and the added keys', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final c = await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [await keyPackage(carol)],
    );
    final p = await engine.process(bob.state, states[1], c.commit);
    final e = p.event as MlsCommitEvent;
    expect(e.committerDeviceId, alice.id);
    expect(e.added, [carol.id]);
    expect(e.addedSignatureKeys, [carol.signatureKey]);
    final after = await engine.describe(p.groupState);
    expect(after.members.last.signaturePublicKey, e.addedSignatureKeys.single);

    // A remove-only commit adds no keys.
    final a2 = await engine.confirmCommit(alice.state, c.groupState);
    final r = await engine.commitChange(
      alice.state,
      a2,
      removeDeviceIds: [bob.id],
    );
    final p2 = await engine.process(bob.state, p.groupState, r.commit);
    final e2 = p2.event as MlsCommitEvent;
    expect(e2.committerDeviceId, alice.id);
    expect(e2.added, isEmpty);
    expect(e2.addedSignatureKeys, isEmpty);
    expect(e2.removed, [bob.id]);
  });

  test(
    'reprocessing from the old state succeeds again with the same result',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final sent = await engine.encrypt(alice.state, states[0], _utf8('again'));
      final first = await engine.process(bob.state, states[1], sent.ciphertext);
      final second = await engine.process(
        bob.state,
        states[1],
        sent.ciphertext,
      );
      expect((first.event as MlsMessageEvent).plaintext, _utf8('again'));
      expect((second.event as MlsMessageEvent).plaintext, _utf8('again'));
      expect(second.groupState, first.groupState);

      final g = await engine.createGroup(alice.state, _bytes(0xB2, 32));
      final k = await keyPackage(bob);
      final one = await engine.commitChange(
        alice.state,
        g,
        addKeyPackages: [k],
      );
      final two = await engine.commitChange(
        alice.state,
        g,
        addKeyPackages: [k],
      );
      expect(two.commit, one.commit);
    },
  );

  test('bad input and corrupt state map to their codes', () async {
    final alice = await device(1);
    final bob = await device(2);
    await _fails(engine.createDevice(_bytes(1, 15)), MlsErrorCode.badInput);
    await _fails(
      engine.createGroup(alice.state, _bytes(1, 65)),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.generateKeyPackages(alice.state, count: 101, lastResort: false),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.generateKeyPackages(alice.state, count: 0, lastResort: false),
      MlsErrorCode.badInput,
    );
    final g = await engine.createGroup(alice.state, _bytes(0xA1, 32));
    await _fails(engine.commitChange(alice.state, g), MlsErrorCode.badInput);
    await _fails(
      engine.commitChange(alice.state, g, removeDeviceIds: [bob.id]),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.commitChange(alice.state, g, removeDeviceIds: [alice.id]),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.encrypt(alice.state, g, _bytes(7, 4097)),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.process(alice.state, g, _bytes(7, 65537)),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.process(alice.state, g, _utf8('garbage')),
      MlsErrorCode.badInput,
    );
    await _fails(engine.wireEpoch(_utf8('garbage')), MlsErrorCode.badInput);
    await _fails(
      engine.describe(Uint8List.sublistView(g, 0, g.length - 1)),
      MlsErrorCode.corruptState,
    );
    await _fails(
      engine.describe(_utf8('not a state')),
      MlsErrorCode.corruptState,
    );
    await _fails(
      engine.encrypt(_utf8('not a state'), g, _utf8('x')),
      MlsErrorCode.corruptState,
    );
  });

  test(
    'a one-time key package joins once, a last-resort one repeatedly',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final r = await engine.generateKeyPackages(
        bob.state,
        count: 1,
        lastResort: true,
      );
      expect(r.keyPackages, hasLength(2));
      bob.state = r.deviceState;

      Future<Uint8List> welcomeFor(Uint8List kp, int n) async {
        final g = await engine.createGroup(alice.state, _bytes(n, 32));
        final c = await engine.commitChange(
          alice.state,
          g,
          addKeyPackages: [kp],
        );
        return c.welcome!;
      }

      final oneTime = await welcomeFor(r.keyPackages.first, 0x10);
      final j = await engine.joinFromWelcome(bob.state, oneTime);
      bob.state = j.deviceState;
      await _fails(
        engine.joinFromWelcome(bob.state, oneTime),
        MlsErrorCode.badInput,
      );

      final lastResort = r.keyPackages.last;
      for (final n in [0x11, 0x12]) {
        final j = await engine.joinFromWelcome(
          bob.state,
          await welcomeFor(lastResort, n),
        );
        bob.state = j.deviceState;
      }
    },
  );

  test('securityCode matches the known answer and is symmetric', () async {
    final a = SecurityParty(
      userId: _utf8('alice'),
      deviceKeys: [_bytes(1, 32)],
    );
    final b = SecurityParty(userId: _utf8('bob'), deviceKeys: [_bytes(2, 32)]);
    const expected =
        '01071 07934 45417 07576 54938 95528 17637 75144 80312 08694 94109 81731';
    expect(await engine.securityCode(a, b), expected);
    expect(await engine.securityCode(b, a), expected);

    await _fails(engine.securityCode(a, a), MlsErrorCode.badInput);
    await _fails(
      engine.securityCode(
        SecurityParty(userId: Uint8List(0), deviceKeys: [_bytes(1, 32)]),
        b,
      ),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.securityCode(SecurityParty(userId: _utf8('x'), deviceKeys: []), b),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.securityCode(
        SecurityParty(userId: _utf8('x'), deviceKeys: [Uint8List(0)]),
        b,
      ),
      MlsErrorCode.badInput,
    );
  });

  test('a group state refuses any device but its own', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final carolKp = await keyPackage(carol);
    final pending = (await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [carolKp],
    )).groupState;
    final wire = (await engine.encrypt(
      bob.state,
      states[1],
      _utf8('hi'),
    )).ciphertext;
    // Bob is a member but this is alice's state; carol is not a member.
    for (final other in [bob, carol]) {
      await _fails(
        engine.commitChange(other.state, states[0], removeDeviceIds: [bob.id]),
        MlsErrorCode.corruptState,
      );
      await _fails(
        engine.encrypt(other.state, states[0], _utf8('x')),
        MlsErrorCode.corruptState,
      );
      await _fails(
        engine.process(other.state, states[0], wire),
        MlsErrorCode.corruptState,
      );
      await _fails(
        engine.confirmCommit(other.state, pending),
        MlsErrorCode.corruptState,
      );
      await _fails(
        engine.discardCommit(other.state, pending),
        MlsErrorCode.corruptState,
      );
      // The binding is checked before the pending-commit rule.
      await _fails(
        engine.commitChange(other.state, pending, removeDeviceIds: [bob.id]),
        MlsErrorCode.corruptState,
      );
    }
    // The owner still works.
    await engine.process(alice.state, states[0], wire);

    // An evicted group state answers evicted, whichever device comes with it.
    final removal = await engine.commitChange(
      alice.state,
      states[0],
      removeDeviceIds: [bob.id],
    );
    final p = await engine.process(bob.state, states[1], removal.commit);
    await _fails(
      engine.encrypt(bob.state, p.groupState, _utf8('x')),
      MlsErrorCode.evicted,
    );
    await _fails(
      engine.commitChange(bob.state, p.groupState, addKeyPackages: [carolKp]),
      MlsErrorCode.evicted,
    );
    await _fails(
      engine.encrypt(carol.state, p.groupState, _utf8('x')),
      MlsErrorCode.evicted,
    );
  });

  test("another member's commit drops this device's pending commit", () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final dave = await device(4);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final fromAlice = await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [await keyPackage(carol)],
    );
    final fromBob = await engine.commitChange(
      bob.state,
      states[1],
      addKeyPackages: [await keyPackage(dave)],
    );
    expect((await engine.describe(fromBob.groupState)).hasPendingCommit, true);

    final p = await engine.process(
      bob.state,
      fromBob.groupState,
      fromAlice.commit,
    );
    final info = await engine.describe(p.groupState);
    expect(info.hasPendingCommit, isFalse);
    expect(info.epoch, 2);
    await _fails(
      engine.confirmCommit(bob.state, p.groupState),
      MlsErrorCode.noPendingCommit,
    );
  });

  test(
    'a commit that adds a duplicate or an existing member is refused',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final carol = await device(3);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      await _fails(
        engine.commitChange(
          alice.state,
          states[0],
          addKeyPackages: [await keyPackage(bob)],
        ),
        MlsErrorCode.badInput,
      );
      await _fails(
        engine.commitChange(
          alice.state,
          states[0],
          addKeyPackages: [await keyPackage(carol), await keyPackage(carol)],
        ),
        MlsErrorCode.badInput,
      );
    },
  );

  test(
    'a received commit adding a present or repeated device id is refused',
    () async {
      final alice = await device(1);
      final bob = await device(2);
      final carol = await device(3);
      final dave = await device(4);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final c = await engine.commitChange(
        alice.state,
        states[0],
        addKeyPackages: [await keyPackage(carol), await keyPackage(dave)],
      );
      // Control: the commit as sent is accepted.
      await engine.process(bob.state, states[1], c.commit);
      // An add that reuses bob's id (already a member).
      await _fails(
        engine.process(
          bob.state,
          states[1],
          _swapId(c.commit, carol.id, bob.id),
        ),
        MlsErrorCode.badInput,
      );
      // The same id added twice in one commit.
      await _fails(
        engine.process(
          bob.state,
          states[1],
          _swapId(c.commit, dave.id, carol.id),
        ),
        MlsErrorCode.badInput,
      );
    },
  );

  test('a welcome listing a device id twice is refused', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final c = await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [await keyPackage(carol)],
    );
    await _fails(
      engine.joinFromWelcome(
        carol.state,
        _swapId(c.welcome!, bob.id, carol.id),
      ),
      MlsErrorCode.badInput,
    );
    // Control: the welcome as sent is accepted.
    await engine.joinFromWelcome(carol.state, c.welcome!);
  });

  test('a message from another group is refused', () async {
    final alice = await device(1);
    final bob = await device(2);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final other = await engine.createGroup(alice.state, _bytes(0xB2, 32));
    final sent = await engine.encrypt(alice.state, other, _utf8('elsewhere'));
    await _fails(
      engine.process(bob.state, states[1], sent.ciphertext),
      MlsErrorCode.badInput,
    );
  });

  test('an exhaustive switch over MlsEvent covers both outcomes', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final sent = await engine.encrypt(alice.state, states[0], _utf8('hi'));
    final commit = await engine.commitChange(
      alice.state,
      states[0],
      addKeyPackages: [await keyPackage(carol)],
    );

    String describeEvent(MlsEvent event) => switch (event) {
      MlsMessageEvent(:final plaintext) => 'message:${utf8.decode(plaintext)}',
      MlsCommitEvent(:final epoch, :final added) =>
        'commit:$epoch:${added.length}',
    };

    final first = await engine.process(bob.state, states[1], sent.ciphertext);
    expect(describeEvent(first.event), 'message:hi');
    // The message above belongs to epoch 1, so the commit (also epoch 1) is
    // processed from the original state.
    final second = await engine.process(bob.state, states[1], commit.commit);
    expect(describeEvent(second.event), 'commit:2:1');
  });

  group('selfUpdate', () {
    // Lists, not records: a record compares its Uint8List fields by identity.
    List<List<Uint8List>> membersOf(GroupDescription info) => [
      for (final m in info.members) [m.deviceId, m.signaturePublicKey],
    ];

    test('is pending, then confirms to the next epoch', () async {
      final alice = await device(1);
      final bob = await device(2);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final before = membersOf(await engine.describe(states[0]));

      final c = await engine.selfUpdate(alice.state, states[0]);
      expect(c.epoch, 1);
      expect(c.welcome, isNull);
      final pending = await engine.describe(c.groupState);
      expect(pending.hasPendingCommit, isTrue);
      expect(pending.epoch, 1);

      final a2 = await engine.confirmCommit(alice.state, c.groupState);
      final info = await engine.describe(a2);
      expect(info.epoch, 2);
      expect(info.hasPendingCommit, isFalse);
      expect(membersOf(info), before);
      expect(before, [
        [alice.id, alice.signatureKey],
        [bob.id, bob.signatureKey],
      ]);
    });

    test('receivers see an empty commit and keep talking', () async {
      final alice = await device(1);
      final bob = await device(2);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final c = await engine.selfUpdate(alice.state, states[0]);
      var a = await engine.confirmCommit(alice.state, c.groupState);

      final p = await engine.process(bob.state, states[1], c.commit);
      final event = p.event as MlsCommitEvent;
      expect(event.epoch, 2);
      expect(event.added, isEmpty);
      expect(event.removed, isEmpty);
      expect(event.selfRemoved, isFalse);
      var b = p.groupState;
      expect(
        membersOf(await engine.describe(b)),
        membersOf(await engine.describe(a)),
      );

      final toBob = await engine.encrypt(alice.state, a, _utf8('renewed'));
      a = toBob.groupState;
      final got = await engine.process(bob.state, b, toBob.ciphertext);
      b = got.groupState;
      expect((got.event as MlsMessageEvent).plaintext, _utf8('renewed'));
      final toAlice = await engine.encrypt(bob.state, b, _utf8('answer'));
      final back = await engine.process(alice.state, a, toAlice.ciphertext);
      expect((back.event as MlsMessageEvent).plaintext, _utf8('answer'));
      expect(toAlice.epoch, 2);
    });

    test('follows the commit rules', () async {
      final alice = await device(1);
      final bob = await device(2);
      final carol = await device(3);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final c = await engine.selfUpdate(alice.state, states[0]);

      await _fails(
        engine.selfUpdate(alice.state, c.groupState),
        MlsErrorCode.pendingCommit,
      );
      await _fails(
        engine.commitChange(
          alice.state,
          c.groupState,
          addKeyPackages: [await keyPackage(carol)],
        ),
        MlsErrorCode.pendingCommit,
      );
      await _fails(
        engine.encrypt(alice.state, c.groupState, _utf8('x')),
        MlsErrorCode.pendingCommit,
      );

      // Discarded: back at epoch 1 with the same members, and usable.
      final g = await engine.discardCommit(alice.state, c.groupState);
      final info = await engine.describe(g);
      expect(info.epoch, 1);
      expect(info.hasPendingCommit, isFalse);
      expect(membersOf(info), membersOf(await engine.describe(states[0])));
      final sent = await engine.encrypt(alice.state, g, _utf8('after'));
      final got = await engine.process(bob.state, states[1], sent.ciphertext);
      expect((got.event as MlsMessageEvent).plaintext, _utf8('after'));

      // Another device's blob: corruptState, before the pending-commit rule.
      for (final other in [bob, carol]) {
        await _fails(
          engine.selfUpdate(other.state, states[0]),
          MlsErrorCode.corruptState,
        );
        await _fails(
          engine.selfUpdate(other.state, c.groupState),
          MlsErrorCode.corruptState,
        );
      }

      // Evicted: alice removes bob; bob's processed state refuses.
      final r = await engine.commitChange(
        alice.state,
        states[0],
        removeDeviceIds: [bob.id],
      );
      final gone = await engine.process(bob.state, states[1], r.commit);
      await _fails(
        engine.selfUpdate(bob.state, gone.groupState),
        MlsErrorCode.evicted,
      );
    });

    test('racing self-updates: the loser processes the winner', () async {
      final alice = await device(1);
      final bob = await device(2);
      final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
      final ca = await engine.selfUpdate(alice.state, states[0]);
      final cb = await engine.selfUpdate(bob.state, states[1]);
      expect((ca.epoch, cb.epoch), (1, 1));
      await engine.confirmCommit(alice.state, ca.groupState);
      final p = await engine.process(bob.state, cb.groupState, ca.commit);
      final info = await engine.describe(p.groupState);
      expect(info.epoch, 2);
      expect(info.hasPendingCommit, isFalse);
      final retry = await engine.selfUpdate(bob.state, p.groupState);
      expect(retry.epoch, 2);
    });
  });

  group('seal and open', () {
    final key = _bytes(7, 32);
    final aad = _utf8('messages:row-1');

    test('round-trips with exactly 28 bytes of overhead', () async {
      for (final plaintext in [
        Uint8List(0),
        _utf8('x'),
        _utf8('hello vault'),
        _bytes(0, 4096),
      ]) {
        final sealed = await engine.seal(key, aad, plaintext);
        expect(sealed.length, plaintext.length + 28);
        expect(await engine.open(key, aad, sealed), plaintext);
      }
    });

    test('two seals of the same input differ', () async {
      final a = await engine.seal(key, aad, _utf8('same'));
      final b = await engine.seal(key, aad, _utf8('same'));
      expect(a, isNot(b));
      expect(a.sublist(0, 12), isNot(b.sublist(0, 12)));
    });

    test('a wrong key, a wrong aad or a flipped byte is badInput', () async {
      final sealed = await engine.seal(key, aad, _utf8('secret'));
      await _fails(
        engine.open(_bytes(8, 32), aad, sealed),
        MlsErrorCode.badInput,
      );
      await _fails(
        engine.open(key, _utf8('messages:row-2'), sealed),
        MlsErrorCode.badInput,
      );
      await _fails(
        engine.open(key, Uint8List(0), sealed),
        MlsErrorCode.badInput,
      );
      for (final i in [0, 11, 12, sealed.length - 1]) {
        final bad = Uint8List.fromList(sealed)..[i] ^= 1;
        await _fails(engine.open(key, aad, bad), MlsErrorCode.badInput);
      }
    });

    test('a truncated or extended value is badInput', () async {
      final sealed = await engine.seal(key, aad, _utf8('secret'));
      for (final n in [0, 1, 12, 27, sealed.length - 1]) {
        await _fails(
          engine.open(key, aad, sealed.sublist(0, n)),
          MlsErrorCode.badInput,
        );
      }
      await _fails(
        engine.open(key, aad, Uint8List.fromList([...sealed, 0])),
        MlsErrorCode.badInput,
      );
      await _fails(engine.open(key, aad, Uint8List(28)), MlsErrorCode.badInput);
    });

    test('a key other than 32 bytes is badInput', () async {
      final sealed = await engine.seal(key, aad, _utf8('secret'));
      for (final n in [0, 16, 31, 33]) {
        await _fails(
          engine.seal(_bytes(7, n), aad, _utf8('secret')),
          MlsErrorCode.badInput,
        );
        await _fails(
          engine.open(_bytes(7, n), aad, sealed),
          MlsErrorCode.badInput,
        );
      }
    });

    test('the plaintext cap is 1 MiB inclusive', () async {
      const cap = 1048576;
      final atCap = _bytes(0x5a, cap);
      final sealed = await engine.seal(key, aad, atCap);
      expect(sealed.length, cap + 28);
      expect(await engine.open(key, aad, sealed), atCap);
      await _fails(
        engine.seal(key, aad, _bytes(0x5a, cap + 1)),
        MlsErrorCode.badInput,
      );
      await _fails(
        engine.open(key, aad, Uint8List(cap + 29)),
        MlsErrorCode.badInput,
      );
    });

    test('errors carry no key, aad or plaintext', () async {
      final sealed = await engine.seal(key, aad, _utf8('top-secret'));
      try {
        await engine.open(key, _utf8('other-aad'), sealed);
        fail('expected badInput');
      } on MlsException catch (e) {
        expect(e.toString(), isNot(contains('top-secret')));
        expect(e.toString(), isNot(contains('other-aad')));
        expect(e.toString(), isNot(contains('messages:row')));
      }
    });
  });

  test('randomBytes gives 1 to 64 fresh bytes', () async {
    for (final n in [1, 12, 32, 64]) {
      expect((await engine.randomBytes(n)).length, n);
    }
    expect(await engine.randomBytes(32), isNot(await engine.randomBytes(32)));
    for (final n in [0, 65, -1, 1 << 32]) {
      await _fails(engine.randomBytes(n), MlsErrorCode.badInput);
    }
  });

  test('MlsErrorCode.parse maps wire strings and unknown to internal', () {
    expect(MlsErrorCode.parse('wrong_epoch'), MlsErrorCode.wrongEpoch);
    expect(
      MlsErrorCode.parse('no_pending_commit'),
      MlsErrorCode.noPendingCommit,
    );
    expect(MlsErrorCode.parse('nonsense'), MlsErrorCode.internal);
  });
}
