import 'dart:typed_data';

import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 12, brief amendment 8 (pre-flag fix round 3 report, "for
// Task 12/13"): attribution binds its peer reference to the one the vault
// stored for the conversation. A header (or a first page) that names
// another user must not make that user's devices the peer side of this
// conversation.

const _c1 = '11111111111111111111111111111111';

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigPeer carol;

  setUp(() async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    carol = await RigPeer.create('carol');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
  });

  tearDown(() => rig.dispose());

  Future<MemberRecord?> pin(Uint8List id) async {
    for (final m in await rig.device.vault.members(_c1)) {
      if (rigEq(m.deviceId, id)) return m;
    }
    return null;
  }

  /// Joined with bob (stored peer ref `ref-bob`), then bob adds carol.
  Future<void> carolAdded() async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    final offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(rig.known.peerOf(_c1), 'ref-bob');
    expect((await pin(bob.id))!.side, MemberSide.theirs);
    final at = rig.server.current(_c1);
    final commit = await rigCommit(
      offer.add.group,
      add: [await carol.keyPackage()],
    );
    rig.server.addCommit(_c1, at, commit.commit, fromUser: 'user-b');
  }

  test('attribution refuses when the stored peer ref is set and differs '
      'from the one it checks against', () async {
    await carolAdded();
    // The header now names another user, whose list shows carol.
    rig.contexts.of(_c1).peerUserId = 'ref-mallory';
    rig.keys.peers['ref-mallory'] = [rigKeyDevice(carol.idString, carol.key)];

    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

    expect((await pin(carol.id))!.side, MemberSide.unattributed);
    expect(rig.known.peerOf(_c1), 'ref-bob');
    expect(rig.keys.getCalls.expand((c) => c), isNot(contains('ref-mallory')));
    expect(rig.contexts.of(_c1).listUnverifiable, isTrue);
  });

  test('the same peer ref attributes as before', () async {
    await carolAdded();
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, carol.key),
    ];

    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

    expect((await pin(carol.id))!.side, MemberSide.theirs);
  });
}
