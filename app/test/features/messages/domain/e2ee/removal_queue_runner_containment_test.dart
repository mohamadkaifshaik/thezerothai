import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's fix-round-2 tests (Task 11 whole-branch review CR and
// security audit SA): containment of a removed device in every case the
// earlier rounds left open. The other files are removal_queue_runner_test.dart
// and removal_queue_runner_recovery_test.dart.

const _c1 = '11111111111111111111111111111111';

void main() {
  tearDown(removalQueueTearDown);

  /// Some minutes after the acceptance (so a peer fetch counts and
  /// attribution concludes), bob commits, on the server's current pair of
  /// [c], an add of [add] (this device has not applied it).
  Future<void> bobAdds(String c, List<RigPeer> add) async {
    rig.clock.advance(kConversationCopyStale + const Duration(minutes: 1));
    final at = rig.server.current(c);
    final commit = await rigCommit(
      offers[c]!.add.group,
      add: [for (final p in add) await p.keyPackage()],
    );
    rig.server.addCommit(c, at, commit.commit, fromUser: 'user-b');
  }

  group('a removed own device pinned unattributed (CR I-A, SA L3)', () {
    test('a peer-built commit adds an own device while this device is '
        'behind; removeDevice still takes it out of the group', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      // Bob adds the user's sibling; this device has not caught up, so it
      // never attributed the sibling while the own list still named it.
      await bobAdds(_c1, [sibling]);

      await removeAndSettle(sibling);
      // That pass's catch-up applied bob's add (the sibling is pinned
      // unattributed: the own list no longer names it); its commit waits
      // for a live pull at the new pair, which the next pass makes first.
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      await runner.runPass();

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(await pin(sibling), isNull, reason: 'left the group');
      expect(requests(_c1), hasLength(1));
      expect(runner.pending.value, 0);
      expect((await pin(bob))!.side, MemberSide.theirs);
    });

    test('the upkeep\'s reconcile takes it out too', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1);
      await synced();
      await bobAdds(_c1, [sibling]);
      // The runner's pass catches up (the sibling is pinned unattributed)
      // and cannot commit before a live pull at the new pair.
      await removeAndSettle(sibling);
      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
      await rig.receiver.pullLive(_c1);
      expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);

      await rig.upkeep.reconcile(_c1);

      expect(await pin(sibling), isNull);
      expect(requests(_c1), hasLength(1));
    });

    test('a pin whose key is not the key the own list showed stays and is '
        'reported', () async {
      final sibling = await RigPeer.create('sibling');
      final other = await RigPeer.create('other');
      // The own list names the sibling's id with another key.
      await setUpRig();
      rig.keys.own.add(rigKeyDevice(sibling.idString, other.key));
      await join(_c1);
      await synced();
      await bobAdds(_c1, [sibling]);
      expectedErrors = ['removalQueue.keyMismatch'];

      await removeAndSettle(sibling);
      await runner.runPass();

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.unattributed);
      expect(queued(_c1, sibling), isTrue);
    });
  });
}
