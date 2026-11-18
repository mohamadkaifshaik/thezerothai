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

  test('a replay and the device\'s own message are duplicate', () async {
    final alice = await device(1);
    final bob = await device(2);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final sent = await engine.encrypt(alice.state, states[0], _utf8('once'));
    final p = await engine.process(bob.state, states[1], sent.ciphertext);
    await _fails(
      engine.process(bob.state, p.groupState, sent.ciphertext),
      MlsErrorCode.duplicate,
    );
    await _fails(
      engine.process(alice.state, sent.groupState, sent.ciphertext),
      MlsErrorCode.duplicate,
    );
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

  test('a device that is not in the group cannot commit or encrypt', () async {
    final alice = await device(1);
    final bob = await device(2);
    final carol = await device(3);
    final states = await groupOf(alice, [bob], _bytes(0xA1, 32));
    final carolKp = await keyPackage(carol);
    await _fails(
      engine.commitChange(carol.state, states[0], addKeyPackages: [carolKp]),
      MlsErrorCode.badInput,
    );
    await _fails(
      engine.encrypt(carol.state, states[0], _utf8('x')),
      MlsErrorCode.badInput,
    );

    // An evicted device still gets evicted, not badInput.
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

  test('MlsErrorCode.parse maps wire strings and unknown to internal', () {
    expect(MlsErrorCode.parse('wrong_epoch'), MlsErrorCode.wrongEpoch);
    expect(
      MlsErrorCode.parse('no_pending_commit'),
      MlsErrorCode.noPendingCommit,
    );
    expect(MlsErrorCode.parse('nonsense'), MlsErrorCode.internal);
  });
}
