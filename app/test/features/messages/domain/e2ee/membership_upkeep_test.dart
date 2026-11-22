import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_upkeep.dart'
    show kMaxChainedRechecks;
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';
const _c3 = '33333333333333333333333333333333';

/// The removal clock's first counting moment after acceptance, plus one
/// second (`kConversationCopyStale` is 60 s).
const Duration _counts = Duration(seconds: 61);

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;

  /// Pipeline errors the running test expects (checked by the tearDown).
  var expectedErrors = <String>[];

  tearDown(() async {
    await rig.upkeep.idle();
    final refused = rig.server.refusedAcks.length;
    final unexpected = [
      for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
    ];
    final expected = expectedErrors;
    expectedErrors = [];
    await rig.dispose();
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
    expect(unexpected, expected, reason: 'unexpected pipeline errors');
  });

  pb.Conversation headerRow({
    String id = _c1,
    Folder folder = Folder.FOLDER_INBOX,
    ConversationState state = ConversationState.CONVERSATION_STATE_REQUEST,
  }) => pb.Conversation(
    id: id,
    peer: common.AuthorSnapshot(userId: 'ref-bob'),
    folder: folder,
    state: state,
    canReply: true,
  );

  /// This device joins [_c1] from bob's welcome (generation 1) with [others]
  /// in the group. The key directory lists, for bob, bob, the [others] that
  /// are not in [ownListed], and [alsoListed]; for the own user, this device
  /// and [ownListed]. [accepted]: the stored sync record says so. [folder]
  /// and [state]: the server's header row.
  Future<void> setUpJoined({
    bool accepted = true,
    List<RigPeer> others = const [],
    List<RigPeer> alsoListed = const [],
    List<RigPeer> ownListed = const [],
    Folder folder = Folder.FOLDER_INBOX,
    ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
  }) async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [
      for (final p in [
        bob,
        for (final o in others)
          if (!ownListed.contains(o)) o,
        ...alsoListed,
      ])
        rigKeyDevice(p.idString, p.key),
    ];
    rig.keys.own.addAll([
      for (final p in ownListed) rigKeyDevice(p.idString, p.key),
    ]);
    if (accepted) await rig.accept(_c1);
    rig.server.rows[_c1] = headerRow(folder: folder, state: state);
    offer = await rig.offer(
      _c1,
      bob,
      others: [for (final o in others) await o.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.calls.clear();
    rig.server.calls.clear();
  }

  /// Commits applied to the server's pair, members attributed and one live
  /// pull of that pair: what a commit needs first.
  Future<void> synced() async {
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    await rig.receiver.pullLive(_c1);
    expect(rig.contexts.of(_c1).syncedSinceStart, isTrue);
  }

  /// Bob commits [add] and [remove] on the server's current pair.
  Future<void> bobCommits({
    List<Uint8List> add = const [],
    List<Uint8List> remove = const [],
  }) async {
    final at = rig.server.current(_c1);
    final c = await rigCommit(offer.add.group, add: add, remove: remove);
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
  }

  Future<ConversationSync> sync([String c = _c1]) async =>
      (await rig.device.vault.conversation(c))?.sync ??
      const ConversationSync();

  Future<void> updateSync(
    ConversationSync Function(ConversationSync s) change, [
    String c = _c1,
  ]) async {
    final next = change(await sync(c));
    await rig.device.vault.transaction((tx) => tx.putConversationSync(c, next));
  }

  Future<MemberRecord?> pin(RigPeer p, [String c = _c1]) async {
    for (final m in await rig.device.vault.members(c)) {
      if (rigEq(m.deviceId, p.id)) return m;
    }
    return null;
  }

  Future<GroupRecord> groupRecord() async =>
      (await rig.device.vault.groups(_c1)).last;

  List<RigCommitCall> requests() => rig.server.commitRequests;

  /// Bob's directory entry list becomes [listed].
  void peerList(List<RigPeer> listed) => rig.keys.peers['ref-bob'] = [
    for (final p in listed) rigKeyDevice(p.idString, p.key),
  ];

  /// The own directory list becomes this device and [listed].
  void ownList(List<RigPeer> listed) => rig.keys.own
    ..clear()
    ..add(rigKeyDevice(rig.device.deviceIdString, rig.device.signatureKey))
    ..addAll([for (final p in listed) rigKeyDevice(p.idString, p.key)]);

  Future<kpb.ClaimedKeyPackage> claimed(
    RigPeer p, {
    bool empty = false,
  }) async => kpb.ClaimedKeyPackage(
    deviceId: p.idString,
    signaturePublicKey: p.key,
    keyPackage: empty ? const <int>[] : await p.keyPackage(),
    hasKeyPackage_4: !empty,
  );

  /// Bob's claims answer [devices] (fresh packages per claim).
  void peerClaims(List<RigPeer> devices, {String conversationId = _c1}) =>
      rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: conversationId,
        keyPackages: [for (final d in devices) await claimed(d)],
      );

  /// The own user's claims answer [devices].
  void ownClaims(List<RigPeer> devices) =>
      rig.keys.claims['user-a'] = () async => kpb.ClaimKeyPackagesResponse(
        keyPackages: [for (final d in devices) await claimed(d)],
      );

  /// Runs the one re-check the upkeep scheduled, as its timer would, and
  /// waits until that re-check has left the conversation lock.
  Future<void> runRecheck() async {
    final live = [
      for (final e in rig.upkeepScheduled)
        if (!e.cancelled) e,
    ];
    expect(live, hasLength(1), reason: 'one re-check per conversation');
    rig.upkeepScheduled.clear();
    live.single.run();
    await rig.upkeep.idle();
    await rig.locks.run(_c1, () async {});
  }

  int liveRechecks() => rig.upkeepScheduled.where((e) => !e.cancelled).length;

  Future<List<SystemLineContent>> lines([String c = _c1]) => rig.lines(c);

  bool added(List<SystemLineContent> ls, RigPeer p, String side) => ls.any(
    (l) =>
        l.line == SystemLine.deviceAdded &&
        l.side == side &&
        rigEq(l.deviceId ?? const [], p.id),
  );

  /// Another conversation [c] whose stored sync record says [accepted],
  /// with a group (so the vault is not brand new once it is accepted) and
  /// [mine] pinned as own devices.
  Future<void> otherConversation(
    String c, {
    required bool accepted,
    List<RigPeer> mine = const [],
  }) => rig.device.vault.transaction((tx) async {
    await tx.putConversationSync(
      c,
      ConversationSync(requestAccepted: accepted),
    );
    await tx.putGroup(
      GroupRecord(
        conversationId: c,
        generation: 1,
        epoch: 1,
        state: Uint8List.fromList([1, 2, 3]),
      ),
    );
    for (final p in mine) {
      await tx.putMember(
        MemberRecord(
          conversationId: c,
          deviceId: p.id,
          signatureKey: p.key,
          side: MemberSide.mine,
          since: const MlsPair(1, 1),
        ),
      );
    }
  });

  /// Bob adds a device that no list shows ([ghost]) and this device applies
  /// it with counting lists, so attribution concludes it unknown now.
  Future<void> ghostAdded(RigPeer ghost) async {
    rig.clock.advance(_counts);
    await bobCommits(add: [await ghost.keyPackage()]);
    await synced();
    expect((await pin(ghost))!.side, MemberSide.unattributed);
    expect(rig.contexts.of(_c1).firstSeenUnattributed, isNotEmpty);
  }

  // -------------------------------------------------------------------------

  group('the request rules (R10)', () {
    test(
      'an unaccepted conversation makes no list call and no commit',
      () async {
        final sibling = await RigPeer.create('sibling');
        final bob2 = await RigPeer.create('bob2');
        await setUpJoined(
          accepted: false,
          others: [sibling],
          alsoListed: [bob2],
          ownListed: [sibling],
          state: ConversationState.CONVERSATION_STATE_REQUEST,
        );
        await synced();
        // A removal (sibling not listed), an add (bob2), a queued removal, a
        // due self-update and a lost send would all be made if accepted.
        ownList(const []);
        peerClaims([bob, bob2]);
        rig.upkeep.queuedRemovals = (_) => {sibling.id};
        await updateSync((s) => s.copyWith(epochMustAdvance: true));
        rig.clock.advance(kSelfUpdateEvery + const Duration(days: 1));
        final listsBefore = rig.keys.listCalls;
        final getsBefore = rig.keys.getCalls.length;
        rig.server.calls.clear();

        await rig.upkeep.reconcile(_c1);
        await rig.upkeep.selfUpdateIfDue(_c1);

        expect(rig.keys.listCalls, listsBefore);
        expect(rig.keys.getCalls, hasLength(getsBefore));
        expect(rig.keys.claimCalls, isEmpty);
        expect(rig.server.calls, isEmpty);
        expect(requests(), isEmpty);
        expect(rig.upkeepScheduled, isEmpty);
      },
    );
  });

  group('adds (M1)', () {
    test('an active device missing from the group is claimed, checked and '
        'added', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(alsoListed: [bob2]);
      await synced();
      peerClaims([bob, bob2]);

      await rig.upkeep.reconcile(_c1);

      expect(rig.keys.claimCalls.single.userId, 'ref-bob');
      expect(rig.keys.claimCalls.single.excludeDeviceId, '');
      expect(requests().single.welcomeDeviceIds, [bob2.idString]);
      expect((await groupRecord()).epoch, 2);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      expect(added(await lines(), bob2, MemberSide.theirs), isTrue);
    });

    test('an own device a start left out is claimed for this user, without '
        'this device, and added (brief amendment 9)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpJoined(ownListed: [sibling]);
      await synced();
      ownClaims([sibling]);

      await rig.upkeep.reconcile(_c1);

      final call = rig.keys.claimCalls.single;
      expect(call.userId, 'user-a');
      expect(call.excludeDeviceId, rig.device.deviceIdString);
      expect(requests().single.welcomeDeviceIds, [sibling.idString]);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('an inactive listed device is not added and not removed', () async {
      final bob2 = await RigPeer.create('bob2');
      final bob3 = await RigPeer.create('bob3');
      await setUpJoined(others: [bob2]);
      await synced();
      rig.clock.advance(kDeviceListReuse + _counts);
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(bob2.idString, bob2.key)..inactive = true,
        rigKeyDevice(bob3.idString, bob3.key)..inactive = true,
      ];
      peerClaims([bob]);

      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kPeerRemovalFetchGap * 2);
      await rig.upkeep.reconcile(_c1);

      expect(rig.keys.claimCalls, isEmpty);
      expect(requests(), isEmpty);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      expect(await pin(bob3), isNull);
    });

    test('a listed device the key history refuses is not claimed (brief '
        'amendment 6)', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(alsoListed: [bob2]);
      await synced();
      // bob2's id was seen with another key here: tainted for good.
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key)],
        changed: [bob2.id],
      );
      peerClaims([bob, bob2]);

      await rig.upkeep.reconcile(_c1);

      expect(rig.keys.claimCalls, isEmpty);
      expect(requests(), isEmpty);
    });

    test('a peer claim that names another conversation adds nothing', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(alsoListed: [bob2]);
      await synced();
      peerClaims([bob, bob2], conversationId: _c2);

      await rig.upkeep.reconcile(_c1);

      expect(rig.keys.claimCalls, hasLength(1));
      expect(requests(), isEmpty);
      expect(await pin(bob2), isNull);
    });

    test(
      'an empty claim for a listed device is tried once per IST day',
      () async {
        final bob2 = await RigPeer.create('bob2');
        await setUpJoined(alsoListed: [bob2]);
        await synced();
        rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
          conversationId: _c1,
          keyPackages: [await claimed(bob), await claimed(bob2, empty: true)],
        );

        await rig.upkeep.reconcile(_c1);
        expect(rig.keys.claimCalls, hasLength(1));
        expect(await rig.ledger.emptyClaimTried(bob2.id), isTrue);
        expect(requests(), isEmpty);

        rig.clock.advance(const Duration(hours: 1));
        await rig.upkeep.reconcile(_c1);
        expect(rig.keys.claimCalls, hasLength(1));

        rig.clock.advance(const Duration(days: 1));
        await rig.upkeep.reconcile(_c1);
        expect(rig.keys.claimCalls, hasLength(2));
      },
    );
  });

  group('removals (M2, M3, M4)', () {
    test('an own device absent from the own list is removed with one '
        'fetch', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpJoined(others: [sibling], ownListed: [sibling]);
      await synced();
      expect((await pin(sibling))!.side, MemberSide.mine);
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);
      final before = rig.keys.listCalls;

      await rig.upkeep.reconcile(_c1);

      expect(rig.keys.listCalls, before + 1);
      final request = requests().single;
      expect(request.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect((await groupRecord()).epoch, 2);
    });

    test('a peer device missing once is not removed; missing again 2 minutes '
        'later it is', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      final accepted = rig.contexts.of(_c1).acceptedSeenAt!;
      peerList([bob]);
      // PR A coupling: a fetch 59 s after acceptance does not count.
      rig.directory.clear();
      rig.clock.value = accepted.add(const Duration(seconds: 59));
      await rig.upkeep.reconcile(_c1);
      expect(rig.contexts.of(_c1).firstMiss, isEmpty);
      expect(requests(), isEmpty);

      // One re-check at the first counting moment: the first miss.
      rig.clock.value = accepted.add(const Duration(seconds: 60));
      await runRecheck();
      expect(rig.contexts.of(_c1).firstMiss, hasLength(1));
      expect(requests(), isEmpty);
      expect((await pin(bob2))!.side, MemberSide.theirs);

      // Missing again 2 minutes later, on a fresh fetch: removed.
      final gets = rig.keys.getCalls.length;
      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();
      expect(rig.keys.getCalls, hasLength(gets + 1));
      expect(await pin(bob2), isNull);
      expect(requests().single.welcome, isNull);
    });

    test(
      'a device listed again clears its first miss (PR 1 carryover)',
      () async {
        final bob2 = await RigPeer.create('bob2');
        await setUpJoined(others: [bob2]);
        await synced();
        rig.clock.advance(kDeviceListReuse + _counts);
        peerList([bob]);
        await rig.upkeep.reconcile(_c1);
        expect(rig.contexts.of(_c1).firstMiss, hasLength(1));

        // Listed again by the re-check's counting fetch.
        peerList([bob, bob2]);
        rig.clock.advance(kPeerRemovalFetchGap);
        await runRecheck();
        expect(rig.contexts.of(_c1).firstMiss, isEmpty);

        // Missing again: the 2 minutes start again from this fetch.
        peerList([bob]);
        rig.clock.advance(kDeviceListReuse);
        await rig.upkeep.reconcile(_c1);
        expect(requests(), isEmpty);
        expect((await pin(bob2))!.side, MemberSide.theirs);
        rig.clock.advance(kPeerRemovalFetchGap);
        await runRecheck();
        expect(await pin(bob2), isNull);
      },
    );

    test('an empty peer list removes nothing', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      rig.clock.advance(kDeviceListReuse + _counts);
      peerList(const []);

      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kPeerRemovalFetchGap * 2);
      rig.directory.clear();
      await rig.upkeep.reconcile(_c1);

      expect(rig.contexts.of(_c1).firstMiss, isEmpty);
      expect(requests(), isEmpty);
      expect((await pin(bob2))!.side, MemberSide.theirs);
    });

    test('an unreadable peer list removes nothing, sets '
        'deviceListUnverifiable and sends continue', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      rig.clock.advance(kDeviceListReuse + _counts);
      rig.keys.peerFails = true;

      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kPeerRemovalFetchGap * 2);
      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      final state = await rig.crypto.describeState(_c1);
      expect(state.deviceListUnverifiable, isTrue);
      expect(state.sendBlock, SendBlock.none);
    });

    test('a rate-limited list changes nothing and sets no warning', () async {
      final bob2 = await RigPeer.create('bob2');
      final ghost = await RigPeer.create('ghost');
      await setUpJoined(others: [bob2]);
      await synced();
      // With no unattributed member.
      rig.clock.advance(kDeviceListReuse + _counts);
      peerList([bob]);
      rig.keys.peerError = const RateLimitedException(
        'rig',
        retryAfter: Duration(hours: 2),
      );
      await rig.upkeep.reconcile(_c1);
      expect(requests(), isEmpty);
      expect(rig.contexts.of(_c1).firstMiss, isEmpty);
      expect(
        (await rig.crypto.describeState(_c1)).deviceListUnverifiable,
        isFalse,
      );

      // With one, for up to 30 minutes (security read M4): still silent.
      await bobCommits(add: [await ghost.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await pin(ghost))!.side, MemberSide.unattributed);
      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kDeferredWithUnattributedLimit);
      await rig.upkeep.reconcile(_c1);
      expect(
        (await rig.crypto.describeState(_c1)).deviceListUnverifiable,
        isFalse,
      );
      expect(requests(), isEmpty);
      expect((await pin(bob2))!.side, MemberSide.theirs);
    });

    test('a deferral over 30 minutes with an unattributed member sets '
        'deviceListUnverifiable and removes nothing', () async {
      final ghost = await RigPeer.create('ghost');
      await setUpJoined();
      await synced();
      await ghostAdded(ghost);
      rig.keys.peerError = const RateLimitedException(
        'rig',
        retryAfter: Duration(hours: 2),
      );
      rig.clock.advance(kDeviceListReuse);
      await rig.upkeep.reconcile(_c1);
      expect(
        (await rig.crypto.describeState(_c1)).deviceListUnverifiable,
        isFalse,
      );

      rig.clock.advance(
        kDeferredWithUnattributedLimit + const Duration(seconds: 1),
      );
      await rig.upkeep.reconcile(_c1);

      expect(
        (await rig.crypto.describeState(_c1)).deviceListUnverifiable,
        isTrue,
      );
      expect(requests(), isEmpty);
      expect((await pin(ghost))!.side, MemberSide.unattributed);
    });

    test('the peer\'s last device is never removed', () async {
      final carol = await RigPeer.create('carol');
      await setUpJoined();
      await synced();
      rig.clock.advance(kDeviceListReuse + _counts);
      // A readable, non-empty list that lacks bob's only device.
      peerList([carol]);
      peerClaims(const []);

      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();
      rig.clock.advance(kPeerRemovalFetchGap * 3);
      rig.directory.clear();
      await rig.upkeep.reconcile(_c1);

      expect(
        requests().where((r) => r.welcome == null),
        isEmpty,
        reason: 'no removal',
      );
      expect((await pin(bob))!.side, MemberSide.theirs);
    });

    test('removals decided in one pass keep the peer\'s last device (the '
        'count is per call, PR 1 carryover)', () async {
      final bob2 = await RigPeer.create('bob2');
      final bob3 = await RigPeer.create('bob3');
      final carol = await RigPeer.create('carol');
      await setUpJoined(others: [bob2, bob3]);
      await synced();
      rig.clock.advance(kDeviceListReuse + _counts);
      // None of bob's three devices is listed any more.
      peerList([carol]);
      peerClaims(const []);
      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();

      final removed = [
        for (final p in [bob, bob2, bob3])
          if (await pin(p) == null) p,
      ];
      expect(removed, hasLength(2));
      expect(
        (await rig.device.vault.members(_c1))
            .where((m) => m.side == MemberSide.theirs),
        hasLength(1),
      );
    });

    test('an unattributed member is re-checked after 2 minutes and removed '
        'only with both lists readable', () async {
      final ghost = await RigPeer.create('ghost');
      await setUpJoined();
      await synced();
      await ghostAdded(ghost);

      // Before the 2 minutes: nothing, one re-check at their end.
      rig.clock.advance(const Duration(minutes: 1));
      await rig.upkeep.reconcile(_c1);
      expect(requests(), isEmpty);
      expect(liveRechecks(), 1);

      // At the re-check the own list cannot be read: kept.
      rig.clock.advance(const Duration(minutes: 1));
      rig.keys.ownFails = true;
      await runRecheck();
      expect(requests(), isEmpty);
      expect((await pin(ghost))!.side, MemberSide.unattributed);

      // Both readable: removed.
      rig.keys.ownFails = false;
      await rig.upkeep.reconcile(_c1);
      expect(await pin(ghost), isNull);
      expect(requests().single.welcome, isNull);
    });

    test('an unrecorded or unreadable member is never removed automatically '
        '(the call site passes the key history\'s refusal)', () async {
      final ghost = await RigPeer.create('ghost');
      await setUpJoined();
      await synced();
      // The history is closed: a new id is only remembered (unrecorded).
      await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], closed: true);
      await ghostAdded(ghost);
      // Never removable: no re-check is even armed for it.
      await rig.upkeep.reconcile(_c1);
      expect(liveRechecks(), 0);
      // Well past the 2 minutes, with both lists readable and counting.
      rig.clock.advance(kUnattributedRecheck);
      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kUnattributedRecheck);
      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(ghost))!.side, MemberSide.unattributed);

      // Unreadable: the history no longer opens.
      expectedErrors = ['keyHistory.read'];
      await rig.device.vault.transaction(
        (tx) => tx.putSetting('messages.e2ee.keys.$_c1', rigBytes('broken')),
      );
      rig.clock.advance(kUnattributedRecheck);
      await rig.upkeep.reconcile(_c1);
      expect(requests(), isEmpty);
      expect((await pin(ghost))!.side, MemberSide.unattributed);
    });

    test('a tainted member whose current key the directory lists is not '
        'removed automatically', () async {
      final ghost = await RigPeer.create('ghost');
      await setUpJoined();
      await synced();
      await ghostAdded(ghost);
      // The ghost's id is tainted (seen here with another key), and its
      // current pair is now listed: a hostile member may have tainted an
      // honest device's id before it joined.
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key)],
        changed: [ghost.id],
      );
      peerList([bob, ghost]);
      rig.clock.advance(kUnattributedRecheck + kDeviceListReuse);
      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kUnattributedRecheck);
      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(ghost))!.side, MemberSide.unattributed);
    });

    test('removals and adds go in one commit, removals alone with the flag '
        'off', () async {
      final sib1 = await RigPeer.create('sib1');
      final sib2 = await RigPeer.create('sib2');
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(
        others: [sib1, sib2],
        ownListed: [sib1, sib2],
        alsoListed: [bob2],
      );
      await synced();
      peerClaims([bob, bob2]);

      // Flag off: sib1's removal goes alone, and nothing is claimed.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: rig.device.uid);
      rig.clock.advance(kDeviceListReuse);
      ownList([sib2]);
      await rig.upkeep.reconcile(_c1);
      expect(rig.keys.claimCalls, isEmpty);
      expect(requests().single.welcome, isNull);
      expect(await pin(sib1), isNull);

      // Flag on: sib2's removal and bob2's add in one commit.
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: rig.device.uid);
      await synced();
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);
      await rig.upkeep.reconcile(_c1);
      expect(requests(), hasLength(2));
      expect(requests().last.welcomeDeviceIds, [bob2.idString]);
      expect(await pin(sib2), isNull);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      expect((await groupRecord()).epoch, 3);
    });

    test('a removal is committed alone when the add in the same pass cannot '
        'be built (audit M1)', () async {
      final sibling = await RigPeer.create('sibling');
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(
        others: [sibling],
        ownListed: [sibling],
        alsoListed: [bob2],
      );
      await synced();
      peerClaims([bob, bob2]);
      // The lost phone is deregistered; bob2's package passes every check,
      // but the engine refuses to build a commit that adds it.
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);
      rig.device.engine.failNext['commitChange'] = const MlsException(
        MlsErrorCode.badInput,
        'rig: a package the core refuses',
      );

      await rig.upkeep.reconcile(_c1);

      // The removal went alone, in this same pass.
      expect(requests().single.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect(await pin(bob2), isNull);
      // bob2 is tried for the IST day: the pass after the removal does not
      // claim it again.
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await rig.ledger.emptyClaimTried(bob2.id), isTrue);
      rig.clock.advance(kDeviceListReuse);
      await synced();
      await rig.upkeep.reconcile(_c1);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(requests(), hasLength(1));
    });

    test(
      'a removal is committed alone when the server refuses the change '
      'that also adds, and the add is tried for the day (audit M1)',
      () async {
        final sibling = await RigPeer.create('sibling');
        final bob2 = await RigPeer.create('bob2');
        await setUpJoined(
          others: [sibling],
          ownListed: [sibling],
          alsoListed: [bob2],
        );
        await synced();
        peerClaims([bob, bob2]);
        rig.clock.advance(kDeviceListReuse);
        ownList(const []);
        rig.server.commitScript.add((
          error: const ValidationException('commit', field: 'commit'),
          stored: false,
        ));

        await rig.upkeep.reconcile(_c1);

        expect(requests(), hasLength(2));
        expect(requests().first.welcome, isNotNull);
        expect(requests().last.welcome, isNull);
        expect(await pin(sibling), isNull);
        expect(await pin(bob2), isNull);
        expect(await rig.ledger.emptyClaimTried(bob2.id), isTrue);
        expect(rig.keys.claimCalls, hasLength(1));
      },
    );

    test('an add that fails its check is claimed at most once per IST day '
        '(audit M1)', () async {
      final bob2 = await RigPeer.create('bob2');
      final other = await RigPeer.create('other');
      await setUpJoined(alsoListed: [bob2]);
      await synced();
      // The claim answers bob2's package under another signature key: the
      // inspection names bob2's real key, so checkClaims drops it.
      rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [
          kpb.ClaimedKeyPackage(
            deviceId: bob2.idString,
            signaturePublicKey: other.key,
            keyPackage: await bob2.keyPackage(),
            hasKeyPackage_4: true,
          ),
        ],
      );

      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kDeviceListReuse);
      await rig.upkeep.reconcile(_c1);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(requests(), isEmpty);

      // The next IST day it is claimed once more.
      rig.clock.advance(const Duration(days: 1));
      await rig.upkeep.reconcile(_c1);
      expect(rig.keys.claimCalls, hasLength(2));
      expect(requests(), isEmpty);
    });

    test('after superseded the reconciliation runs again on the new group and '
        'no rebuilt add is sent', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(alsoListed: [bob2]);
      await synced();
      peerClaims([bob, bob2]);
      var raced = false;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || raced) return;
        raced = true;
        // Bob's own add of the same device lands first.
        await bobCommits(add: [await bob2.keyPackage()]);
      };

      await rig.upkeep.reconcile(_c1);

      expect(raced, isTrue);
      expect(requests(), hasLength(1));
      expect(rig.keys.claimCalls, hasLength(1));
      expect((await groupRecord()).epoch, 2);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      // The second run was made: on the new group, with bob2 a member.
      expect(
        rig.server.calls.where((c) => c == 'listConversationCommits'),
        hasLength(greaterThanOrEqualTo(2)),
      );
    });

    test('a removal decided after superseded is committed after the next '
        'live pull: a lost own phone goes in the same reconcile (review '
        'I1)', () async {
      final sibling = await RigPeer.create('sibling');
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(
        others: [sibling],
        ownListed: [sibling],
        alsoListed: [bob2],
      );
      await synced();
      peerClaims([bob, bob2]);
      // The lost phone is deregistered; bob2 is to be added.
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);
      var raced = false;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || raced) return;
        raced = true;
        // Bob's own add of bob2 wins the pair: this commit is superseded.
        await bobCommits(add: [await bob2.keyPackage()]);
      };

      await rig.upkeep.reconcile(_c1);

      expect(raced, isTrue);
      expect(requests(), hasLength(2));
      // The second commit removes the phone and adds nothing again.
      expect(requests().last.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      expect((await groupRecord()).epoch, 3);
      expect(rig.keys.claimCalls, hasLength(1));
    });

    test('a change decided while not synced arms one re-check, which pulls '
        'and commits; re-checks whose pull fails chain at most 3 (review I1 '
        'c, ruling C)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpJoined(others: [sibling], ownListed: [sibling]);
      await synced();
      // This device's own earlier commit moved the pair: no live pull of
      // the new pair since.
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);
      expect(requests(), hasLength(1));
      rig.server.commitRequests.clear();
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);

      await rig.upkeep.reconcile(_c1);
      expect(rig.contexts.of(_c1).syncedSinceStart, isFalse);
      expect(requests(), isEmpty);
      expect(liveRechecks(), 1);
      expect(
        rig.clock.now().add(rig.upkeepScheduled.last.delay),
        rig.clock.now().add(kPeerRemovalFetchGap),
      );

      // Every re-check's pull fails: no commit. Each arms one more, and
      // the third chained one arms none (no loop).
      rig.server.onCall = (call) async {
        if (call == 'listMlsMessages' ||
            call == 'listEpochMessages' ||
            call == 'listMessageTombstones') {
          throw const NetworkException('rig: offline');
        }
      };
      for (var chained = 1; chained <= kMaxChainedRechecks; chained++) {
        expect(liveRechecks(), 1, reason: 're-check $chained is armed');
        rig.clock.advance(kPeerRemovalFetchGap);
        await runRecheck();
        expect(requests(), isEmpty);
      }
      expect(liveRechecks(), 0);
      expect((await pin(sibling))!.side, MemberSide.mine);

      // The next open arms one again; its re-check pulls and removes.
      rig.server.onCall = null;
      await rig.upkeep.reconcile(_c1);
      expect(liveRechecks(), 1);
      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();
      expect(requests(), hasLength(1));
      expect(await pin(sibling), isNull);
      expect(liveRechecks(), 0);
    });

    test('two undos today pause adds until the next IST day, and an M3 '
        'removal still commits (audit L2, ruling H)', () async {
      final sibling = await RigPeer.create('sibling');
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(
        others: [sibling],
        ownListed: [sibling],
        alsoListed: [bob2],
      );
      await synced();
      peerClaims([bob, bob2]);
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);

      await rig.upkeep.reconcile(_c1);
      // The lost own phone goes, alone; the add waits.
      expect(requests().single.welcome, isNull);
      expect(await pin(sibling), isNull);
      // No key package is spent on an add that cannot be made.
      expect(rig.keys.claimCalls, isEmpty);
      expect(await pin(bob2), isNull);

      rig.clock.advance(const Duration(days: 1));
      await synced();
      await rig.upkeep.reconcile(_c1);
      expect(requests(), hasLength(2));
      expect((await pin(bob2))!.side, MemberSide.theirs);
    });

    test('the M5 pause still holds a peer-side automatic removal (ruling '
        'H)', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      // bob2 is missing from two counting fetches 2 minutes apart.
      peerList([bob]);
      rig.clock.advance(kDeviceListReuse + _counts);
      await rig.upkeep.reconcile(_c1);
      rig.clock.advance(kPeerRemovalFetchGap);
      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(bob2))!.side, MemberSide.theirs);
    });

    test('an unreadable ledger, then a queued removal still commits (audit '
        'L2, ruling H)', () async {
      final sibling = await RigPeer.create('sibling');
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(
        others: [sibling],
        ownListed: [sibling],
        alsoListed: [bob2],
      );
      await synced();
      peerClaims([bob, bob2]);
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingE2eeDaily, rigBytes('not json')),
      );
      expectedErrors = ['daily.read'];
      // The user asked for the removal (Task 11's queue); the own list
      // still shows the device.
      rig.upkeep.queuedRemovals = (_) => {sibling.id};

      await rig.upkeep.reconcile(_c1);

      expect(requests().single.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await pin(bob2), isNull);
      expect((await rig.ledger.read()).exhausted, isTrue);
    });
  });

  group('a pending record (9a decision 2)', () {
    test('a reconcile with a pending record resends its bytes before any '
        'list call, and a pending answer ends the pass', () async {
      const offline = NetworkException('rig: no answer');
      final sibling = await RigPeer.create('sibling');
      await setUpJoined(others: [sibling], ownListed: [sibling]);
      await synced();
      // Two calls with no answer: the self-update's record stays pending.
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(2));
      // A removal the pass would make once it got past the record.
      rig.clock.advance(kDeviceListReuse + kRequestInFlightMargin);
      ownList(const []);
      final lists = rig.keys.listCalls;
      final gets = rig.keys.getCalls.length;
      int? listsAtCommit;
      int? getsAtCommit;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        listsAtCommit ??= rig.keys.listCalls;
        getsAtCommit ??= rig.keys.getCalls.length;
      };
      rig.server.calls.clear();
      // The resend gets no answer either.
      rig.server.commitScript.add((error: offline, stored: false));

      await rig.upkeep.reconcile(_c1);

      // The identical bytes went out before any list call.
      expect(requests(), hasLength(3));
      expect(requests()[2].sameBytes(requests()[0]), isTrue);
      expect(listsAtCommit, lists);
      expect(getsAtCommit, gets);
      // `pending` ended the pass: nothing after the call.
      expect(rig.server.calls.last, 'commitConversation');
      expect(
        rig.server.calls.skipWhile((c) => c != 'commitConversation').skip(1),
        isEmpty,
      );
      expect(rig.keys.listCalls, lists);
      expect(rig.keys.getCalls, hasLength(gets));
      expect(rig.keys.claimCalls, isEmpty);
      expect((await groupRecord()).pending, isNotNull);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });
  });

  group('a change that did not land (review I-A, audit L1, review m-1)', () {
    const offline = NetworkException('rig: no answer');

    /// A lost own phone (sibling) for the next reconcile to remove.
    Future<RigPeer> lostPhone() async {
      final sibling = await RigPeer.create('sibling');
      await setUpJoined(others: [sibling], ownListed: [sibling]);
      await synced();
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);
      return sibling;
    }

    test('a commit left pending by two unanswered calls is resent by one '
        're-check after the margin, and the waiting reply then goes '
        'out', () async {
      final sibling = await lostPhone();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));

      await rig.upkeep.reconcile(_c1);
      expect(requests(), hasLength(2));
      expect((await groupRecord()).pending, isNotNull);
      // One re-check, at the runner's not-before (the margin).
      expect(liveRechecks(), 1);
      expect(rig.upkeepScheduled.last.delay, kRequestInFlightMargin);

      // The user replies meanwhile: the reply waits behind the record.
      await rig.sender.enqueue(
        localId: 'r1',
        conversationId: _c1,
        text: 'hello',
      );
      await rig.sender.settled(_c1);
      expect(rig.server.sends, isEmpty);

      rig.clock.advance(kRequestInFlightMargin);
      await runRecheck();
      expect(requests(), hasLength(3));
      expect(requests()[2].sameBytes(requests()[0]), isTrue);
      expect((await groupRecord()).pending, isNull);
      expect(await pin(sibling), isNull);

      // The waiting reply goes out at the next drain.
      await rig.sender.drain(_c1);
      expect(rig.server.sends, hasLength(1));
    });

    test('a re-check that still does not land arms one more, at most 3 '
        'chained re-checks, then none', () async {
      final sibling = await lostPhone();
      // No commit call ever gets an answer.
      for (var i = 0; i < 10; i++) {
        rig.server.commitScript.add((error: offline, stored: false));
      }

      await rig.upkeep.reconcile(_c1);
      expect(requests(), hasLength(2));
      for (var chained = 1; chained <= 3; chained++) {
        expect(liveRechecks(), 1, reason: 're-check $chained is armed');
        rig.clock.advance(kRequestInFlightMargin);
        await runRecheck();
        expect(requests(), hasLength(2 + chained));
      }
      // The third chained re-check arms none: the outside triggers (Task
      // 13) take over.
      expect(liveRechecks(), 0);
      expect((await pin(sibling))!.side, MemberSide.mine);

      // An outside trigger starts a new chain.
      rig.clock.advance(kRequestInFlightMargin);
      await rig.upkeep.reconcile(_c1);
      expect(liveRechecks(), 1);
    });

    test('a RATE_LIMITED removal arms one re-check at the server\'s retry '
        'time, which removes it', () async {
      final sibling = await lostPhone();
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'slow down',
          retryAfter: Duration(minutes: 3),
        ),
        stored: false,
      ));

      await rig.upkeep.reconcile(_c1);
      expect(requests(), hasLength(1));
      expect((await pin(sibling))!.side, MemberSide.mine);
      expect(liveRechecks(), 1);
      expect(rig.upkeepScheduled.last.delay, const Duration(minutes: 3));

      rig.clock.advance(const Duration(minutes: 3));
      await runRecheck();
      expect(requests(), hasLength(2));
      expect(await pin(sibling), isNull);
      expect(liveRechecks(), 0);
    });

    test('a resume that settles the record arms no re-check when the same '
        'reconcile pulls and runs again (review m-2)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpJoined(others: [sibling], ownListed: [sibling]);
      await synced();
      // A self-update left pending by two unanswered calls.
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      // The lost phone is decided by the pass after the resume.
      rig.clock.advance(kDeviceListReuse + kRequestInFlightMargin);
      ownList(const []);

      await rig.upkeep.reconcile(_c1);

      // The resend landed, the pull ran and the second pass removed the
      // phone: nothing is left to re-check.
      expect(requests(), hasLength(4));
      expect((await groupRecord()).pending, isNull);
      expect(await pin(sibling), isNull);
      expect(liveRechecks(), 0);
    });

    test('a second pass whose commit is superseded again arms one re-check '
        '(review m-1)', () async {
      final sibling = await lostPhone();
      final bob2 = await RigPeer.create('bob2');
      final bob3 = await RigPeer.create('bob3');
      peerList([bob, bob2, bob3]);
      peerClaims([bob, bob2, bob3]);
      // Bob's own commits win the pair twice: first he adds bob2, then
      // bob3, each while this device's commit is on its way.
      final racing = [bob2, bob3];
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || racing.isEmpty) return;
        await bobCommits(add: [await racing.removeAt(0).keyPackage()]);
      };

      await rig.upkeep.reconcile(_c1);
      expect(requests(), hasLength(2));
      expect((await pin(sibling))!.side, MemberSide.mine);
      expect(liveRechecks(), 1);
      expect(rig.upkeepScheduled.last.delay, kPeerRemovalFetchGap);

      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();
      expect(await pin(sibling), isNull);
    });
  });

  group('self-update (R9, R7)', () {
    test('self-update is due at 30 days, only from open or send, and not at '
        '10 calls today', () async {
      await setUpJoined();
      await synced();
      rig.clock.advance(kSelfUpdateEvery - const Duration(days: 1));
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), isEmpty);

      // Due now; time passing alone makes no call and schedules nothing.
      rig.clock.advance(const Duration(days: 1));
      expect(requests(), isEmpty);
      expect(rig.upkeepScheduled, isEmpty);

      // Not at 10 calls today.
      await updateSync(
        (s) => s.copyWith(
          commitCallsDay: istDay(rig.clock.now()),
          commitCallsToday: kSelfUpdateMaxCommitCallsToday,
        ),
      );
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), isEmpty);

      // Opened (or sent in) with calls left: one self-update, and the date
      // renews.
      await updateSync((s) => s.copyWith(commitCallsToday: 0));
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), hasLength(1));
      expect(requests().single.welcome, isNull);
      expect(
        (await sync()).lastSelfUpdateAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      // Not due again the same day.
      await synced();
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), hasLength(1));
    });

    test('a re-check timer makes no self-update', () async {
      final carol = await RigPeer.create('carol');
      await setUpJoined();
      await synced();
      rig.clock.advance(kSelfUpdateEvery + _counts);
      peerList([carol]);
      peerClaims(const []);
      // Bob's only device is unlisted: a re-check is scheduled, and the
      // last device is never removed. Opened now: the open path renews.
      rig.directory.clear();
      await updateSync(
        (s) => s.copyWith(
          lastSelfUpdateAtMicros: rig.clock.now().microsecondsSinceEpoch,
        ),
      );
      await rig.upkeep.reconcile(_c1);
      expect(liveRechecks(), 1);
      // Thirty days on, only the timer runs: no self-update.
      await updateSync((s) => s.copyWith(lastSelfUpdateAtMicros: 0));
      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();
      expect(requests(), isEmpty);

      // At 10 calls today an open makes none either.
      await updateSync(
        (s) => s.copyWith(
          commitCallsDay: istDay(rig.clock.now()),
          commitCallsToday: kSelfUpdateMaxCommitCallsToday,
        ),
      );
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), isEmpty);
      // Below it, it does.
      await updateSync((s) => s.copyWith(commitCallsToday: 9));
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), hasLength(1));
    });

    test('a lost send makes one self-update that day when no commit arrives, '
        'and none the second time', () async {
      await setUpJoined();
      await synced();
      await updateSync((s) => s.copyWith(epochMustAdvance: true));

      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), hasLength(1));
      expect((await sync()).epochMustAdvance, isFalse);
      expect(await rig.ledger.lostSendUpdateDone(_c1), isTrue);

      // Again the same day: none.
      await synced();
      await updateSync((s) => s.copyWith(epochMustAdvance: true));
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), hasLength(1));

      // The next IST day: one more.
      rig.clock.advance(const Duration(days: 1));
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(requests(), hasLength(2));
    });

    test(
      'a lost send whose epoch a commit advances makes no self-update',
      () async {
        await setUpJoined();
        await synced();
        await updateSync((s) => s.copyWith(epochMustAdvance: true));
        // Bob's commit is waiting at the server: catch-up applies it.
        final c = await bob.engine.selfUpdate(bob.state, offer.add.group.state);
        offer.add.group.state = await bob.engine.confirmCommit(
          bob.state,
          c.groupState,
        );
        rig.server.addCommit(
          _c1,
          rig.server.current(_c1),
          c.commit,
          fromUser: 'user-b',
        );

        await rig.upkeep.selfUpdateIfDue(_c1);

        expect(requests(), isEmpty);
        expect((await sync()).epochMustAdvance, isFalse);
        expect(await rig.ledger.lostSendUpdateDone(_c1), isFalse);
      },
    );
  });

  group('acceptance (R10, H2, M3)', () {
    /// An incoming request: this device joined bob's group with [sibling]
    /// (an own device) in it; both are attributed during the request.
    Future<void> setUpRequest(RigPeer sibling) async {
      await setUpJoined(
        accepted: false,
        others: [sibling],
        ownListed: [sibling],
        folder: Folder.FOLDER_REQUESTS,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );
      await synced();
      expect((await pin(sibling))!.side, MemberSide.mine);
      expect(rig.contexts.of(_c1).incomingRequest, isTrue);
      expect(rig.contexts.of(_c1).requestSeenInHeader, isTrue);
      rig.realAcceptance = true;
    }

    Future<void> send(String localId) async {
      await rig.sender.enqueue(
        localId: localId,
        conversationId: _c1,
        text: 'hi',
      );
      await rig.sender.settled(_c1);
    }

    test('acceptForReply accepts, runs queued removals and attribution, then '
        'lets the reply encrypt', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      final events = <String>[];
      rig.server.onCall = (call) async {
        if (call == 'acceptMessageRequest' ||
            call == 'commitConversation' ||
            call == 'sendEncrypted') {
          events.add(call);
        }
      };

      await send('l1');

      expect(events, [
        'acceptMessageRequest',
        'commitConversation',
        'sendEncrypted',
      ]);
      expect(rig.acceptPriorities, [BudgetPriority.user]);
      expect((await sync()).requestAccepted, isTrue);
      expect(rig.contexts.of(_c1).incomingRequest, isFalse);
      expect(rig.contexts.of(_c1).acceptedSeenAt, isNotNull);
      expect(await pin(sibling), isNull);
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
    });

    test('the acceptance removes a queued own device the own list still '
        'shows, in its one commit, with no wait (review m3)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // Nothing else would change: the queue is the only reason.
      rig.upkeep.queuedRemovals = (_) => {sibling.id};

      await rig.upkeep.onAccepted(_c1);

      expect((await sync()).requestAccepted, isTrue);
      expect(requests(), hasLength(1));
      expect(requests().single.welcome, isNull);
      expect(await pin(sibling), isNull);
      // The own list still shows it: only the queue removed it.
      expect(rig.keys.own.any((d) => d.deviceId == sibling.idString), isTrue);
      // No removal clock for it: no re-check was needed.
      expect(liveRechecks(), 0);
    });

    test('the acceptance with a queued removal and a deregistered own device '
        'makes one commit (review I1 b)', () async {
      final sibling = await RigPeer.create('sibling');
      final sib2 = await RigPeer.create('sib2');
      await setUpJoined(
        accepted: false,
        others: [sibling, sib2],
        ownListed: [sibling, sib2],
        folder: Folder.FOLDER_REQUESTS,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );
      await synced();
      expect((await pin(sib2))!.side, MemberSide.mine);
      // sibling is queued (still listed); sib2 is deregistered.
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      rig.clock.advance(kDeviceListReuse);
      ownList([sibling]);

      await rig.upkeep.onAccepted(_c1);

      expect((await sync()).requestAccepted, isTrue);
      expect(requests(), hasLength(1));
      expect(requests().single.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect(await pin(sib2), isNull);
    });

    test('onAccepted with a racing bobCommits arms one re-check, which makes '
        'the removal (review m-3)', () async {
      final sibling = await RigPeer.create('sibling');
      final bob2 = await RigPeer.create('bob2');
      await setUpRequest(sibling);
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      peerList([bob, bob2]);
      peerClaims([bob, bob2]);
      var raced = false;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || raced) return;
        raced = true;
        // Bob's own add of bob2 wins the pair: the acceptance's commit is
        // superseded, and the held steps cannot pull.
        await bobCommits(add: [await bob2.keyPackage()]);
      };

      await rig.upkeep.onAccepted(_c1);

      expect(raced, isTrue);
      expect(requests(), hasLength(1));
      expect((await pin(sibling))!.side, MemberSide.mine);
      expect(liveRechecks(), 1);
      expect(rig.upkeepScheduled.last.delay, kPeerRemovalFetchGap);

      rig.clock.advance(kPeerRemovalFetchGap);
      await runRecheck();
      expect(requests(), hasLength(2));
      expect(requests().last.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect((await pin(bob2))!.side, MemberSide.theirs);
    });

    test('the first reply after an accept that committed is sent in the same '
        'drain', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // The acceptance's reconcile removes sibling (not listed any more).
      rig.clock.advance(kDeviceListReuse);
      ownList(const []);

      await send('l1');

      expect(requests(), hasLength(1));
      expect(await pin(sibling), isNull);
      // One drain: accepted, committed, synced again and sent.
      expect(rig.server.sends, hasLength(1));
      expect(rig.server.sends.single.pair, const MlsPair(1, 2));
      expect(
        (await rig.device.vault.outbox(conversationId: _c1)).items,
        isEmpty,
      );
    });

    test('a failed acceptForReply writes no state and runs no acceptance '
        'step', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // Steps that WOULD run on success: a queued removal, an add, alerts.
      final bob2 = await RigPeer.create('bob2');
      peerList([bob, bob2]);
      peerClaims([bob, bob2]);
      rig.upkeep.queuedRemovals = (_) => {sibling.id};
      await otherConversation(_c3, accepted: true);
      final before = await rig.dump();
      final lists = rig.keys.listCalls;
      final gets = rig.keys.getCalls.length;
      rig.server.calls.clear();
      rig.server.acceptError = const NetworkException('offline');

      await expectLater(
        rig.upkeep.acceptForReply(_c1, priority: BudgetPriority.user),
        throwsA(isA<NetworkException>()),
      );

      expect(rig.server.acceptRequests, [_c1]);
      expect(await rig.dump(), before);
      expect(rig.server.calls, ['acceptMessageRequest']);
      expect(rig.keys.listCalls, lists);
      expect(rig.keys.getCalls, hasLength(gets));
      expect(rig.keys.claimCalls, isEmpty);
      final context = rig.contexts.of(_c1);
      expect(context.incomingRequest, isTrue);
      expect(context.requestSeenInHeader, isTrue);
      expect(context.acceptedSeenAt, isNull);

      // The same fake, answering: the state changes (the test can fail).
      rig.server.acceptError = null;
      await rig.upkeep.acceptForReply(_c1, priority: BudgetPriority.user);
      expect((await sync()).requestAccepted, isTrue);
      expect(await rig.dump(), isNot(before));
    });

    test('a background drain does not accept an incoming request', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // The user's own send stops at another gate first.
      await updateSync((s) => s.copyWith(epochMustAdvance: true));
      await send('l1');
      expect(rig.acceptCalls, isEmpty);
      await updateSync((s) => s.copyWith(epochMustAdvance: false));

      // A push or poll drains at background priority: no accept.
      await rig.sender.drain(_c1, priority: BudgetPriority.background);
      expect(rig.acceptCalls, isEmpty);
      expect(rig.server.acceptRequests, isEmpty);
      expect(rig.server.sends, isEmpty);
      // Nor does a background call of the upkeep itself.
      await expectLater(
        rig.upkeep.acceptForReply(_c1, priority: BudgetPriority.background),
        throwsA(isA<StateError>()),
      );
      expect(rig.server.acceptRequests, isEmpty);
      expect((await sync()).requestAccepted, isFalse);

      // The user's retry accepts and sends.
      await rig.sender.drain(_c1, priority: BudgetPriority.user);
      expect(rig.server.acceptRequests, [_c1]);
      expect(rig.server.sends, hasLength(1));
    });

    test('a drain with no priority given drains at background and does not '
        'accept (review m2)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // The user's own send stops at another gate first.
      await updateSync((s) => s.copyWith(epochMustAdvance: true));
      await send('l1');
      await updateSync((s) => s.copyWith(epochMustAdvance: false));
      expect(rig.acceptCalls, isEmpty);

      // A caller that forgets the priority (an open, a poll): no accept.
      await rig.sender.drain(_c1);
      expect(rig.acceptCalls, isEmpty);
      expect(rig.server.acceptRequests, isEmpty);
      expect(rig.server.sends, isEmpty);

      // Only an explicit user priority accepts.
      await rig.sender.drain(_c1, priority: BudgetPriority.user);
      expect(rig.server.acceptRequests, [_c1]);
      expect(rig.server.sends, hasLength(1));
    });

    test('a send answer that flips the direction does not call '
        'AcceptMessageRequest or commit', () async {
      // This user sent the request (inbox, not accepted yet).
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(
        accepted: false,
        alsoListed: [bob2],
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );
      await synced();
      peerClaims([bob, bob2]);
      rig.realAcceptance = true;
      rig.watchAcceptanceNow();
      expect(rig.contexts.of(_c1).incomingRequest, isFalse);

      // A send answer that puts the request in this user's Requests folder.
      rig.server.sendAnswerRow = headerRow(folder: Folder.FOLDER_REQUESTS);
      await send('l1');
      // Then one that says ACCEPTED.
      rig.server.sendAnswerRow = headerRow(
        folder: Folder.FOLDER_REQUESTS,
        state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      );
      await send('l2');
      await send('l3');
      await rig.upkeep.idle();

      expect(rig.server.sends, hasLength(3));
      expect(rig.acceptCalls, isEmpty);
      expect(rig.server.acceptRequests, isEmpty);
      expect(requests(), isEmpty);
      expect(rig.keys.claimCalls, isEmpty);
      expect((await sync()).requestAccepted, isFalse);
      expect(rig.contexts.of(_c1).incomingRequest, isFalse);
    });

    test('acceptForReply refuses a direction no header showed', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // Incoming as far as memory says, but no header or inbox row of this
      // run showed the Requests folder.
      rig.contexts.of(_c1).requestSeenInHeader = false;

      await expectLater(
        rig.upkeep.acceptForReply(_c1, priority: BudgetPriority.user),
        throwsA(isA<StateError>()),
      );
      expect(rig.server.acceptRequests, isEmpty);
      expect((await sync()).requestAccepted, isFalse);
    });

    test('a cached row is no sight: neither its Requests folder nor its '
        'ACCEPTED drives the acceptance (review m5)', () async {
      // An incoming request, cached on disk from an earlier run.
      await setUpJoined(
        accepted: false,
        folder: Folder.FOLDER_REQUESTS,
        state: ConversationState.CONVERSATION_STATE_REQUEST,
      );
      // A member to attribute, so attribution needs the peer reference.
      final ghost = await RigPeer.create('ghost');
      await rig.device.vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: ghost.id,
            signatureKey: ghost.key,
            side: MemberSide.unattributed,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key), (ghost.id, ghost.key)],
      );
      rig.realAcceptance = true;
      rig.watchAcceptance = true;
      await rig.restart();
      // This run has read no header and no inbox row: attribution falls
      // back to the cached row for the peer reference.
      await rig.crypto.attributeMembers(_c1);
      final context = rig.contexts.of(_c1);
      expect(context.peerUserId, 'ref-bob');
      expect(context.incomingRequest, isNull);
      expect(context.requestSeenInHeader, isFalse);
      await expectLater(
        rig.upkeep.acceptForReply(_c1, priority: BudgetPriority.user),
        throwsA(isA<StateError>()),
      );
      expect(rig.server.acceptRequests, isEmpty);

      // A cached row saying ACCEPTED starts no acceptance either.
      rig.server.rows[_c1] = headerRow(
        state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      );
      rig.contexts.clear();
      await rig.crypto.attributeMembers(_c1);
      await rig.upkeep.idle();
      expect(rig.contexts.of(_c1).peerUserId, 'ref-bob');
      expect((await sync()).requestAccepted, isFalse);
      expect(requests(), isEmpty);
    });

    test('acceptForReply refuses a thread that cannot be answered (review '
        'm7)', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      rig.contexts.of(_c1).canReply = false;

      await expectLater(
        rig.upkeep.acceptForReply(_c1, priority: BudgetPriority.user),
        throwsA(isA<StateError>()),
      );
      expect(rig.server.acceptRequests, isEmpty);
      expect((await sync()).requestAccepted, isFalse);
    });

    test('an ACCEPTED header of a plaintext conversation writes no sync '
        'record (review m7)', () async {
      await setUpJoined();
      rig.watchAcceptanceNow();
      // _c2 has no record and no group here: it is not encrypted.
      expect(await rig.device.vault.conversation(_c2), isNull);
      final before = await rig.dump();

      rig.contexts.note(
        headerRow(
          id: _c2,
          state: ConversationState.CONVERSATION_STATE_ACCEPTED,
        ),
      );
      await rig.upkeep.idle();

      expect(await rig.device.vault.conversation(_c2), isNull);
      expect(await rig.device.vault.groups(_c2), isEmpty);
      expect(await rig.dump(), before);
      expect(requests(), isEmpty);
    });

    test('acceptance writes the own-device alert for an unseen own-side '
        'member attributed during the request', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // Not a brand-new vault: another accepted conversation has a group.
      await otherConversation(_c3, accepted: true);
      expect(added(await lines(), sibling, MemberSide.mine), isFalse);

      await rig.upkeep.onAccepted(_c1);

      expect((await sync()).requestAccepted, isTrue);
      final ls = await lines();
      expect(added(ls, sibling, MemberSide.mine), isTrue);
      // Never for this device.
      expect(
        ls.where(
          (l) =>
              l.line == SystemLine.deviceAdded &&
              rigEq(l.deviceId ?? const [], rig.device.deviceId),
        ),
        isEmpty,
      );
    });

    test('an own device seen in another accepted conversation does not '
        'alert at acceptance', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      await otherConversation(_c3, accepted: true, mine: [sibling]);

      await rig.upkeep.onAccepted(_c1);

      expect((await sync()).requestAccepted, isTrue);
      expect(added(await lines(), sibling, MemberSide.mine), isFalse);
    });

    test('a ghost pinned silently during one request still alerts at the '
        'acceptance of another conversation', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      // The same own-side pair, pinned in another conversation that is
      // still a request: that does not count as seen.
      await otherConversation(_c2, accepted: false, mine: [sibling]);
      await otherConversation(_c3, accepted: true);

      await rig.upkeep.onAccepted(_c1);

      expect(added(await lines(), sibling, MemberSide.mine), isTrue);
    });

    test('the conversation being accepted does not count its own request '
        'pins as seen', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRequest(sibling);
      await otherConversation(_c3, accepted: true);

      await rig.upkeep.onAccepted(_c1);
      // Asked again (a later header): nothing more, nothing less.
      await rig.upkeep.onAccepted(_c1);

      final ls = await lines();
      expect(
        ls.where(
          (l) =>
              l.line == SystemLine.deviceAdded &&
              rigEq(l.deviceId ?? const [], sibling.id),
        ),
        hasLength(1),
      );
    });

    test('an init settled by expiry in an already accepted conversation gets '
        'the own-device alert at the next header', () async {
      rig = await RigCrypto.create();
      bob = await RigPeer.create('bob');
      final sibling = await RigPeer.create('sibling');
      rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
      ownList([sibling]);
      await otherConversation(_c3, accepted: true);
      // This device's own init with bob, provisional; sibling was added as
      // an own device (pinned mine).
      await rig.seedProvisional(_c1, [bob]);
      await rig.device.vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: sibling.id,
            signatureKey: sibling.key,
            side: MemberSide.mine,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key), (sibling.id, sibling.key)],
      );
      final init = (await rig.device.vault.group(_c1, 1))!.pending!;
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 0),
        init.commit,
        fromUser: 'user-a',
      );
      // Settled without a server answer (Task 8's expiry path): no
      // requestAccepted and no alert.
      expect(
        await rig.locks.run(_c1, () => rig.crypto.settleOwnInitLocked(_c1, 1)),
        InitSettle.settled,
      );
      expect((await sync()).requestAccepted, isFalse);
      expect(added(await lines(), sibling, MemberSide.mine), isFalse);

      // The next header says ACCEPTED (the peer accepted long ago).
      rig.watchAcceptanceNow();
      rig.server.rows[_c1] = headerRow(
        state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      );
      await rig.receiver.pullLive(_c1);
      await rig.upkeep.idle();

      expect((await sync()).requestAccepted, isTrue);
      expect(added(await lines(), sibling, MemberSide.mine), isTrue);
      expect(rig.contexts.of(_c1).acceptanceSettled, isTrue);
    });
  });

  group('the re-check timer (brief amendment 10)', () {
    test('one re-check per conversation keeps the earliest due time and is '
        'cancelled at pause and at sign-out', () async {
      final carol = await RigPeer.create('carol');
      await setUpJoined();
      await synced();
      rig.clock.advance(kDeviceListReuse + _counts);
      // Bob's only device unlisted (never removed): its first miss F and
      // one re-check at F + 2 minutes.
      peerList([carol]);
      peerClaims(const []);
      await rig.upkeep.reconcile(_c1);
      final context = rig.contexts.of(_c1);
      final bobHex = context.firstMiss.keys.single;
      final first = context.firstMiss[bobHex]!;
      expect(liveRechecks(), 1);
      final entry = rig.upkeepScheduled.last;
      expect(rig.clock.now().add(entry.delay), first.add(kPeerRemovalFetchGap));

      // A reconcile with the same due time keeps the entry as it is.
      rig.clock.advance(const Duration(seconds: 10));
      await rig.upkeep.reconcile(_c1);
      expect(liveRechecks(), 1);
      expect(entry.cancelled, isFalse);

      // An EARLIER due time replaces it (review N3: never delayed by a
      // later one).
      context.firstMiss[bobHex] = first.subtract(const Duration(minutes: 1));
      await rig.upkeep.reconcile(_c1);
      expect(entry.cancelled, isTrue);
      expect(liveRechecks(), 1);
      final earlier = rig.upkeepScheduled.last;
      expect(
        rig.clock.now().add(earlier.delay),
        first.add(kPeerRemovalFetchGap - const Duration(minutes: 1)),
      );

      // Paused: cancelled.
      rig.upkeep.cancelScheduled();
      expect(earlier.cancelled, isTrue);
      expect(liveRechecks(), 0);
      // The next trigger schedules again; sign-out cancels it.
      await rig.upkeep.reconcile(_c1);
      expect(liveRechecks(), 1);
      rig.upkeep.reset();
      expect(liveRechecks(), 0);
    });
  });
}
