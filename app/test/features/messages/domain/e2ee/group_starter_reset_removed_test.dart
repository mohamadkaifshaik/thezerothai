// Task 11 follow-up (CR2 M-6; fix round 4, ruling 8; review ruling 4; fix
// round 5, R2): a reset never re-adds an own device the user removed, and
// an unreadable removal queue means fresh own devices only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/e2ee_reset_harness.dart';

const _bob = 'ref-bob';
const _me = 'user-a';

void main() {
  // The shared state and helpers (`e2ee_reset_harness.dart`).
  registerResetHarness();

  /// Every id the seam was asked about, as the server shows it.
  late List<String> asked;

  /// The seam answers [removed] for each id it is asked about.
  void seam(bool Function(Uint8List id) removed) {
    asked = [];
    rig.wasRemovedByUser = (id) async {
      asked.add(utf8.decode(id));
      return removed(id);
    };
  }

  /// The seam cannot answer: the removal queue is unreadable.
  void unreadableQueue() {
    asked = [];
    rig.wasRemovedByUser = (id) async {
      asked.add(utf8.decode(id));
      throw StateError('The removal record cannot be read.');
    };
  }

  /// The claims for this user answer [devices] (listed or not).
  void ownClaims(List<RigPeer> devices) => rig.keys.claims[_me] = () async =>
      kpb.ClaimKeyPackagesResponse(
        keyPackages: [for (final d in devices) await packageOf(d)],
      );

  /// The directory holds lists read now with [sib] on the own one; then the
  /// server removes [sib] and its list calls are deferred (RATE_LIMITED
  /// pauses the directory's budget): the reset's "fresh" reads answer the
  /// kept lists, which still show [sib].
  Future<void> cachedListsStillShow(RigPeer sib) async {
    expect((await rig.directory.own(fresh: true)).readable, isTrue);
    expect((await rig.directory.peer(_bob, fresh: true)).readable, isTrue);
    rig.keys.own.removeWhere((d) => d.deviceId == sib.idString);
    rig.directoryBudget.pauseUntil(
      rig.clock.now().add(const Duration(minutes: 5)),
    );
  }

  test('a reset never re-adds a device the user removed', () async {
    final sib = await RigPeer.create('sib');
    final sib2 = await RigPeer.create('sib2');
    await setUpJoined();
    siblings([sib, sib2]);
    await makeStuck();
    seam((id) => rigEq(id, sib.id));

    await reset();

    expect(resets().single.welcomeDeviceIds.toSet(), {
      bob.idString,
      sib2.idString,
    });
    expect(await pin(sib.id), isNull);
    expect(await pin(sib2.id), isNotNull);
    // Own-list devices only (fix round 5, R2): the peer's are never asked.
    expect(asked, isNot(contains(bob.idString)));
    expect(asked, contains(sib.idString));
  });

  test('the reset asks only about own-list devices: a mark naming the '
      'peer\'s device is never consulted (fix round 5, R2)', () async {
    final sib = await RigPeer.create('sib');
    await setUpJoined();
    siblings([sib]);
    await makeStuck();
    // A mark for bob's id (it cannot be the user's): never consulted, and
    // bob is still addressed.
    seam((id) => rigEq(id, bob.id) || rigEq(id, sib.id));

    await reset();

    expect(resets().single.welcomeDeviceIds, [bob.idString]);
    expect(asked, [sib.idString]);
  });

  test('an unreadable removal queue: the reset uses only fresh own devices '
      '(kept lists add no own device)', () async {
    final sib = await RigPeer.create('sib');
    await setUpJoined();
    siblings([sib]);
    await makeStuck();
    await cachedListsStillShow(sib);
    unreadableQueue();

    await reset();

    // Bob is still addressed; the own device only the kept list showed is
    // not: nothing new is reported either (no deviceAdded for it).
    expect(resets().single.welcomeDeviceIds, [bob.idString]);
    expect(await pin(sib.id), isNull);
    expect(rig.unexpected, isEmpty);
  });

  test('an unreadable removal queue with a fresh own list adds the own '
      'devices that list shows, and no other', () async {
    final sib = await RigPeer.create('sib');
    final sib2 = await RigPeer.create('sib2');
    await setUpJoined();
    siblings([sib2]);
    // The claim also hands out a package of sib, which no fresh list shows.
    ownClaims([sib, sib2]);
    await makeStuck();
    unreadableQueue();

    await reset();

    expect(resets().single.welcomeDeviceIds.toSet(), {
      bob.idString,
      sib2.idString,
    });
    expect(await pin(sib.id), isNull);
  });

  test('a removal older than the queue\'s memory (expired mark) may be '
      're-added', () async {
    // The bound, documented: the client remembers a removal for
    // kRemovedByUserLimit (30 days, the runner's mark); the server refuses
    // the removed id's re-registration for 90 days (keys RemovalMarkTTL).
    // A device the fresh own list shows again after the client's 30 days
    // is a device the server let back in, and a reset may add it.
    expect(kRemovedByUserLimit, const Duration(days: 30));
    final sib = await RigPeer.create('sib');
    await setUpJoined();
    siblings([sib]);
    await makeStuck();
    final runner = RemovalQueueRunner(
      keys: rig.keys,
      directory: rig.directory,
      commits: rig.commits,
      upkeep: rig.upkeep,
      receiver: rig.receiver,
      crypto: rig.crypto,
      session: rig.device.session,
      engine: rig.engineNow,
      locks: rig.locks,
      contexts: rig.contexts,
      now: rig.clock.now,
      removedElsewhere: () => rig.removedElsewhere,
      schedule: (delay, run) => () {},
      onUnexpectedError: (e, _) => rig.unexpected.add(e),
    );
    final removedAt = rig.clock.now().subtract(
      kRemovedByUserLimit + const Duration(minutes: 1),
    );
    await rig.device.vault.transaction(
      (tx) => tx.putSetting(
        kVaultSettingRemovalRecord,
        RemovalRecord(
          removed: [
            RemovalMark(
              deviceId: sib.idString,
              atMicros: removedAt.microsecondsSinceEpoch,
              signatureKey: sib.key,
            ),
          ],
        ).encode(),
      ),
    );
    rig.wasRemovedByUser = runner.wasRemovedByUser;
    expect(await runner.wasRemovedByUser(sib.id), isFalse);

    await reset();

    expect(resets().single.welcomeDeviceIds.toSet(), {
      bob.idString,
      sib.idString,
    });
    await runner.idle();
  });

  test('a mark inside the queue\'s memory is still a removal (the runner\'s '
      'answer the reset consults)', () async {
    final sib = await RigPeer.create('sib');
    await setUpJoined();
    siblings([sib]);
    await makeStuck();
    final runner = RemovalQueueRunner(
      keys: rig.keys,
      directory: rig.directory,
      commits: rig.commits,
      upkeep: rig.upkeep,
      receiver: rig.receiver,
      crypto: rig.crypto,
      session: rig.device.session,
      engine: rig.engineNow,
      locks: rig.locks,
      contexts: rig.contexts,
      now: rig.clock.now,
      removedElsewhere: () => rig.removedElsewhere,
      schedule: (delay, run) => () {},
      onUnexpectedError: (e, _) => rig.unexpected.add(e),
    );
    final removedAt = rig.clock.now().subtract(
      kRemovedByUserLimit - const Duration(minutes: 1),
    );
    await rig.device.vault.transaction(
      (tx) => tx.putSetting(
        kVaultSettingRemovalRecord,
        RemovalRecord(
          removed: [
            RemovalMark(
              deviceId: sib.idString,
              atMicros: removedAt.microsecondsSinceEpoch,
              signatureKey: sib.key,
            ),
          ],
        ).encode(),
      ),
    );
    rig.wasRemovedByUser = runner.wasRemovedByUser;

    await reset();

    expect(resets().single.welcomeDeviceIds, [bob.idString]);
    expect(await pin(sib.id), isNull);
    await runner.idle();
  });
}
