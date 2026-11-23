import 'dart:async';

import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

// Plan 5a Task 12, brief amendment 6: while this device is removed
// elsewhere, no sync, decrypt, send, init, reset or commit call goes out.
// The sender, the starter (init and reset) and the commit runner already
// have their tests (encrypted_sender_test, group_starter_init_test,
// group_starter_reset_test, commit_runner_test); these cover the seams that
// had none: the crypto's welcome poll, catch-up and attribution, the
// receiver's passes, and the upkeep's reconcile and self-update. The rig
// hands every component the SAME fact (`RigCrypto.removedElsewhere`), as
// Task 13 hands them `DeviceKeysService.removedElsewhere`.

const _c1 = '11111111111111111111111111111111';

/// A sync budget whose first take waits for [release].
class _HeldBudget extends SyncBudget {
  _HeldBudget(RigClock clock)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: clock.now);

  final Completer<void> release = Completer<void>();
  bool waiting = false;

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) async {
    if (!release.isCompleted) {
      waiting = true;
      await release.future;
    }
    return super.take(priority, lane: lane);
  }
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;

  setUp(() async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
  });

  tearDown(() => rig.dispose());

  test('removed elsewhere: the crypto, the receiver and the upkeep send '
      'nothing and call no engine; the same calls go out once it '
      'clears', () async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    final offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    // Bob moves the group on, and offers a second conversation.
    final at = rig.server.current(_c1);
    final carol = await RigPeer.create('carol');
    final commit = await rigCommit(
      offer.add.group,
      add: [await carol.keyPackage()],
    );
    rig.server.addCommit(_c1, at, commit.commit, fromUser: 'user-b');
    const c2 = '22222222222222222222222222222222';
    await rig.accept(c2);
    rig.header(c2, 'ref-bob');
    await rig.offer(c2, bob);

    rig.removedElsewhere = true;
    final calls = rig.server.calls.length;
    final lists = rig.keys.listCalls;
    final gets = rig.keys.getCalls.length;
    rig.device.engine.calls.clear();
    final before = await rig.dump();

    expect(rig.crypto.removedElsewhere, isTrue);
    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
    await rig.crypto.attributeMembers(_c1, priority: BudgetPriority.user);
    final pass = await rig.receiver.pullLive(
      _c1,
      priority: BudgetPriority.user,
    );
    expect(pass.kind, ReceiveOutcomeKind.stopped);
    expect(
      (await rig.receiver.reconcile(_c1)).kind,
      ReceiveOutcomeKind.stopped,
    );
    await rig.receiver.applyClearedAtOnce(_c1);
    await rig.upkeep.reconcile(_c1);
    await rig.upkeep.selfUpdateIfDue(_c1);

    expect(rig.server.calls.sublist(calls), isEmpty);
    expect(rig.keys.listCalls, lists);
    expect(rig.keys.getCalls, hasLength(gets));
    expect(rig.device.engine.calls, isEmpty);
    expect(await rig.dump(), before);
    expect(rig.unexpected, isEmpty);

    // The fact clears: the same entries make their calls again.
    rig.removedElsewhere = false;
    expect(await rig.crypto.processWelcomes(), [c2]);
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    expect(rig.server.calls.sublist(calls), isNotEmpty);
  });

  test('found removed while a sync unit was awaited: the call does not go '
      'out (fix round 1, M5)', () async {
    await rig.dispose();
    late _HeldBudget budget;
    rig = await RigCrypto.create(
      syncBudget: (clock) => budget = _HeldBudget(clock),
    );
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    final calls = rig.server.calls.length;

    final poll = rig.crypto.processWelcomes();
    for (var i = 0; i < 50 && !budget.waiting; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(budget.waiting, isTrue);
    // Detection happens while the take waits in the budget's queue.
    rig.removedElsewhere = true;
    budget.release.complete();

    expect(await poll, isEmpty);
    expect(rig.server.calls.sublist(calls), isEmpty);
  });

  test('removed elsewhere: attribution reads no device list while a member '
      'is unattributed (fix round 1, I1)', () async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    final offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    // Bob adds carol; no list shows her yet, so she stays unattributed.
    final carol = await RigPeer.create('carol');
    final at = rig.server.current(_c1);
    final commit = await rigCommit(
      offer.add.group,
      add: [await carol.keyPackage()],
    );
    rig.server.addCommit(_c1, at, commit.commit, fromUser: 'user-b');
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    Future<String?> carolSide() async {
      for (final m in await rig.device.vault.members(_c1)) {
        if (rigEq(m.deviceId, carol.id)) return m.side;
      }
      return null;
    }

    expect(await carolSide(), 'unattributed');
    // Now the peer's list shows her: an attribution would pin her.
    rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));

    rig.removedElsewhere = true;
    final lists = rig.keys.listCalls;
    final gets = rig.keys.getCalls.length;
    final before = await rig.dump();

    await rig.crypto.attributeMembers(_c1, priority: BudgetPriority.user);
    await rig.locks.run(
      _c1,
      () =>
          rig.crypto.attributeMembersLocked(_c1, priority: BudgetPriority.user),
    );

    expect(rig.keys.listCalls, lists);
    expect(rig.keys.getCalls, hasLength(gets));
    expect(await rig.dump(), before);
    expect(await carolSide(), 'unattributed');

    rig.removedElsewhere = false;
    await rig.crypto.attributeMembers(_c1, priority: BudgetPriority.user);
    expect(rig.keys.getCalls.length, greaterThan(gets));
    expect(await carolSide(), 'theirs');
  });
}
