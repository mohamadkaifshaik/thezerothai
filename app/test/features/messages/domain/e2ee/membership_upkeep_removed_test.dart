// Task 11 follow-up (CR2 M-6; fix round 4, ruling 8; review ruling 4; fix
// round 5, R2): reconcile never re-adds an own device the user removed,
// and an unreadable removal queue means fresh own devices only.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;

  /// Every id the seam was asked about, as the server shows it.
  var asked = <String>[];

  tearDown(() async {
    await rig.upkeep.idle();
    final unexpected = [
      for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
    ];
    await rig.dispose();
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  /// This device joins [_c1] (accepted) from bob's welcome; bob's list
  /// shows bob and [alsoListed], the own list this device and [ownListed].
  Future<void> setUpJoined({
    List<RigPeer> alsoListed = const [],
    List<RigPeer> ownListed = const [],
  }) async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [
      for (final p in [bob, ...alsoListed]) rigKeyDevice(p.idString, p.key),
    ];
    rig.keys.own.addAll([
      for (final p in ownListed) rigKeyDevice(p.idString, p.key),
    ]);
    await rig.accept(_c1);
    rig.server.rows[_c1] = pb.Conversation(
      id: _c1,
      peer: common.AuthorSnapshot(userId: 'ref-bob'),
      folder: Folder.FOLDER_INBOX,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      canReply: true,
    );
    offer = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    await rig.receiver.pullLive(_c1);
    expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);
  }

  Future<kpb.ClaimedKeyPackage> claimed(RigPeer p) async =>
      kpb.ClaimedKeyPackage(
        deviceId: p.idString,
        signaturePublicKey: p.key,
        keyPackage: await p.keyPackage(),
        hasKeyPackage_4: true,
      );

  void peerClaims(List<RigPeer> devices) =>
      rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [for (final d in devices) await claimed(d)],
      );

  void ownClaims(List<RigPeer> devices) =>
      rig.keys.claims['user-a'] = () async => kpb.ClaimKeyPackagesResponse(
        keyPackages: [for (final d in devices) await claimed(d)],
      );

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

  Future<MemberRecord?> pin(RigPeer p) async {
    for (final m in await rig.device.vault.members(_c1)) {
      if (rigEq(m.deviceId, p.id)) return m;
    }
    return null;
  }

  List<String> ownClaimCalls() => [
    for (final c in rig.keys.claimCalls)
      if (c.userId == 'user-a') c.userId,
  ];

  /// The directory keeps an own list read now that shows [sibling]; the
  /// server's list then no longer does. Reconcile's own read (reused within
  /// kDeviceListReuse) answers the kept list.
  Future<void> keptListStillShows(RigPeer sibling) async {
    expect((await rig.directory.own(fresh: true)).readable, isTrue);
    rig.keys.own.removeWhere((d) => d.deviceId == sibling.idString);
  }

  RemovalQueueRunner realRunner() => RemovalQueueRunner(
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

  Future<void> markRemoved(RigPeer p, Duration ago) =>
      rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingRemovalRecord,
          RemovalRecord(
            removed: [
              RemovalMark(
                deviceId: p.idString,
                atMicros: rig.clock.now().subtract(ago).microsecondsSinceEpoch,
                signatureKey: p.key,
              ),
            ],
          ).encode(),
        ),
      );

  test('reconcile never re-adds a device the user removed', () async {
    final sibling = await RigPeer.create('sibling');
    final sibling2 = await RigPeer.create('sibling2');
    await setUpJoined(ownListed: [sibling, sibling2]);
    ownClaims([sibling, sibling2]);
    seam((id) => rigEq(id, sibling.id));

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests.single.welcomeDeviceIds, [
      sibling2.idString,
    ]);
    expect(await pin(sibling), isNull);
    expect((await pin(sibling2))!.side, MemberSide.mine);
  });

  test('reconcile asks only about own-list devices: a mark naming a peer '
      'device is never consulted (fix round 5, R2)', () async {
    final sibling = await RigPeer.create('sibling');
    final bob2 = await RigPeer.create('bob2');
    await setUpJoined(ownListed: [sibling], alsoListed: [bob2]);
    ownClaims([sibling]);
    peerClaims([bob, bob2]);
    seam((id) => rigEq(id, sibling.id) || rigEq(id, bob2.id));

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests.single.welcomeDeviceIds, [bob2.idString]);
    expect(ownClaimCalls(), isEmpty, reason: 'no claim for a removed device');
    // Asked once a pass (an applied change runs one more pass).
    expect(asked.toSet(), {sibling.idString});
    expect((await pin(bob2))!.side, MemberSide.theirs);
  });

  test('a peer claim carrying a removed own device\'s key under another id '
      'is not added (fix round 1, ruling 2: the cross-side dedupe keeps the '
      'own list\'s keys)', () async {
    final sibling = await RigPeer.create('sibling');
    // The server lists bob2 for bob; it signs with the removed sibling's
    // key under its own id.
    final bob2 = RigPeer.withKeyOf('bob2', sibling);
    await setUpJoined(ownListed: [sibling], alsoListed: [bob2]);
    peerClaims([bob, bob2]);
    ownClaims([sibling]);
    seam((id) => rigEq(id, sibling.id));

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests, isEmpty);
    expect(await pin(bob2), isNull);
    expect(await pin(sibling), isNull);
  });

  test('an unreadable removal queue: reconcile uses only fresh own devices '
      '(a kept own list adds none of its own)', () async {
    final sibling = await RigPeer.create('sibling');
    final sibling2 = await RigPeer.create('sibling2');
    await setUpJoined(ownListed: [sibling]);
    await keptListStillShows(sibling);
    // The fresh list shows a device the kept one did not.
    rig.keys.own.add(rigKeyDevice(sibling2.idString, sibling2.key));
    ownClaims([sibling, sibling2]);
    unreadableQueue();
    final listsBefore = rig.keys.listCalls;

    await rig.upkeep.reconcile(_c1);

    expect(rig.keys.listCalls, listsBefore + 1, reason: 'one fresh own read');
    expect(rig.server.commitRequests.single.welcomeDeviceIds, [
      sibling2.idString,
    ]);
    expect(await pin(sibling), isNull);
  });

  test('an unreadable removal queue and no fresh own list: reconcile adds '
      'no own device this pass, and still adds the peer\'s', () async {
    final sibling = await RigPeer.create('sibling');
    final bob2 = await RigPeer.create('bob2');
    await setUpJoined(ownListed: [sibling], alsoListed: [bob2]);
    expect((await rig.directory.own(fresh: true)).readable, isTrue);
    rig.keys.ownFails = true;
    ownClaims([sibling]);
    peerClaims([bob, bob2]);
    unreadableQueue();

    await rig.upkeep.reconcile(_c1);

    expect(ownClaimCalls(), isEmpty);
    expect(rig.server.commitRequests.single.welcomeDeviceIds, [bob2.idString]);
    expect(await pin(sibling), isNull);
  });

  test('a removed device re-pinned by a peer\'s commit is removed with no '
      'queue entry, though a hostile own list shows it (fix round 1, '
      'ruling 3, SA M2)', () async {
    final sibling = await RigPeer.create('sibling');
    // The own list keeps showing the removed sibling (hostile or stale),
    // so M3 alone would keep it.
    await setUpJoined(ownListed: [sibling]);
    final runner = realRunner();
    await markRemoved(sibling, const Duration(days: 1));
    expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    expect(runner.queuedFor(_c1), isEmpty, reason: 'no queue entry');
    // Bob's commit adds the removed device back; it is pinned on this
    // user's side.
    final at = rig.server.current(_c1);
    final c = await rigCommit(
      offer.add.group,
      add: [await sibling.keyPackage()],
    );
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    await rig.receiver.pullLive(_c1);
    expect((await pin(sibling))!.side, MemberSide.mine);
    rig.server.commitRequests.clear();

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests, hasLength(1));
    expect(await pin(sibling), isNull);
    await runner.idle();
  });

  test('a re-pinned own device whose key is not the removed mark\'s key is '
      'kept (an id alone is no proof)', () async {
    final sibling = await RigPeer.create('sibling');
    await setUpJoined(ownListed: [sibling]);
    final runner = realRunner();
    await rig.device.vault.transaction(
      (tx) => tx.putSetting(
        kVaultSettingRemovalRecord,
        RemovalRecord(
          removed: [
            RemovalMark(
              deviceId: sibling.idString,
              atMicros: rig.clock
                  .now()
                  .subtract(const Duration(days: 1))
                  .microsecondsSinceEpoch,
              signatureKey: bob.key,
            ),
          ],
        ).encode(),
      ),
    );
    expect(await runner.wasRemovedByUser(sibling.id), isTrue);
    final at = rig.server.current(_c1);
    final c = await rigCommit(
      offer.add.group,
      add: [await sibling.keyPackage()],
    );
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    await rig.receiver.pullLive(_c1);
    expect((await pin(sibling))!.side, MemberSide.mine);
    rig.server.commitRequests.clear();

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests, isEmpty);
    expect((await pin(sibling))!.side, MemberSide.mine);
    await runner.idle();
  });

  test('a removal older than the queue\'s memory (expired mark) may be '
      're-added', () async {
    // The bound, documented: the client remembers a removal for
    // kRemovedByUserLimit (30 days, the runner's mark); the server refuses
    // the removed id's re-registration for 90 days (keys RemovalMarkTTL).
    // A device the own list shows again after the client's 30 days is one
    // the server let back in, and reconcile may add it.
    expect(kRemovedByUserLimit, const Duration(days: 30));
    final sibling = await RigPeer.create('sibling');
    await setUpJoined(ownListed: [sibling]);
    ownClaims([sibling]);
    final runner = realRunner();
    await markRemoved(
      sibling,
      kRemovedByUserLimit + const Duration(minutes: 1),
    );
    rig.wasRemovedByUser = runner.wasRemovedByUser;
    expect(await runner.wasRemovedByUser(sibling.id), isFalse);

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests.single.welcomeDeviceIds, [
      sibling.idString,
    ]);
    await runner.idle();
  });

  test('a mark inside the queue\'s memory still keeps the device out (the '
      'runner\'s answer reconcile consults)', () async {
    final sibling = await RigPeer.create('sibling');
    await setUpJoined(ownListed: [sibling]);
    ownClaims([sibling]);
    final runner = realRunner();
    await markRemoved(
      sibling,
      kRemovedByUserLimit - const Duration(minutes: 1),
    );
    rig.wasRemovedByUser = runner.wasRemovedByUser;

    await rig.upkeep.reconcile(_c1);

    expect(rig.server.commitRequests, isEmpty);
    expect(ownClaimCalls(), isEmpty);
    await runner.idle();
  });
}
