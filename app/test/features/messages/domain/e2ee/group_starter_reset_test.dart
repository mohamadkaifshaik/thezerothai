import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart'
    show
        kCommitCallsPerConversationPerDay,
        kCommitRetryWaitMax,
        kRequestInFlightMargin;
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _bob = 'ref-bob';
const _me = 'user-a';

/// Records the priority of every unit taken from the sync budget.
class _SpyBudget extends SyncBudget {
  _SpyBudget(RigClock clock)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: clock.now);

  final List<BudgetPriority> taken = [];

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    taken.add(priority);
    return super.take(priority, lane: lane);
  }
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late GroupStarter starter;
  _SpyBudget? spy;

  /// Bob's offer this device joined generation 1 from ([setUpJoined]).
  late RigOffer joined;

  /// Pipeline errors the running test expects (checked by the tearDown).
  var expectedErrors = <String>[];

  /// While set, every `ListConversationCommits` call fails (the record of a
  /// reset cannot be read in this run).
  var listingsFail = false;

  GroupStarter build() => starter = GroupStarter(
    crypto: rig.crypto,
    sender: rig.sender,
    receiver: rig.receiver,
    session: rig.device.session,
    engine: () => rig.device.engine,
    messaging: rig.messaging,
    keys: rig.keys,
    directory: rig.directory,
    ledger: rig.ledger,
    known: rig.known,
    syncBudget: rig.syncBudget,
    locks: rig.locks,
    contexts: rig.contexts,
    now: rig.clock.now,
    onChanged: rig.changed.add,
    removedElsewhere: () => rig.removedElsewhere,
    ownUserId: () => _me,
    publicIdsOff: () => false,
    schedule: (delay, run) => rig.scheduled.add((delay: delay, run: run)),
    onUnexpectedError: (e, _) => rig.unexpected.add(e),
  );

  Future<kpb.ClaimedKeyPackage> packageOf(RigPeer p) async =>
      kpb.ClaimedKeyPackage(
        deviceId: p.idString,
        signaturePublicKey: p.key,
        keyPackage: await p.keyPackage(),
        hasKeyPackage_4: true,
      );

  /// Bob's listed devices; each claim for him hands out one package each.
  void peers(List<RigPeer> devices) {
    rig.keys.peers[_bob] = [
      for (final d in devices) rigKeyDevice(d.idString, d.key),
    ];
    rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: _c1,
      keyPackages: [for (final d in devices) await packageOf(d)],
    );
  }

  /// This user's other devices: listed (when [listed]) and claimable.
  void siblings(List<RigPeer> devices, {bool listed = true}) {
    rig.keys.own.removeWhere((d) => d.deviceId != rig.device.deviceIdString);
    if (listed) {
      for (final d in devices) {
        rig.keys.own.add(rigKeyDevice(d.idString, d.key));
      }
    }
    rig.keys.claims[_me] = () async => kpb.ClaimKeyPackagesResponse(
      keyPackages: [for (final d in devices) await packageOf(d)],
    );
  }

  /// This device joins [_c1] (generation 1, accepted) from bob's welcome,
  /// with [others] in the group; [listed] of bob's devices are in his list.
  Future<void> setUpJoined({
    List<RigPeer> others = const [],
    List<RigPeer> listed = const [],
    bool spyBudget = false,
  }) async {
    spy = null;
    rig = await RigCrypto.create(
      syncBudget: spyBudget ? (clock) => spy = _SpyBudget(clock) : null,
    );
    rig.server.onCall = (call) async {
      if (call == 'listConversationCommits' && listingsFail) {
        throw const NetworkException('rig: no listing');
      }
    };
    bob = await RigPeer.create('bob');
    peers([bob, ...listed]);
    await rig.accept(_c1);
    rig.header(_c1, _bob);
    joined = await rig.offer(
      _c1,
      bob,
      others: [for (final o in others) await o.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
    build();
    rig.server.calls.clear();
    rig.server.acks.clear();
    rig.keys.claimCalls.clear();
    rig.keys.getCalls.clear();
  }

  setUp(() {
    expectedErrors = [];
    listingsFail = false;
  });

  tearDown(() async {
    final refused = rig.server.refusedAcks.length;
    final unexpected = [
      for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
    ];
    final expected = expectedErrors;
    await rig.dispose();
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
    expect(unexpected, expected, reason: 'unexpected pipeline errors');
  });

  final garbage = rigBytes('a commit no engine can process');

  /// Bob's next commit cannot be processed here: catch-up is stuck.
  Future<void> makeStuck() async {
    rig.device.engine.failWireAlways[RigEngine.key(garbage)] =
        const MlsException(MlsErrorCode.badInput, 'rig');
    rig.server.addCommit(
      _c1,
      rig.server.current(_c1),
      garbage,
      fromUser: 'user-b',
    );
    expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
  }

  Future<ConversationCryptoState> state() => rig.crypto.describeState(_c1);

  Future<GroupRecord?> groupAt(int g) => rig.device.vault.group(_c1, g);

  Future<ConversationSync> sync() async =>
      (await rig.device.vault.conversation(_c1))?.sync ??
      const ConversationSync();

  Future<MemberRecord?> pin(Uint8List deviceId) async {
    for (final m in await rig.device.vault.members(_c1)) {
      if (rigEq(m.deviceId, deviceId)) return m;
    }
    return null;
  }

  List<RigCommitCall> resets() => [
    for (final r in rig.server.commitRequests)
      if (r.reset) r,
  ];

  Future<List<SystemLineContent>> lines() => rig.lines(_c1);

  Future<void> reset() => starter.resetConversation(_c1);

  /// Bob's own reset of generation [from] into [from] + 1, stored on the
  /// server; with a welcome for this device when [addMe].
  Future<RigAdd> bobResets(int from, {bool addMe = true}) async {
    final kps = addMe ? [await rigKeyPackage(rig.device)] : <Uint8List>[];
    final carol = await RigPeer.create('carol-$from');
    final add = await rigCreateAndAdd(bob, mlsGroupId(_c1, from + 1), [
      ...kps,
      if (!addMe) await carol.keyPackage(),
    ]);
    final at = MlsPair(from + 1, 0);
    rig.server.addCommit(_c1, at, add.commit, fromUser: 'user-b');
    if (addMe) {
      rig.server.addWelcome(rig.device.deviceIdString, _c1, at, add.welcome);
    }
    return add;
  }

  /// Runs every callback the starter scheduled, as its timers would, and
  /// waits for the resumes they started.
  Future<void> runScheduled() async {
    final entries = [...rig.scheduled];
    rig.scheduled.clear();
    for (final e in entries) {
      e.run();
    }
    await starter.settled(_c1);
    await rig.locks.run(_c1, () async {});
    await starter.settled(_c1);
  }

  const unknown = (error: NetworkException('timed out'), stored: false);
  const lostAnswer = (error: NetworkException('timed out'), stored: true);

  /// M5's pause (two undos today): the reset is offered in a conversation
  /// that is not stuck.
  Future<void> pauseCommitting() async {
    await rig.ledger.addUndone(_c1);
    await rig.ledger.addUndone(_c1);
    expect((await state()).canReset, isTrue);
  }

  /// Bob's removal of this device from generation 1, stored on the server
  /// at its current pair (not applied here).
  Future<void> bobRemovesMe() async {
    final removal = await rigCommit(
      joined.add.group,
      remove: [rig.device.deviceId],
    );
    rig.server.addCommit(
      _c1,
      rig.server.current(_c1),
      removal.commit,
      fromUser: 'user-b',
    );
  }

  group('who may reset, and when', () {
    test('reset throws FeatureDisabledException with the flag off or unknown '
        'and nothing is claimed', () async {
      await setUpJoined();
      await makeStuck();
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        await rig.device.session.onFlagChanged(flag, uid: _me);
        await expectLater(reset(), throwsA(isA<FeatureDisabledException>()));
      }
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.keys.getCalls, isEmpty);
      expect(rig.server.commitRequests, isEmpty);
      expect(await groupAt(2), isNull);
    });

    test('reset is refused in an unaccepted conversation', () async {
      await setUpJoined();
      await makeStuck();
      await rig.device.vault.transaction(
        (tx) async => tx.putConversationSync(
          _c1,
          (await sync()).copyWith(requestAccepted: false),
        ),
      );
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.notAccepted,
          ),
        ),
      );
      expect((await state()).canReset, isFalse);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.commitRequests, isEmpty);
    });

    test('a waiting device may not reset at 23 h 59 min and may at 24 h, '
        'counted from the first sighting of that generation', () async {
      await setUpJoined();
      // Bob reset into generation 2 without this device.
      await bobResets(1, addMe: false);
      final first = rig.clock.now();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      rig.clock.advance(const Duration(hours: 1));
      // A later sighting does not move the first one.
      await rig.crypto.catchUp(_c1);
      expect(
        (await sync()).firstSawGenerationAtMicros,
        first.microsecondsSinceEpoch,
      );
      rig.clock.value = first.add(
        const Duration(hours: 23, minutes: 59, seconds: 59),
      );
      var s = await state();
      expect(s.phase, ConversationPhase.waitingForWelcome);
      expect(s.resetAllowedAt, first.add(kResetWaitWithoutWelcome));
      expect(s.canReset, isFalse);
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.unavailable,
          ),
        ),
      );
      expect(rig.keys.claimCalls, isEmpty);

      rig.clock.value = first.add(kResetWaitWithoutWelcome);
      s = await state();
      expect(s.canReset, isTrue);
      await reset();
      // The server is at generation 2: the reset names it and makes 3.
      final r = resets().single;
      expect(r.builtOn.generation, 2);
      expect((await groupAt(3))!.provisional, isFalse);
      expect(await groupAt(1), isNull);
      expect((await state()).phase, ConversationPhase.ready);
    });

    test('canReset is true exactly for stuck, waiting past 24 h and '
        'anti-flap pause, with the flag on and the conversation '
        'accepted', () async {
      await setUpJoined();
      var s = await state();
      expect(s.phase, ConversationPhase.ready);
      expect(s.canReset, isFalse);

      // M5's pause: the anti-flap offer (amendment 8).
      await rig.ledger.addUndone(_c1);
      expect((await state()).canReset, isFalse);
      await rig.ledger.addUndone(_c1);
      s = await state();
      expect(s.committingPausedToday, isTrue);
      expect(s.canReset, isTrue);
      rig.clock.advance(const Duration(days: 1));
      expect((await state()).canReset, isFalse);

      // Stuck.
      await makeStuck();
      expect((await state()).canReset, isTrue);
      // The flag off: stuck, and it says so.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isFalse);
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      expect((await state()).canReset, isTrue);
      // Not accepted.
      final accepted = await sync();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          accepted.copyWith(requestAccepted: false),
        ),
      );
      expect((await state()).canReset, isFalse);
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(_c1, accepted),
      );
      expect((await state()).canReset, isTrue);

      // A reset in progress: never a second one.
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);
      s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isFalse);
    });

    test('unavailable and peerHasNoDevice are E2eeActionException with the '
        'kind named, the commit cap a RateLimitedException (amendment '
        '9)', () async {
      await setUpJoined();
      // Not offered: a healthy conversation.
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.unavailable,
          ),
        ),
      );
      await makeStuck();
      peers([]);
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.peerHasNoDevice,
          ),
        ),
      );
      expect(rig.keys.claimCalls, isEmpty);
      // The commit cap of the conversation: a RateLimitedException, before
      // any claim.
      peers([bob]);
      await rig.device.vault.transaction(
        (tx) async => tx.putConversationSync(
          _c1,
          (await sync()).copyWith(
            commitCallsDay: istDay(rig.clock.now()),
            commitCallsToday: kCommitCallsPerConversationPerDay,
          ),
        ),
      );
      await expectLater(
        reset(),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limitName',
            kLimitCommitsPerConversationDaily,
          ),
        ),
      );
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.commitRequests, isEmpty);
    });
  });

  group('the reset', () {
    test('the new group id is mlsGroupId(conversation, g + 1)', () async {
      await setUpJoined();
      await makeStuck();
      await reset();
      final g2 = (await groupAt(2))!;
      final described = await rig.device.engine.inner.describe(g2.state);
      expect(rigEq(described.groupId, mlsGroupId(_c1, 2)), isTrue);
    });

    test('a reset addresses every usable device and fails peerHasNoDevice '
        'with none of the peer\'s', () async {
      final bob2 = await RigPeer.create('bob2');
      final sib = await RigPeer.create('sib');
      await setUpJoined();
      peers([bob, bob2]);
      siblings([sib]);
      await makeStuck();

      // Only bob is listed and his claim has no package: nothing is built
      // or sent.
      final real = rig.keys.claims[_bob]!;
      peers([bob]);
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [kpb.ClaimedKeyPackage(deviceId: bob.idString)],
      );
      await expectLater(
        reset(),
        throwsA(
          isA<E2eeActionException>().having(
            (e) => e.refusal,
            'refusal',
            E2eeRefusal.peerHasNoDevice,
          ),
        ),
      );
      expect(await groupAt(2), isNull);
      expect(rig.server.commitRequests, isEmpty);

      // Every usable device: both of bob's and this user's other one. (Bob's
      // empty claim of today is not tried again: a fresh device is used.)
      rig.keys.peers[_bob] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(bob2.idString, bob2.key),
      ];
      rig.keys.claims[_bob] = real;
      rig.clock.advance(const Duration(days: 1));
      await reset();
      final r = resets().single;
      expect(r.welcomeDeviceIds.toSet(), {
        bob.idString,
        bob2.idString,
        sib.idString,
      });
      expect((await pin(bob2.id))!.side, MemberSide.theirs);
      expect((await pin(sib.id))!.side, MemberSide.mine);
    });

    test('the provisional group of g + 1 leaves g\'s group, pins and marks '
        'untouched until the server accepts; the pending record and the '
        'call count are stored before the call (amendment 1)', () async {
      await setUpJoined();
      await makeStuck();
      final v = rig.device.vault;
      final g1 = (await groupAt(1))!;
      final pinsBefore = [
        for (final m in await v.members(_c1))
          (m.deviceId, m.signatureKey, m.side, m.since),
      ];
      final marks = await v.conversation(_c1);
      var seen = 0;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        seen++;
        final request = rig.server.commitRequests.single;
        expect(request.reset, isTrue);
        expect(request.builtOn, const MlsPair(1, 0));
        final g2 = (await groupAt(2))!;
        expect(g2.provisional, isTrue);
        expect(g2.epoch, 1);
        final pending = g2.pending!;
        expect(pending.kind, PendingKind.reset);
        expect(pending.builtOn, const MlsPair(2, 0));
        expect(rigEq(pending.commit, request.commit), isTrue);
        expect(rigEq(pending.welcome!, request.welcome!), isTrue);
        expect(pending.welcomeDeviceIds, [bob.idString]);
        // Counted before the call.
        final s = await sync();
        expect(s.commitCallsDay, istDay(rig.clock.now()));
        expect(s.commitCallsToday, 1);
        // g is untouched.
        final now1 = (await groupAt(1))!;
        expect(rigEq(now1.state, g1.state), isTrue);
        expect(now1.epoch, g1.epoch);
        expect([
          for (final m in await v.members(_c1))
            (m.deviceId, m.signatureKey, m.side, m.since),
        ], hasLength(pinsBefore.length));
        for (final m in await v.members(_c1)) {
          expect(m.since.generation, 1);
        }
        final marksNow = await v.conversation(_c1);
        expect(marksNow?.afterPair, marks?.afterPair);
        expect(marksNow?.joinHighWater, marks?.joinHighWater);
      };
      await reset();
      expect(seen, 1);
    });

    test('success clears provisional with after-pair (g + 1, 0), deletes g '
        'and writes one encryptionReset row', () async {
      await setUpJoined();
      await makeStuck();
      await reset();
      final v = rig.device.vault;
      expect(await groupAt(1), isNull);
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      expect(g2.pending, isNull);
      expect(g2.epoch, 1);
      final record = (await v.conversation(_c1))!;
      expect(record.afterPair, const MlsPair(2, 0));
      final s = record.sync;
      expect(s.completedEpochs, isEmpty);
      expect(s.firstSawGeneration, isNull);
      expect(s.firstSawGenerationAtMicros, isNull);
      expect(s.epochMustAdvance, isFalse);
      expect(s.lastSelfUpdateAtMicros, rig.clock.now().microsecondsSinceEpoch);
      final resetLines = [
        for (final l in await lines())
          if (l.line == SystemLine.encryptionReset) l,
      ];
      expect(resetLines, hasLength(1));
      // The pins are g + 1's members.
      final pins = await v.members(_c1);
      expect(pins, hasLength(2));
      for (final m in pins) {
        expect(m.since, const MlsPair(2, 1));
      }
      expect((await pin(rig.device.deviceId))!.side, MemberSide.mine);
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      final st = await state();
      expect(st.phase, ConversationPhase.ready);
      expect(st.canReset, isFalse);
      // The key history keeps bob, never shrinks.
      expect(
        (await rig.keyHistoryIds(_c1))[vaultDeviceIdHex(bob.id)],
        base64Encode(bob.key),
      );
    });

    test('an unchanged peer key set gives the reset line only; a new peer '
        'key also gives a deviceAdded row', () async {
      await setUpJoined();
      await makeStuck();
      await reset();
      expect(
        [for (final l in await lines()) l.line],
        [SystemLine.encryptionReset],
      );

      // A second reset (stuck again) with a new device of bob's.
      final bob2 = await RigPeer.create('bob2');
      peers([bob, bob2]);
      final garbage2 = rigBytes('a second commit no engine can process');
      rig.device.engine.failWireAlways[RigEngine.key(garbage2)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      rig.server.addCommit(
        _c1,
        rig.server.current(_c1),
        garbage2,
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
      await reset();
      final added = [
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded) l,
      ];
      expect(added, hasLength(1));
      expect(rigEq(added.single.deviceId!, bob2.id), isTrue);
      expect(added.single.side, MemberSide.theirs);
      expect(
        [for (final l in await lines()) l.line]
            .where((l) => l == SystemLine.encryptionReset),
        hasLength(2),
      );
    });

    test('a key claimed on both sides is added on neither, and a device '
        'reclaimed through an unattributed pin is new: own-side and '
        'peer-side deviceAdded rows (amendment 7)', () async {
      final carol = await RigPeer.create('carol');
      final sib = await RigPeer.create('sib');
      // Carol (bob's) and sib (this user's) are in the group, in no list:
      // pinned unattributed.
      await setUpJoined(others: [carol, sib]);
      expect((await pin(carol.id))!.side, MemberSide.unattributed);
      expect((await pin(sib.id))!.side, MemberSide.unattributed);
      // Now both are listed, and a device of bob's whose key is also
      // claimed for this user's side.
      final twin = await RigPeer.create('twin');
      // A package of this user's side that names twin's key under its own
      // id (what a server could hand out): its key is claimed on both sides.
      final mineTwin = await RigPeer.create('minetwin');
      final mineTwinPackage = await mineTwin.keyPackage();
      rig.device.engine.rewriteInspect = (kp, real) =>
          rigEq(kp, mineTwinPackage)
          ? KeyPackageInfo(deviceId: mineTwin.id, signaturePublicKey: twin.key)
          : null;
      peers([bob, carol, twin]);
      rig.keys.own
        ..add(rigKeyDevice(sib.idString, sib.key))
        ..add(rigKeyDevice(mineTwin.idString, twin.key));
      rig.keys.claims[_me] = () async => kpb.ClaimKeyPackagesResponse(
        keyPackages: [
          await packageOf(sib),
          kpb.ClaimedKeyPackage(
            deviceId: mineTwin.idString,
            signaturePublicKey: twin.key,
            keyPackage: mineTwinPackage,
            hasKeyPackage_4: true,
          ),
        ],
      );
      await makeStuck();
      await reset();
      final r = resets().single;
      expect(r.welcomeDeviceIds.toSet(), {
        bob.idString,
        carol.idString,
        sib.idString,
      });
      expect((await pin(carol.id))!.side, MemberSide.theirs);
      expect((await pin(sib.id))!.side, MemberSide.mine);
      final added = {
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded)
            (vaultDeviceIdHex(l.deviceId!), l.side),
      };
      expect(added, {
        (vaultDeviceIdHex(carol.id), MemberSide.theirs),
        (vaultDeviceIdHex(sib.id), MemberSide.mine),
      });
    });

    test('a member of g + 1 that is neither in the directory nor pinned at '
        'the end of g is unattributed and blocks sends', () async {
      final carol = await RigPeer.create('carol');
      await setUpJoined();
      peers([bob, carol]);
      await makeStuck();
      // The answers are lost and the record cannot be read in this run.
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);

      // A restart: carol is no longer listed.
      await rig.restart();
      build();
      listingsFail = false;
      peers([bob]);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      expect((await pin(carol.id))!.side, MemberSide.unattributed);
      final s = await state();
      expect(s.unattributedPresent, isTrue);
      expect(s.sendBlock, isNot(SendBlock.none));
      // No deviceAdded row for a member with no side.
      expect([
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded) l,
      ], isEmpty);
    });

    test('the pins of g + 1 are admitted to the key history before '
        'attribution: a refused member is unattributed with an unknownDevice '
        'row, and the history keeps closed and allow', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined();
      peers([bob, bob2]);
      await makeStuck();
      // While the call is out, bob2's id is seen with another key here
      // (tainted), and the history is closed at a raised allowance. The
      // settle in this run has the reset's lists, which list bob2.
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        await rig.putKeyHistory(
          _c1,
          ids: [(bob.id, bob.key)],
          changed: [bob2.id],
          closed: true,
          allow: 512,
        );
      };
      await reset();
      expect((await groupAt(2))!.provisional, isFalse);
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      expect((await pin(bob2.id))!.side, MemberSide.unattributed);
      final unknownLines = [
        for (final l in await lines())
          if (l.line == SystemLine.unknownDevice) l,
      ];
      expect(unknownLines, hasLength(1));
      expect(rigEq(unknownLines.single.deviceId!, bob2.id), isTrue);
      expect((await state()).unknownDevicePresent, isTrue);
      final history = (await rig.keyHistory(_c1))!;
      expect(history['closed'], isTrue);
      expect(history['allow'], 512);
      expect(await rig.keyHistoryChanged(_c1), [vaultDeviceIdHex(bob2.id)]);
    });

    test('STALE_EPOCH: the provisional group is deleted and the winner\'s '
        'welcome is joined', () async {
      await setUpJoined();
      await makeStuck();
      RigAdd? winner;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' && winner == null) {
          winner = await bobResets(1);
        }
      };
      await reset();
      expect(resets(), hasLength(1));
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      final described = await rig.device.engine.inner.describe(g2.state);
      expect(
        described.members.map((m) => vaultDeviceIdHex(m.deviceId)).toSet(),
        {vaultDeviceIdHex(rig.device.deviceId), vaultDeviceIdHex(bob.id)},
      );
      expect(await groupAt(1), isNull);
      expect(rig.server.acks, isNotEmpty);
      // This device's own reset line is not written: the join writes one.
      expect(
        [for (final l in await lines()) l.line]
            .where((l) => l == SystemLine.encryptionReset),
        hasLength(1),
      );
    });

    test('a timeout resends the identical reset once; a restart finds its '
        'record at (g + 1, 0) and clears provisional', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 2) {
          listingsFail = true;
        }
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      final calls = resets();
      expect(calls, hasLength(2));
      expect(calls[0].sameBytes(calls[1]), isTrue);
      expect(calls[0].key, isNot(calls[1].key));
      expect((await sync()).commitCallsToday, 2);
      expect((await groupAt(2))!.provisional, isTrue);

      await rig.restart();
      build();
      listingsFail = false;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isFalse);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(2, 0),
      );
      expect(await groupAt(1), isNull);
    });

    test('the reset cap surfaces as RateLimitedException', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'slow down',
          limitName: kLimitResetsDaily,
        ),
        stored: false,
      ));
      await expectLater(
        reset(),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limitName',
            kLimitResetsDaily,
          ),
        ),
      );
      expect(await groupAt(2), isNull);
      expect(await groupAt(1), isNotNull);
      expect((await state()).phase, ConversationPhase.stuck);
      expect((await state()).canReset, isTrue);
    });

    test('a stage-encrypted row of g is re-encrypted in g + 1 after its '
        'STALE_EPOCH', () async {
      await setUpJoined();
      await rig.receiver.pullLive(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.receiver.pullLive(_c1);
      // The send's outcome stays unknown: the row stays at stage
      // encrypted, at (1, 1).
      rig.server.sendScript.addAll([unknown, unknown]);
      await rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'hi');
      await rig.sender.settled(_c1);
      final row = (await rig.device.vault.outbox(conversationId: _c1))
          .items
          .single;
      expect(row.stage, OutboxStage.encrypted);
      expect(row.generation, 1);

      await makeStuck();
      await reset();
      await rig.sender.drain(_c1, priority: BudgetPriority.user);
      await rig.sender.settled(_c1);
      expect(rig.server.sends.last.pair.generation, 2);
      expect(
        (await rig.device.vault.outbox(conversationId: _c1)).items,
        isEmpty,
      );
      final stored = [
        for (final m in await rig.device.vault.messages(_c1, limit: 50))
          if (m.kind == StoredMessageKind.message) m,
      ];
      expect(stored.single.generation, 2);
    });
  });

  group('the call rules (amendment 1) and timer priority (amendment 2)', () {
    test('a recognised retry of a stored reset still draws both server '
        'caps (the rig models commitCaps)', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      // The second call was recognised as a retry (nothing more stored).
      expect(rig.server.commitAt(_c1, const MlsPair(2, 0)), isNotNull);
      expect(rig.server.current(_c1), const MlsPair(2, 1));
      expect(rig.server.resetDraws[_me], 2);
      expect(rig.server.commitDraws['$_me|$_c1'], 2);
      // At the user's reset cap the server refuses before recognising.
      rig.server.resetCapPerUser = 2;
      await expectLater(
        rig.messaging.commitConversation(
          idempotencyKey: 'k',
          conversationId: _c1,
          builtOn: const MlsPair(1, 0),
          commit: resets().first.commit,
          welcome: resets().first.welcome,
          welcomeDeviceIds: resets().first.welcomeDeviceIds,
          reset: true,
        ),
        throwsA(
          isA<RateLimitedException>().having(
            (e) => e.limitName,
            'limitName',
            kLimitResetsDaily,
          ),
        ),
      );
      expect(rig.server.commitDraws['$_me|$_c1'], 3);
      expect(rig.server.resetDraws[_me], 2);
    });

    test('another reset won is not decided while an abandoned reset call '
        'still runs; its end decides', () async {
      await setUpJoined();
      await makeStuck();
      final ended = Completer<void>();
      rig.server.commitScript.add(unknown);
      rig.server.onCall = (call) async {
        if (call != 'commitConversation') return;
        final n = rig.server.commitRequests.length;
        if (n == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        } else if (n == 2) {
          // Bob's reset lands between the two calls.
          await bobResets(1);
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      // Kept: the first call may still reach the server.
      expect((await groupAt(2))!.provisional, isTrue);
      expect(rig.server.acks, isEmpty);

      ended.complete();
      await pumpEventQueue();
      expect(rig.scheduled.single.delay, kRequestInFlightMargin);
      // The timer fires after its delay (review I1: a resume inside the
      // wait after the unknown outcome does not even list).
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      expect(rig.server.acks, isNotEmpty);
      expect(resets(), hasLength(2));
    });

    test('a refused resend is dropped only after the margin that follows '
        'the end of an abandoned call', () async {
      await setUpJoined();
      await makeStuck();
      final ended = Completer<void>();
      rig.server.commitScript.addAll([
        unknown,
        (
          error: const FeatureDisabledException('off', feature: 'e2ee_dm'),
          stored: false,
        ),
      ]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);

      ended.complete();
      await pumpEventQueue();
      await runScheduled();
      // The margin counts from the call's end: not passed yet.
      expect((await groupAt(2))!.provisional, isTrue);
      expect(resets(), hasLength(2), reason: 'refused bytes are not resent');
      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();
      expect(await groupAt(2), isNull);
      expect(await groupAt(1), isNotNull);
      expect(resets(), hasLength(2));
    });

    test('a server retry time holds the resend, at most 5 minutes, and the '
        'timer-driven resend runs at live, never at user', () async {
      await setUpJoined(spyBudget: true);
      await makeStuck();
      rig.server.commitScript.add((
        error: const ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(hours: 1),
        ),
        stored: false,
      ));
      await reset();
      expect(resets(), hasLength(1));
      expect(rig.scheduled.single.delay, kCommitRetryWaitMax);
      // A resume before that time sends nothing (nor lists: review I1).
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(1));

      rig.clock.advance(kCommitRetryWaitMax);
      spy!.taken.clear();
      final entry = rig.scheduled.removeAt(0);
      rig.scheduled.clear();
      entry.run();
      await starter.settled(_c1);
      expect(resets(), hasLength(2));
      expect(resets()[0].sameBytes(resets()[1]), isTrue);
      expect(spy!.taken, isNotEmpty);
      expect(spy!.taken, isNot(contains(BudgetPriority.user)));
      expect(spy!.taken, contains(BudgetPriority.live));
      expect((await groupAt(2))!.provisional, isFalse);
      expect((await sync()).commitCallsToday, 2);
    });
  });

  group('resumeProvisional and resets (amendment 4)', () {
    test('a provisional reset older than 24 h is settled from its record at '
        '(g + 1, 0)', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      await rig.restart();
      build();
      listingsFail = false;
      rig.clock.advance(const Duration(hours: 25));
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(resets(), hasLength(2));
    });

    test(
      'an unstored reset older than 24 h expires only on a listing that '
      'started after the margin, never while an abandoned call runs',
      () async {
        await setUpJoined();
        await makeStuck();
        final ended = Completer<void>();
        rig.server.commitScript.addAll([unknown, unknown]);
        rig.server.onCall = (call) async {
          if (call == 'commitConversation' &&
              rig.server.commitRequests.length == 1) {
            rig.server.abandon(
              rig.server.commitRequests.last.key,
              ended.future,
            );
          }
        };
        await reset();
        expect((await groupAt(2))!.provisional, isTrue);
        rig.clock.advance(const Duration(hours: 25));
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect((await groupAt(2))!.provisional, isTrue, reason: 'a call runs');

        ended.complete();
        await pumpEventQueue();
        await runScheduled();
        expect((await groupAt(2))!.provisional, isTrue, reason: 'the margin');
        rig.clock.advance(kRequestInFlightMargin);
        await runScheduled();
        expect(await groupAt(2), isNull);
        expect(await groupAt(1), isNotNull);
        // Never sent again after the expiry; the user may reset again.
        expect(resets(), hasLength(2));
        final s = await state();
        expect(s.phase, ConversationPhase.stuck);
        expect(s.canReset, isTrue);
      },
    );

    test('a young unstored reset is resent with the identical bytes by '
        'resumeProvisional once its wait has passed', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(2), reason: 'not before the margin');
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(3));
      expect(resets()[0].sameBytes(resets()[2]), isTrue);
      expect((await groupAt(2))!.provisional, isFalse);
    });

    test('review I1: a stored reset whose settle waits makes no further call '
        'over three resumes', () async {
      await setUpJoined();
      await makeStuck();
      // Both calls are stored (the second a recognised retry); every
      // listing of the first run fails, so the reset stays provisional.
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      var listings = 0;
      var walkFails = false;
      // Only the first listing after the restore works (the record is
      // found as ours); every walk of g that a settle starts is
      // interrupted. Audit M1: once the record was read as ours, no resume
      // lists it again, so each later resume lists only for the walk.
      var recordRead = false;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call != 'listConversationCommits') return;
        listings++;
        if (listingsFail) throw const NetworkException('rig: no listing');
        if (walkFails) {
          if (recordRead) {
            throw const NetworkException('rig: the walk of g is interrupted');
          }
          recordRead = true;
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);
      expect(rig.server.resetDraws[_me], 2);
      expect((await sync()).commitCallsToday, 2);

      listingsFail = false;
      walkFails = true;
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(kRequestInFlightMargin);
        listings = 0;
        await starter.resumeProvisional();
        await starter.settled(_c1);
        expect(
          listings,
          greaterThan(0),
          reason: 'resume $i listed (the record, or the walk of g)',
        );
      }
      expect(resets(), hasLength(2), reason: 'an accepted reset needs no call');
      expect(rig.server.resetDraws[_me], 2);
      expect(rig.server.commitDraws['$_me|$_c1'], 2);
      expect((await sync()).commitCallsToday, 2);
      expect((await groupAt(2))!.provisional, isTrue);

      // The next trigger whose walk completes settles it, still with no
      // call.
      walkFails = false;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(resets(), hasLength(2));
    });

    test('review I1: a reset whose record cannot be read is resent at most '
        'once per margin, and not listed while held back', () async {
      await setUpJoined();
      await makeStuck();
      // Every answer is lost (audit M1: an answer would tell the server
      // holds the bytes, and nothing would be resent).
      rig.server.commitScript.addAll([
        lostAnswer,
        lostAnswer,
        lostAnswer,
        lostAnswer,
      ]);
      var listings = 0;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call != 'listConversationCommits') return;
        listings++;
        if (listingsFail) throw const NetworkException('rig: no listing');
      };
      await reset();
      expect(resets(), hasLength(2));

      // Held back by the last unknown outcome: no listing, no call.
      listings = 0;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(listings, 0, reason: 'heldBack is checked before the listing');
      expect(resets(), hasLength(2));

      // Past the wait, every listing still fails: one resend.
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(3));
      // More triggers inside the margin of that resend: no call.
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(const Duration(seconds: 1));
        await starter.resumeProvisional();
        await starter.settled(_c1);
      }
      expect(resets(), hasLength(3));
      expect(rig.server.resetDraws[_me], 3);
      // One margin later: one more.
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(resets(), hasLength(4));
      expect(resets()[0].sameBytes(resets()[3]), isTrue);
      expect((await sync()).commitCallsToday, 4);
      expect((await groupAt(2))!.provisional, isTrue);
    });

    test('audit M1: a reset the server answered is never resent while the '
        'listings fail; only its settle is retried', () async {
      await setUpJoined();
      await makeStuck();
      // The call answers (g + 1, 1); every listing after it fails, so the
      // settle's walk of g cannot run and the reset stays provisional.
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect(resets(), hasLength(1));
      expect((await groupAt(2))!.provisional, isTrue);
      for (var i = 0; i < 3; i++) {
        rig.clock.advance(kRequestInFlightMargin);
        await starter.resumeProvisional();
        await starter.settled(_c1);
      }
      expect(resets(), hasLength(1), reason: 'the server holds these bytes');
      expect(rig.server.resetDraws[_me], 1);
      expect((await sync()).commitCallsToday, 1);
      expect((await groupAt(2))!.provisional, isTrue);

      // The next trigger whose walk runs settles it, with no call.
      listingsFail = false;
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect((await groupAt(2))!.provisional, isFalse);
      expect(resets(), hasLength(1));
    });

    test('audit M1: a listing the local sync budget refuses is not asked: '
        'no decision and no call', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);

      rig.clock.advance(kRequestInFlightMargin);
      rig.syncBudget.pauseUntil(rig.clock.now().add(const Duration(hours: 1)));
      rig.server.calls.clear();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(rig.server.calls, isNot(contains('listConversationCommits')));
      expect(resets(), hasLength(2), reason: 'not asked is no answer');
      expect((await groupAt(2))!.provisional, isTrue);
    });
  });

  group('the stuck member (R12, M9)', () {
    test('a stuck member with the flag on is repaired by one reset; with '
        'the flag off it stays stuck and says so', () async {
      await setUpJoined();
      await makeStuck();
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      await starter.repairIfStuck(_c1);
      expect(rig.keys.claimCalls, isEmpty);
      var s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.sendBlock, SendBlock.stuck);
      expect(s.canReset, isFalse);
      expect(await rig.ledger.autoResets(_c1), 0);

      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(1));
      s = await state();
      expect(s.phase, ConversationPhase.ready);
      expect(await rig.ledger.autoResets(_c1), 1);
    });

    test('a third stuck result in one day does not reset by itself', () async {
      await setUpJoined();
      await makeStuck();
      final real = rig.keys.claims[_bob]!;
      // Each automatic reset fails at its claim; the count was written
      // before it.
      final countsAtClaim = <int>[];
      rig.keys.claims[_bob] = () async {
        countsAtClaim.add(await rig.ledger.autoResets(_c1));
        throw const NetworkException('rig: no claim');
      };
      await starter.repairIfStuck(_c1);
      await starter.repairIfStuck(_c1);
      expect(countsAtClaim, [1, 2]);
      expect(await rig.ledger.autoResets(_c1), kAutoResetsPerDay);

      await starter.repairIfStuck(_c1);
      expect(countsAtClaim, [1, 2], reason: 'no claim the third time');
      var s = await state();
      expect(s.phase, ConversationPhase.stuck);
      expect(s.canReset, isTrue);

      // A manual reset is not counted.
      rig.keys.claims[_bob] = real;
      await reset();
      expect(resets(), hasLength(1));
      expect(await rig.ledger.autoResets(_c1), kAutoResetsPerDay);

      // Stuck again the same day: no reset by itself; the next IST day
      // allows two again.
      final garbage2 = rigBytes('another unprocessable commit');
      rig.device.engine.failWireAlways[RigEngine.key(garbage2)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      rig.server.addCommit(
        _c1,
        rig.server.current(_c1),
        garbage2,
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(1));
      rig.clock.advance(const Duration(days: 1));
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(2));
      expect(await rig.ledger.autoResets(_c1), 1);
      s = await state();
      expect(s.phase, ConversationPhase.ready);
    });

    test(
      'an unreadable ledger makes no automatic reset (fails closed)',
      () async {
        await setUpJoined();
        await makeStuck();
        await rig.device.vault.transaction(
          (tx) => tx.putSetting(kVaultSettingE2eeDaily, rigBytes('not json')),
        );
        expectedErrors = ['daily.read'];
        await starter.repairIfStuck(_c1);
        expect(rig.keys.claimCalls, isEmpty);
        expect(resets(), isEmpty);
        expect((await state()).canReset, isTrue);
      },
    );

    test('an unprocessable commit never triggers more than one reset per '
        'catch-up', () async {
      await setUpJoined();
      await makeStuck();
      await Future.wait([
        starter.repairIfStuck(_c1),
        starter.repairIfStuck(_c1),
      ]);
      expect(resets(), hasLength(1));
      expect(rig.keys.claimCalls.where((c) => c.userId == _bob), hasLength(1));
      // The unprocessable commit is behind the reset: catch-up is current
      // and nothing asks for another.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await starter.repairIfStuck(_c1);
      expect(resets(), hasLength(1));
      expect(await rig.ledger.autoResets(_c1), 1);
    });
  });

  group('a reset in progress (amendment 10)', () {
    test('blocks reconcile and the self-update check', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);
      rig.server.calls.clear();
      final lists = rig.keys.listCalls;
      final gets = rig.keys.getCalls.length;
      rig.clock.advance(const Duration(days: 31));
      await rig.upkeep.reconcile(_c1);
      await rig.upkeep.selfUpdateIfDue(_c1);
      expect(rig.server.calls, isNot(contains('commitConversation')));
      expect(rig.keys.listCalls, lists);
      expect(rig.keys.getCalls, hasLength(gets));
      expect(resets(), hasLength(2));
    });
  });

  group('a later generation passes a provisional reset (amendment 6)', () {
    test('a join of a later generation ends the provisional reset it '
        'passed, never leaving it for good', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);
      // Bob reset into 2 without this device, then into 3 with it.
      await bobResets(1, addMe: false);
      await bobResets(2);
      await rig.crypto.processWelcomes();
      expect((await groupAt(3))!.provisional, isFalse);
      expect(await groupAt(2), isNull);
      final st = await state();
      expect(st.phase, isNot(ConversationPhase.provisional));
      expect(st.sendBlock, isNot(SendBlock.provisional));
    });

    /// Review M1: this device's reset into 2 is STORED (both calls landed,
    /// every listing failed, so it is still provisional), and the marks are
    /// already past it, at (3, 0). The join change keeps this state from
    /// arising; it is seeded here so the two defensive ends are pinned. g's
    /// last epoch is marked walked, so neither path walks first.
    Future<void> seedPassedStoredReset() async {
      rig.server.commitScript.addAll([lostAnswer, lostAnswer]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') listingsFail = true;
        if (call == 'listConversationCommits' && listingsFail) {
          throw const NetworkException('rig: no listing');
        }
      };
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);
      expect(rig.server.commitAt(_c1, const MlsPair(2, 0)), isNotNull);
      final g1 = (await groupAt(1))!;
      final s = await sync();
      await rig.device.vault.transaction((tx) async {
        await tx.putConversationSync(
          _c1,
          s.copyWith(completedEpochs: [MlsPair(1, g1.epoch)]),
        );
        await tx.setAfterPair(_c1, const MlsPair(3, 0));
      });
      listingsFail = false;
      rig.clock.advance(kRequestInFlightMargin);
    }

    test('review M1: the starter ends a stored reset the marks already '
        'passed (InitSettle.replay), with no call', () async {
      await setUpJoined();
      await makeStuck();
      await seedPassedStoredReset();
      await starter.resumeProvisional();
      await starter.settled(_c1);
      expect(await groupAt(2), isNull, reason: 'never provisional for good');
      expect(resets(), hasLength(2));
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(3, 0),
      );
      expect(
        [for (final l in await lines()) l.line],
        isNot(contains(SystemLine.encryptionReset)),
        reason: 'a replay writes nothing',
      );
    });

    test('review M1: a join discards an own STORED reset of a lower '
        'generation that the marks already passed', () async {
      await setUpJoined();
      await makeStuck();
      await seedPassedStoredReset();
      // A welcome above both marks, of a later generation (its bytes do not
      // matter here: the lower reset is ended before any join).
      rig.server.addWelcome(
        rig.device.deviceIdString,
        _c1,
        const MlsPair(3, 1),
        rigBytes('a welcome of generation 3'),
      );
      await rig.crypto.processWelcomes();
      expect(await groupAt(2), isNull, reason: 'never provisional for good');
      expect(resets(), hasLength(2));
      expect([
        for (final l in await lines()) l.line,
      ], isNot(contains(SystemLine.encryptionReset)));
    });
  });

  group('a removal of this device in g (review I-1)', () {
    test('review I-1: a removal stored at (g, e) before the reset is '
        'accepted: the reset settles into g + 1, with no deviceAdded row for '
        'bob, and the pins are the members of g + 1', () async {
      await setUpJoined();
      await pauseCommitting();
      await bobRemovesMe();
      // The server checks only the generation: it accepts the reset, and
      // the settle walks g first, which applies the removal.
      await reset();
      expect(resets(), hasLength(1));
      final g2 = await groupAt(2);
      expect(g2, isNotNull, reason: 'the server holds g + 1 with this leaf');
      expect(g2!.provisional, isFalse);
      expect(await groupAt(1), isNull);
      final pins = await rig.device.vault.members(_c1);
      expect(
        {for (final m in pins) vaultDeviceIdHex(m.deviceId)},
        {vaultDeviceIdHex(rig.device.deviceId), vaultDeviceIdHex(bob.id)},
      );
      for (final m in pins) {
        expect(m.since, const MlsPair(2, 1));
      }
      expect((await pin(bob.id))!.side, MemberSide.theirs);
      expect([
        for (final l in await lines())
          if (l.line == SystemLine.deviceAdded) l,
      ], isEmpty);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(2, 0),
      );
      expect((await state()).phase, ConversationPhase.ready);
    });

    test('review I-1: a catch-up removal while an abandoned reset call is '
        'out keeps g + 1 provisional', () async {
      await setUpJoined();
      await pauseCommitting();
      final ended = Completer<void>();
      rig.server.commitScript.addAll([unknown, unknown]);
      rig.server.onCall = (call) async {
        if (call == 'commitConversation' &&
            rig.server.commitRequests.length == 1) {
          rig.server.abandon(rig.server.commitRequests.last.key, ended.future);
        }
      };
      await reset();
      expect((await groupAt(2))!.provisional, isTrue);

      // A receiver catch-up applies bob's removal of this device in g.
      await bobRemovesMe();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      expect(await groupAt(1), isNull);
      final g2 = await groupAt(2);
      expect(g2, isNotNull, reason: 'a call of the reset may still land');
      expect(g2!.provisional, isTrue);
      expect(g2.pending?.kind, PendingKind.reset);
      ended.complete();
      await pumpEventQueue();
    });
  });

  group('a reset ended elsewhere, and a reset made during a resume (review '
      'm-1, m-2)', () {
    /// Stuck again in the current generation (a second unprocessable
    /// commit of bob's).
    Future<void> stuckAgain() async {
      final garbage2 = rigBytes('a second commit no engine can process');
      rig.device.engine.failWireAlways[RigEngine.key(garbage2)] =
          const MlsException(MlsErrorCode.badInput, 'rig');
      rig.server.addCommit(
        _c1,
        rig.server.current(_c1),
        garbage2,
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
    }

    test('review m-1: a reset the join path ended leaves no wait behind: a '
        'new reset made inside that wait is sent at once', () async {
      await setUpJoined();
      await makeStuck();
      // Reset A's outcome stays unknown: its resends wait one margin.
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      expect((await groupAt(2))!.provisional, isTrue);
      // Bob's reset into 2 adds this device; the join path (no starter)
      // discards reset A and joins his.
      await bobResets(1);
      await rig.crypto.processWelcomes();
      final g2 = (await groupAt(2))!;
      expect(g2.provisional, isFalse);
      expect(g2.pending, isNull);

      // Stuck again inside A's wait: reset B is made and sent.
      await stuckAgain();
      await reset();
      expect(resets(), hasLength(3), reason: 'B is sent, not held by A');
      expect(resets().last.builtOn.generation, 2);
      expect((await groupAt(3))!.provisional, isFalse);
    });

    test('review m-2: a reset made while a resume of the same conversation '
        'runs its after-lock steps still makes its call', () async {
      await setUpJoined();
      await makeStuck();
      rig.server.commitScript.addAll([unknown, unknown]);
      await reset();
      expect(resets(), hasLength(2));
      // Bob wins generation 2: the next resume drops reset A and joins his
      // welcome after the lock is released.
      await bobResets(1);
      Future<void>? second;
      var started = false;
      rig.server.onCall = (call) async {
        if (call != 'listWelcomes' || started) return;
        started = true;
        // The resume is in its after-lock join (it holds no lock): the
        // user resets again now, and B's group is created meanwhile.
        second = starter.resetConversation(_c1);
        for (var i = 0; i < 200 && await groupAt(3) == null; i++) {
          await pumpEventQueue();
        }
        expect((await groupAt(3))?.provisional, isTrue);
      };
      rig.clock.advance(kRequestInFlightMargin);
      await starter.resumeProvisional();
      expect(second, isNotNull);
      await second;
      await starter.settled(_c1);
      expect(resets(), hasLength(3), reason: 'B made its call');
      expect(resets().last.builtOn.generation, 2);
      expect((await groupAt(3))!.provisional, isFalse);
    });
  });
}
