import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/removal_queue_harness.dart';

// The removal queue's lost-own-device tests (Task 11 security audit SA M2,
// fix round 2 ruling 11; fix round 4 rulings 3 and 6): a pass queues an own
// device the own list no longer shows. A pure move out of
// removal_queue_runner_containment_test.dart (fix round 4, file size).

const _c1 = '11111111111111111111111111111111';

void main() {
  tearDown(removalQueueTearDown);

  group('an own device removed on another own device (SA M2)', () {
    /// The user's other phone removed the sibling: the own list no longer
    /// names it, and this device never ran removeDevice.
    Future<RigPeer> removedElsewhereByUser() async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      expect((await pin(sibling))!.side, MemberSide.mine);
      rig.keys.own.removeWhere((d) => d.deviceId == sibling.idString);
      // The setup's own list still names it; a pass reuses a list younger
      // than kLostOwnListReuse (fix round 4, ruling 6).
      rig.clock.advance(kLostOwnListReuse);
      return sibling;
    }

    test('a pass queues a mine pin a fresh own list does not show, and '
        'removes it', () async {
      final sibling = await removedElsewhereByUser();

      await runner.onVaultReady();
      await runner.idle();

      expect(rig.keys.removeCalls, isEmpty);
      expect(requests(_c1), hasLength(1));
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
      expect(await runner.wasRemovedByUser(sibling.id), isFalse);
    });

    test('it is not user-queued: the M5 pause holds it', () async {
      final sibling = await removedElsewhereByUser();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }

      await runner.onVaultReady();
      await runner.idle();

      expect(requests(), isEmpty);
      expect(queued(_c1, sibling), isTrue);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('reconcile exempts a queued removal from the pause only when the '
        'user removed the device', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      // Queued; the own list reconcile reads still shows it (M3 says no).
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      rig.upkeep.removedByUser = (_) => false;

      await rig.upkeep.reconcile(_c1);
      expect(requests(), isEmpty, reason: 'held by the pause');

      rig.upkeep.removedByUser = (_) => true;
      await rig.upkeep.reconcile(_c1);
      expect(requests(_c1), hasLength(1));
      expect(await pin(sibling), isNull);
    });

    test('one own list that missed the device does not freeze into a '
        'removal: the next pass\'s list names it, and the unmarked entry '
        'goes (fix round 4, CR2 M-1)', () async {
      final sibling = await removedElsewhereByUser();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      await runner.onVaultReady();
      await runner.idle();
      expect(queued(_c1, sibling), isTrue, reason: 'the glitch queued it');

      // The list names it again (the miss was a glitch).
      rig.keys.own.add(rigKeyDevice(sibling.idString, sibling.key));
      rig.clock.advance(kLostOwnListReuse);
      await runner.runPass();

      expect(queued(_c1, sibling), isFalse);
      expect((await stored())!.entries, isEmpty);
      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('reconcile leaves a queued id with no removed mark to M3: a list '
        'that names it keeps it (fix round 4, CR2 M-1)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      rig.upkeep.removedByUser = (_) => false;

      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('a pass reuses an own list read less than 60 seconds ago, and reads '
        'one fresh when it is older (fix round 4, CR2 M-4)', () async {
      final sibling = await removedElsewhereByUser();
      // Paused, so the entry stays queued across the passes.
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      await rig.directory.own(fresh: true);
      rig.clock.advance(const Duration(seconds: 30));
      final young = rig.keys.listCalls;

      await runner.onVaultReady();
      await runner.idle();

      expect(rig.keys.listCalls, young, reason: 'the young list is reused');
      expect(queued(_c1, sibling), isTrue);

      rig.clock.advance(const Duration(seconds: 31));
      await runner.runPass();

      expect(rig.keys.listCalls, young + 1, reason: 'one fresh list');
      expect(queued(_c1, sibling), isTrue);
    });

    test('a mine pin the own list still shows is never queued', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();

      await runner.onVaultReady();
      await runner.idle();

      expect(runner.queuedFor(_c1), isEmpty);
      expect(requests(), isEmpty);
    });
  });
}
