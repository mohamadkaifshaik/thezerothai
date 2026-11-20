import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/former_pins.dart';
import 'package:dzeroth/features/messages/domain/e2ee/known_conversations.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';
const _c3 = '33333333333333333333333333333333';

String _conv(int n) => n.toRadixString(16).padLeft(32, 'a');

const _mlsBadInput = MlsException(MlsErrorCode.badInput, 'rig');

/// A repository whose one `ListWelcomes` page holds 60 welcomes with a label
/// the client refuses (each is permanent, without an engine call).
class _BigPage extends RigMessaging {
  _BigPage(RigServer server) : super(server, 'user-a');

  @override
  Future<pb.ListWelcomesResponse> listWelcomes({
    required String deviceId,
  }) async {
    final acked = {for (final a in acks) ...a};
    return pb.ListWelcomesResponse(
      welcomes: [
        for (var i = 0; i < 60; i++)
          if (!acked.contains(_conv(i)))
            pb.Welcome(
              id: _conv(i),
              conversationId: _conv(i),
              mlsGeneration: Int64(-1),
              mlsEpoch: Int64.ZERO,
              welcome: Uint8List(4),
            ),
      ],
    );
  }

  final List<List<String>> acks = [];

  @override
  Future<void> ackWelcomes({
    required String idempotencyKey,
    required String deviceId,
    required List<String> ids,
  }) async {
    // Its welcomes are not stored on the rig server: recorded here only (the
    // rig's strict ack would refuse ids it never listed).
    if (ids.isEmpty || ids.length > kAckWelcomesMaxIds) {
      throw StateError('rig: 1-50 ids');
    }
    acks.add([...ids]);
  }
}

/// Records the `after` and page size of every `ListConversationCommits` call.
class _Recording extends RigMessaging {
  _Recording(RigServer server) : super(server, 'user-a');

  final List<({MlsPair? after, int pageSize})> commitCalls = [];

  @override
  Future<pb.ListConversationCommitsResponse> listConversationCommits({
    required String conversationId,
    required MlsPair? after,
    int pageSize = 0,
  }) {
    commitCalls.add((after: after, pageSize: pageSize));
    return super.listConversationCommits(
      conversationId: conversationId,
      after: after,
      pageSize: pageSize,
    );
  }
}

/// Records the device state every join starts from and the one it returns.
class _JoinSpy extends RigEngine {
  final List<Uint8List> inputs = [];
  final List<Uint8List> outputs = [];

  @override
  Future<JoinResult> joinFromWelcome(
    Uint8List deviceState,
    Uint8List welcome,
  ) async {
    inputs.add(deviceState);
    final r = await super.joinFromWelcome(deviceState, welcome);
    outputs.add(r.deviceState);
    return r;
  }
}

/// A sink whose walk of [failing]'s epochs fails (a transient failure).
class _FailingSink implements EpochMessageSink {
  _FailingSink(this.failing);

  final String failing;

  @override
  Future<void> completeEpoch(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) async {
    if (conversationId == failing) throw StateError('rig: walk failed');
  }

  @override
  Future<void> markEpochUndecryptable(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) async {
    if (conversationId == failing) throw StateError('rig: walk failed');
  }
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;

  setUp(() async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
  });

  tearDown(() async {
    final refused = rig.server.refusedAcks.length;
    await rig.dispose();
    // The client swallows a refused ack: every test fails on one.
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
  });

  Future<List<String>> ackedIds() async => [
    for (final a in rig.server.acks) ...a.ids,
  ];

  test('a welcome is joined, stored with marks and pins, then '
      'acknowledged', () async {
    final offer = await rig.offer(_c1, bob);
    final joined = await rig.crypto.processWelcomes();
    expect(joined, [_c1]);

    final v = rig.device.vault;
    final group = await v.group(_c1, 1);
    expect(group, isNotNull);
    expect(group!.epoch, 1);
    expect(group.provisional, isFalse);
    final conv = await v.conversation(_c1);
    expect(conv!.afterPair, const MlsPair(1, 0));
    expect(conv.joinHighWater, const MlsPair(1, 0));
    expect(
      conv.sync.lastSelfUpdateAtMicros,
      rig.clock.now().microsecondsSinceEpoch,
    );
    final members = await v.members(_c1);
    expect(members, hasLength(2));
    final me = members.singleWhere(
      (m) => rigEq(m.deviceId, rig.device.deviceId),
    );
    expect(me.side, MemberSide.mine);
    final peer = members.singleWhere((m) => rigEq(m.deviceId, bob.id));
    expect(peer.side, MemberSide.unattributed);
    expect(peer.since, const MlsPair(1, 1));
    expect(rigEq(peer.signatureKey, bob.key), isTrue);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(rig.server.welcomesFor(rig.device.deviceIdString), isEmpty);
    // The join came before the acknowledgement.
    final calls = rig.server.calls;
    expect(calls.indexOf('ackWelcomes'), greaterThan(0));
    expect(rig.unexpected, isEmpty);
  });

  test('the ack is sent only after the join transaction returned', () async {
    final offer = await rig.offer(_c1, bob);
    final before = await rig.dump();
    // The known set is unloaded during the join, so its write fails after
    // the device state, the group and the pins were written: the whole
    // transaction must roll back.
    rig.device.engine.describeMembers = (real) {
      rig.known.clear();
      return real;
    };
    expect(await rig.crypto.processWelcomes(), isEmpty);
    rig.device.engine.describeMembers = null;

    expect(rig.server.acks, isEmpty);
    expect(await rig.dump(), before);
    expect(rig.server.welcomesFor(rig.device.deviceIdString), hasLength(1));

    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await ackedIds(), [offer.welcomeId]);
    expect(await rig.device.vault.group(_c1, 1), isNotNull);
  });

  test('a replayed welcome at the after-pair is acknowledged without an '
      'engine call and changes nothing', () async {
    final first = await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    // The server hands out the same welcome again.
    final again = rig.server.addWelcome(
      rig.device.deviceIdString,
      _c1,
      const MlsPair(1, 0),
      first.add.welcome,
    );
    final before = await rig.dump();
    rig.device.engine.calls.clear();

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [first.welcomeId, again]);
    expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
    expect(await rig.dump(), before);
  });

  test("a welcome for another conversation's group id is acknowledged and "
      'nothing is stored', () async {
    final offer = await rig.offer(_c2, bob, groupId: mlsGroupId(_c1, 1));
    final before = await rig.dump();

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(await rig.dump(), before);
    expect(await rig.device.vault.group(_c2, 1), isNull);
    expect(await rig.device.vault.conversation(_c2), isNull);
    expect(rig.known.contains(_c2), isFalse);
  });

  test('epoch not label + 1 is permanent', () async {
    final offer = await rig.offer(_c1, bob, label: const MlsPair(1, 1));
    final before = await rig.dump();

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(await rig.dump(), before);
  });

  test('eleven members, a repeated key and only-own members are '
      'permanent', () async {
    final sib = await RigPeer.create('sib');
    rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));
    final cases = <String, List<GroupMember> Function(List<GroupMember>)>{
      _c1: (real) => [
        ...real,
        for (var i = 0; i < 9; i++)
          GroupMember(
            deviceId: rigBytes('extra-device-$i-000000'),
            signaturePublicKey: Uint8List.fromList(List.filled(32, i + 1)),
          ),
      ],
      _c2: (real) => [
        for (final m in real)
          GroupMember(
            deviceId: m.deviceId,
            signaturePublicKey: rig.device.signatureKey,
          ),
      ],
      _c3: (real) => [
        for (final m in real)
          rigEq(m.deviceId, bob.id)
              ? GroupMember(deviceId: sib.id, signaturePublicKey: sib.key)
              : m,
      ],
    };
    for (final e in cases.entries) {
      rig.server.acks.clear();
      final offer = await rig.offer(e.key, bob);
      final before = await rig.dump();
      rig.device.engine.describeMembers = e.value;
      expect(await rig.crypto.processWelcomes(), isEmpty);
      rig.device.engine.describeMembers = null;
      expect(await ackedIds(), [offer.welcomeId]);
      expect(await rig.dump(), before);
      expect(await rig.device.vault.group(e.key, 1), isNull);
    }
  });

  test('engine bad_input is acknowledged and counts as none', () async {
    final offer = await rig.offer(
      _c1,
      bob,
      createdAt: rig.clock.now().subtract(const Duration(minutes: 1)),
    );
    final before = await rig.dump();
    rig.device.engine.failNext['joinFromWelcome'] = _mlsBadInput;

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(await rig.dump(), before);
  });

  test('engine bad_input with the device clock behind created_at is not '
      'acknowledged', () async {
    await rig.offer(
      _c1,
      bob,
      createdAt: rig.clock.now().add(const Duration(hours: 1)),
    );
    rig.device.engine.failNext['joinFromWelcome'] = _mlsBadInput;

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(rig.server.acks, isEmpty);
    expect(rig.server.welcomesFor(rig.device.deviceIdString), hasLength(1));
    expect(await rig.device.vault.group(_c1, 1), isNull);
  });

  test('a deadline, an unavailable engine and a closed vault are not '
      'acknowledged and are retried', () async {
    // A deadline.
    final w1 = await rig.offer(_c1, bob);
    rig.device.engine.failNext['joinFromWelcome'] = const MlsException(
      MlsErrorCode.deadline,
      'rig',
    );
    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(rig.server.acks, isEmpty);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await ackedIds(), [w1.welcomeId]);

    // An unavailable engine.
    rig.server.acks.clear();
    final w2 = await rig.offer(_c2, bob);
    rig.device.engine.failNext['joinFromWelcome'] = const MlsException(
      MlsErrorCode.unavailable,
      'rig',
    );
    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(rig.server.acks, isEmpty);
    expect(await rig.crypto.processWelcomes(), [_c2]);
    expect(await ackedIds(), [w2.welcomeId]);

    // A closed vault.
    rig.server.acks.clear();
    final w3 = await rig.offer(_c3, bob);
    // The vault closes once the welcome was listed.
    rig.server.onCall = (call) async {
      if (call == 'listWelcomes') await rig.device.vault.close();
    };
    expect(await rig.crypto.processWelcomes(), isEmpty);
    rig.server.onCall = null;
    expect(rig.server.listedFor, isNotEmpty);
    expect(rig.server.acks, isEmpty);
    await rig.restart();
    expect(await rig.crypto.processWelcomes(), [_c3]);
    expect(await ackedIds(), [w3.welcomeId]);
  });

  test('ListWelcomes and AckWelcomes name this device only', () async {
    final sib = await RigPeer.create('sib');
    rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));
    await rig.offer(_c1, bob);
    // A welcome for my other device stays where it is.
    rig.server.addWelcome(sib.idString, _c2, const MlsPair(1, 0), Uint8List(8));

    expect(await rig.crypto.processWelcomes(), [_c1]);

    expect(rig.server.listedFor, everyElement(rig.device.deviceIdString));
    expect(rig.server.listedFor, isNotEmpty);
    expect([
      for (final a in rig.server.acks) a.deviceId,
    ], everyElement(rig.device.deviceIdString));
    expect(rig.server.welcomesFor(sib.idString), hasLength(1));
  });

  test('a full page is acknowledged and the next page is read', () async {
    final ids = [for (var i = 0; i < 12; i++) _conv(i)];
    for (final id in ids) {
      await rig.offer(id, bob);
    }

    final joined = await rig.crypto.processWelcomes();

    expect(joined.toSet(), ids.toSet());
    expect(rig.server.listedFor, hasLength(2));
    expect([for (final a in rig.server.acks) a.ids.length], [10, 2]);
    expect(rig.server.welcomesFor(rig.device.deviceIdString), isEmpty);
  });

  test('a transient welcome is retried at the next poll, not on the next '
      'page of the same poll', () async {
    // Listed first (lowest id): unusable while the clock is behind it.
    final skewed = rig.server.addWelcome(
      rig.device.deviceIdString,
      _c1,
      const MlsPair(1, 0),
      Uint8List(4),
      createdAt: rig.clock.now().add(const Duration(hours: 1)),
    );
    for (var i = 0; i < 12; i++) {
      await rig.offer(_conv(i), bob);
    }

    final joined = await rig.crypto.processWelcomes();

    expect(joined, hasLength(12));
    expect(await ackedIds(), isNot(contains(skewed)));
    final raw = await rig.device.vault.setting(kVaultSettingWelcomeSkew);
    final n =
        (jsonDecode(utf8.decode(raw!)) as Map<String, Object?>)['n']!
            as Map<String, Object?>;
    expect(n[skewed], 1);
  });

  test('ack batches never exceed 50 ids', () async {
    await rig.dispose();
    late _BigPage view;
    rig = await RigCrypto.create(messaging: (s) => view = _BigPage(s));

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect([for (final a in view.acks) a.length], [50, 10]);
    expect(
      {for (final a in view.acks) ...a},
      {for (var i = 0; i < 60; i++) _conv(i)},
    );
  });

  test('a first join writes no device rows for peer-side members', () async {
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    await rig.offer(_c1, bob);

    expect(await rig.crypto.processWelcomes(), [_c1]);

    final peer = (await rig.device.vault.members(_c1))
        .singleWhere((m) => rigEq(m.deviceId, bob.id));
    expect(peer.side, MemberSide.theirs);
    expect(await rig.lines(_c1), isEmpty);
  });

  test('a first join alerts for an own-side device this vault has never '
      'pinned, and not on a brand-new vault', () async {
    final sib = await RigPeer.create('sib');
    final sib2 = await RigPeer.create('sib2');
    rig.keys.own
      ..add(rigKeyDevice(sib.idString, sib.key))
      ..add(rigKeyDevice(sib2.idString, sib2.key));
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];

    // A brand-new vault meets its sibling: no alert.
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob, others: [await sib.keyPackage()]);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    final sibPin = (await rig.device.vault.members(_c1))
        .singleWhere((m) => rigEq(m.deviceId, sib.id));
    expect(sibPin.side, MemberSide.mine);
    expect(await rig.lines(_c1), isEmpty);

    // Now a group of an accepted conversation is stored: sib2 was never
    // pinned mine, sib was.
    await rig.accept(_c2);
    rig.header(_c2, 'ref-bob');
    await rig.offer(
      _c2,
      bob,
      others: [await sib.keyPackage(), await sib2.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c2]);
    final lines = await rig.lines(_c2);
    expect(lines, hasLength(1));
    expect(lines.single.line, SystemLine.deviceAdded);
    expect(lines.single.side, MemberSide.mine);
    expect(rigEq(lines.single.deviceId!, sib2.id), isTrue);
  });

  test('a known own device id with a new signature key gets the own-device '
      'alert', () async {
    final sib = await RigPeer.create('sib');
    rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob, others: [await sib.keyPackage()]);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await rig.lines(_c1), isEmpty);

    // The same id now shows another key, in the group and in my list.
    final newKey = Uint8List.fromList(List.filled(32, 7));
    rig.keys.own
      ..removeWhere((d) => d.deviceId == sib.idString)
      ..add(rigKeyDevice(sib.idString, newKey));
    rig.directory.clear();
    await rig.accept(_c2);
    rig.header(_c2, 'ref-bob');
    await rig.offer(_c2, bob, others: [await sib.keyPackage()]);
    rig.device.engine.describeMembers = (real) => [
      for (final m in real)
        rigEq(m.deviceId, sib.id)
            ? GroupMember(deviceId: sib.id, signaturePublicKey: newKey)
            : m,
    ];
    expect(await rig.crypto.processWelcomes(), [_c2]);
    rig.device.engine.describeMembers = null;

    final pin = (await rig.device.vault.members(_c2))
        .singleWhere((m) => rigEq(m.deviceId, sib.id));
    expect(pin.side, MemberSide.mine);
    final lines = await rig.lines(_c2);
    expect(lines, hasLength(1));
    expect(lines.single.line, SystemLine.deviceAdded);
    expect(lines.single.side, MemberSide.mine);
  });

  test('a rejoin after selfRemoved or set up again reports a peer key that '
      'was not pinned before', () async {
    final carol = await RigPeer.create('carol');
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, carol.key),
    ];
    rig.header(_c1, 'ref-bob');
    // This device was in generation 1 with bob, then left it: marks, former
    // pins and the key history stay.
    const formerPins = FormerPins();
    final v = rig.device.vault;
    await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)]);
    await v.transaction((tx) async {
      await tx.putConversationSync(
        _c1,
        const ConversationSync(requestAccepted: true),
      );
      await tx.setAfterPair(_c1, const MlsPair(1, 3));
      await tx.setJoinHighWater(_c1, const MlsPair(1, 0));
      await formerPins.putIn(tx, v, _c1, [
        MemberRecord(
          conversationId: _c1,
          deviceId: bob.id,
          signatureKey: bob.key,
          side: MemberSide.theirs,
          since: const MlsPair(1, 1),
        ),
        MemberRecord(
          conversationId: _c1,
          deviceId: rig.device.deviceId,
          signatureKey: rig.device.signatureKey,
          side: MemberSide.mine,
          since: const MlsPair(1, 1),
        ),
      ]);
    });

    await rig.offer(
      _c1,
      bob,
      generation: 2,
      others: [await carol.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);

    final members = await rig.device.vault.members(_c1);
    expect(
      members.singleWhere((m) => rigEq(m.deviceId, bob.id)).side,
      MemberSide.theirs,
    );
    expect(
      members.singleWhere((m) => rigEq(m.deviceId, carol.id)).side,
      MemberSide.theirs,
    );
    final lines = await rig.lines(_c1);
    expect(lines, hasLength(1));
    expect(lines.single.line, SystemLine.deviceAdded);
    expect(lines.single.side, MemberSide.theirs);
    expect(rigEq(lines.single.deviceId!, carol.id), isTrue);
    // The former pins are current again.
    expect(await formerPins.of(v, _c1), isEmpty);
  });

  test('a welcome for a provisional generation is joined only after the '
      'provisional outcome is settled', () async {
    final engine = rig.device.engine.inner;
    final v = rig.device.vault;
    final nowMicros = rig.clock.now().microsecondsSinceEpoch;

    // This device's own init for _c1 (generation 1, built on (1, 0)).
    Future<Uint8List> provisional(String id) async {
      final state = (await v.deviceState())!;
      final group = await engine.createGroup(state, mlsGroupId(id, 1));
      final commit = await engine.commitChange(
        state,
        group,
        addKeyPackages: [await bob.keyPackage()],
      );
      final confirmed = await engine.confirmCommit(state, commit.groupState);
      await v.transaction((tx) async {
        await tx.putGroup(
          GroupRecord(
            conversationId: id,
            generation: 1,
            epoch: 1,
            state: confirmed,
            provisional: true,
            provisionalCreatedAtMicros: nowMicros,
            pending: PendingCommit(
              kind: PendingKind.init,
              builtOn: const MlsPair(1, 0),
              commit: commit.commit,
              welcome: commit.welcome,
              welcomeDeviceIds: [bob.idString],
            ),
          ),
        );
        for (final m in [
          (rig.device.deviceId, rig.device.signatureKey, MemberSide.mine),
          (bob.id, bob.key, MemberSide.theirs),
        ]) {
          await tx.putMember(
            MemberRecord(
              conversationId: id,
              deviceId: m.$1,
              signatureKey: m.$2,
              side: m.$3,
              since: const MlsPair(1, 1),
            ),
          );
        }
        await tx.putOutbox(
          OutboxItem(
            idempotencyKey: 'k' * 32,
            localId: 'local-1',
            expectedMessageId: expectedMessageId('user-a', 'k' * 32),
            conversationId: id,
            generation: 1,
            epoch: 1,
            ciphertext: Uint8List.fromList([1, 2, 3]),
            reportCommitment: Uint8List(32),
            content: rigBytes('hello'),
            createdAtMicros: nowMicros,
            init: Uint8List.fromList([9, 9]),
          ),
        );
      });
      return commit.commit;
    }

    // 1. The server stored this device's own init: the provisional group is
    // cleared and the welcome is a replay.
    final ownCommit = await provisional(_c1);
    rig.server.addCommit(
      _c1,
      const MlsPair(1, 0),
      ownCommit,
      fromUser: 'user-a',
    );
    final kp = await rigKeyPackage(rig.device);
    final other = await rigCreateAndAdd(bob, mlsGroupId(_c1, 1), [kp]);
    final w1 = rig.server.addWelcome(
      rig.device.deviceIdString,
      _c1,
      const MlsPair(1, 0),
      other.welcome,
    );
    rig.device.engine.calls.clear();
    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(await ackedIds(), [w1]);
    expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
    final cleared = await v.group(_c1, 1);
    expect(cleared!.provisional, isFalse);
    expect((await v.conversation(_c1))!.afterPair, const MlsPair(1, 0));

    // 2. Another device's init was stored first: the provisional group and
    // its pins go, the row is back to plain, then the welcome is joined.
    rig.server.acks.clear();
    await provisional(_c2);
    final w2 = await rig.offer(_c2, bob);
    expect(await rig.crypto.processWelcomes(), [_c2]);
    expect(await ackedIds(), [w2.welcomeId]);
    final joined = await v.group(_c2, 1);
    expect(joined!.provisional, isFalse);
    expect(joined.pending, isNull);
    expect((await v.conversation(_c2))!.afterPair, const MlsPair(1, 0));
    final rows = (await v.outbox(conversationId: _c2)).items;
    expect(rows, hasLength(1));
    expect(rows.single.stage, OutboxStage.plain);
    expect(rows.single.ciphertext, isEmpty);
    expect(rows.single.init, isNull);
    expect(rows.single.localId, 'local-1');
    expect(utf8.decode(rows.single.content), 'hello');
    final bobPin = (await v.members(_c2))
        .singleWhere((m) => rigEq(m.deviceId, bob.id));
    // Re-pinned from the joined group, not kept from the provisional one.
    expect(bobPin.side, MemberSide.unattributed);
  });

  test('engine bad_input with the device clock behind created_at is '
      'transient at most three times per welcome id, across a restart, then '
      'permanent', () async {
    final offer = await rig.offer(
      _c1,
      bob,
      createdAt: rig.clock.now().add(const Duration(hours: 1)),
    );
    rig.device.engine.failAlways['joinFromWelcome'] = _mlsBadInput;

    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(await rig.crypto.processWelcomes(), isEmpty);
    await rig.restart();
    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(rig.server.acks, isEmpty);

    expect(await rig.crypto.processWelcomes(), isEmpty);
    expect(await ackedIds(), [offer.welcomeId]);
    // The counter entry went with the acknowledgement.
    final raw = await rig.device.vault.setting(kVaultSettingWelcomeSkew);
    final n = raw == null
        ? const <String, Object?>{}
        : (jsonDecode(utf8.decode(raw)) as Map<String, Object?>)['n']!
              as Map<String, Object?>;
    expect(n.containsKey(offer.welcomeId), isFalse);
  });

  test('a poll on another vault reloads the known set before any '
      'write', () async {
    // The app's one known set is loaded for vault A (another user's, with
    // its own ids) while the session's vault is B.
    final other = await RigDevice.create(
      dir: rig.dir,
      clock: rig.clock,
      uid: 'user-b',
      name: 'two',
    );
    addTearDown(other.dispose);
    await other.vault.transaction(
      (tx) => tx.putSetting(
        kVaultSettingKnownConversations,
        rigBytes('{"v":1,"ids":["$_c2"],"peers":{}}'),
      ),
    );
    await rig.known.load(other.vault);
    expect(rig.known.loaded, isTrue);
    expect(rig.known.contains(_c2), isTrue);
    await rig.offer(_c1, bob);

    expect(await rig.crypto.processWelcomes(), [_c1]);

    expect(rig.known.isLoadedFor(rig.device.vault), isTrue);
    expect(rig.known.contains(_c1), isTrue);
    expect(rig.known.contains(_c2), isFalse);
    final stored = KnownConversations(session: rig.device.session);
    await stored.load(rig.device.vault);
    expect(stored.ids, [_c1]);
    // Vault A's record is unchanged.
    final a = KnownConversations(session: other.session);
    await a.load(other.vault);
    expect(a.ids, [_c2]);
  });

  test('a joined welcome puts its conversation in the known set', () async {
    await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);

    expect(rig.known.contains(_c1), isTrue);
    final again = KnownConversations(session: rig.device.session);
    await again.load(rig.device.vault);
    expect(again.contains(_c1), isTrue);
    expect([for (final n in rig.messaging.noted) n.id], [_c1]);
    expect(rig.messaging.noted.single.session, rig.messaging.cacheSession);
  });

  test('a permanent welcome for a cached conversation of this user puts it '
      'in the known set', () async {
    rig.header(_c1, 'ref-bob');
    final offer = await rig.offer(_c1, bob, label: const MlsPair(1, 1));

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(rig.known.contains(_c1), isTrue);
    final again = KnownConversations(session: rig.device.session);
    await again.load(rig.device.vault);
    expect(again.contains(_c1), isTrue);
    expect(again.peerOf(_c1), isNull);
    expect([for (final n in rig.messaging.noted) n.id], [_c1]);
  });

  test('a permanent welcome for an uncached conversation does not extend '
      'the known set', () async {
    final offer = await rig.offer(_c1, bob, label: const MlsPair(1, 1));

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(rig.known.contains(_c1), isFalse);
    expect(rig.messaging.noted, isEmpty);
  });

  test('a skew counter for a welcome no longer listed is dropped', () async {
    final first = await rig.offer(
      _c1,
      bob,
      createdAt: rig.clock.now().add(const Duration(hours: 1)),
    );
    rig.device.engine.failNext['joinFromWelcome'] = _mlsBadInput;
    expect(await rig.crypto.processWelcomes(), isEmpty);

    Future<Map<String, Object?>> counters() async {
      final raw = await rig.device.vault.setting(kVaultSettingWelcomeSkew);
      if (raw == null) return const {};
      return (jsonDecode(utf8.decode(raw)) as Map<String, Object?>)['n']!
          as Map<String, Object?>;
    }

    expect((await counters())[first.welcomeId], 1);

    // The server replaces that welcome with another one (a new id, here an
    // unusable one); the old id is no longer listed.
    final second = rig.server.addWelcome(
      rig.device.deviceIdString,
      _c1,
      const MlsPair(1, 0),
      Uint8List(4),
    );
    await rig.crypto.processWelcomes();

    expect(await ackedIds(), [second]);
    expect((await counters()).containsKey(first.welcomeId), isFalse);
    expect(await rig.device.vault.group(_c1, 1), isNull);
  });

  test('two welcomes for two conversations both keep their device-state '
      'changes', () async {
    final w1 = await rig.offer(_c1, bob);
    final w2 = await rig.offer(_c2, bob);

    expect((await rig.crypto.processWelcomes()).toSet(), {_c1, _c2});

    // Each join consumed its one-time package in the stored device state.
    final state = (await rig.device.vault.deviceState())!;
    for (final w in [w1, w2]) {
      await expectLater(
        rig.device.engine.inner.joinFromWelcome(state, w.add.welcome),
        throwsA(
          isA<MlsException>().having(
            (e) => e.code,
            'code',
            MlsErrorCode.badInput,
          ),
        ),
      );
    }
    expect(await rig.device.vault.group(_c1, 1), isNotNull);
    expect(await rig.device.vault.group(_c2, 1), isNotNull);
  });

  test("a welcome of a generation below the server's current one is "
      'acknowledged without an engine call', () async {
    final offer = await rig.offer(_c1, bob);
    // The server already moved to generation 2.
    rig.server.addCommit(
      _c1,
      const MlsPair(2, 0),
      rigBytes('a reset'),
      fromUser: 'user-b',
    );
    final before = await rig.dump();
    rig.device.engine.calls.clear();

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [offer.welcomeId]);
    expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
    expect(await rig.dump(), before);
  });

  test('a join deletes an older generation only when its last epoch is in '
      'completedEpochs', () async {
    await rig.offer(_c1, bob);
    await rig.offer(_c2, bob);
    expect((await rig.crypto.processWelcomes()).toSet(), {_c1, _c2});
    final v = rig.device.vault;
    // Generation 1 of _c1 was walked to its end (L6); _c2's was not.
    final stored = (await v.conversation(_c1))!.sync;
    await v.transaction(
      (tx) => tx.putConversationSync(
        _c1,
        stored.copyWith(completedEpochs: const [MlsPair(1, 1)]),
      ),
    );

    await rig.offer(_c1, bob, generation: 2);
    final w2 = await rig.offer(_c2, bob, generation: 2);
    // _c2's generation 1 must be walked first; that walk fails here, so
    // its welcome waits (not acknowledged) and generation 1 stays.
    rig.crypto.sink = _FailingSink(_c2);
    rig.server.acks.clear();
    expect(await rig.crypto.processWelcomes(), [_c1]);

    expect(await v.group(_c1, 2), isNotNull);
    expect(await v.group(_c1, 1), isNull);
    expect(await v.group(_c2, 2), isNull);
    expect(await v.group(_c2, 1), isNotNull);
    expect(await ackedIds(), isNot(contains(w2.welcomeId)));
    expect((await v.conversation(_c1))!.sync.completedEpochs, isEmpty);

    // Once the walk succeeds, generation 1 goes with the join of 2.
    rig.crypto.sink = null;
    expect(await rig.crypto.processWelcomes(), [_c2]);
    expect(await v.group(_c2, 2), isNotNull);
    expect(await v.group(_c2, 1), isNull);
  });

  test('a rejoin keeps a current pin with the same key, deletes a pin absent '
      'from the group and re-pins a changed key unattributed', () async {
    final carol = await RigPeer.create('carol');
    final dave = await RigPeer.create('dave');
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, carol.key),
      rigKeyDevice(dave.idString, dave.key),
    ];
    rig.header(_c1, 'ref-bob');
    await rig.offer(
      _c1,
      bob,
      others: [await carol.keyPackage(), await dave.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);
    final v = rig.device.vault;
    MemberRecord? pinOf(List<MemberRecord> all, Uint8List id) {
      for (final m in all) {
        if (rigEq(m.deviceId, id)) return m;
      }
      return null;
    }

    final before = await v.members(_c1);
    expect(pinOf(before, bob.id)!.side, MemberSide.theirs);
    expect(pinOf(before, carol.id)!.side, MemberSide.theirs);
    expect(pinOf(before, dave.id)!.side, MemberSide.theirs);

    // Generation 2 holds bob, carol (with another key) and not dave.
    final newKey = Uint8List.fromList(List.filled(32, 5));
    await rig.offer(
      _c1,
      bob,
      generation: 2,
      others: [await carol.keyPackage()],
    );
    rig.device.engine.describeMembers = (real) => [
      for (final m in real)
        rigEq(m.deviceId, carol.id)
            ? GroupMember(deviceId: carol.id, signaturePublicKey: newKey)
            : m,
    ];
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;

    final after = await v.members(_c1);
    final bobPin = pinOf(after, bob.id)!;
    expect(bobPin.side, MemberSide.theirs);
    // Kept as it was: not re-pinned at the new generation.
    expect(bobPin.since, pinOf(before, bob.id)!.since);
    final carolPin = pinOf(after, carol.id)!;
    expect(carolPin.side, MemberSide.unattributed);
    expect(rigEq(carolPin.signatureKey, newKey), isTrue);
    expect(carolPin.since, const MlsPair(2, 1));
    expect(pinOf(after, dave.id), isNull);
  });

  List<String> linesOf(List<SystemLineContent> lines, Uint8List id) => [
    for (final l in lines)
      if (rigEq(l.deviceId ?? const [], id)) l.line,
  ];

  /// [id] is tainted in [c]'s key history (in `changed`, its key no longer
  /// kept), and the history was read: a refusal from an unreadable history
  /// would pass the pin assertions too.
  Future<void> expectTainted(String c, Uint8List id) async {
    final hex = vaultDeviceIdHex(id);
    expect(await rig.keyHistoryChanged(c), contains(hex));
    expect((await rig.keyHistoryIds(c)).keys, isNot(contains(hex)));
    expect(rig.keyHistoryErrors, isEmpty);
  }

  /// [id]'s member with [key] in what `describe` reports.
  List<GroupMember> Function(List<GroupMember>) onKey(
    Uint8List id,
    Uint8List key,
  ) =>
      (real) => [
        for (final m in real)
          rigEq(m.deviceId, id)
              ? GroupMember(deviceId: id, signaturePublicKey: key)
              : m,
      ];

  Future<MemberRecord?> pinIn(String c, Uint8List id) async {
    for (final m in await rig.device.vault.members(c)) {
      if (rigEq(m.deviceId, id)) return m;
    }
    return null;
  }

  // The provisional group and the empty record are Task 8's half of this
  // test (a joined group always holds another device).
  test('the first join and the first provisional group write the key '
      'history, even empty (the first join)', () async {
    final carol = await RigPeer.create('carol');
    expect(await rig.keyHistory(_c1), isNull);
    await rig.offer(_c1, bob, others: [await carol.keyPackage()]);
    expect(await rig.crypto.processWelcomes(), [_c1]);

    // Written in the join's transaction; this device is never recorded.
    expect(await rig.keyHistory(_c1), {
      'v': 1,
      'ids': {
        vaultDeviceIdHex(bob.id): base64Encode(bob.key),
        vaultDeviceIdHex(carol.id): base64Encode(carol.key),
      },
      'changed': <Object?>[],
      'closed': false,
      'allow': 256,
    });
    expect(rig.keyHistoryErrors, isEmpty);
  });

  test('a device dropped by a join and re-added on another key stays '
      'unknown', () async {
    final carol = await RigPeer.create('carol');
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, carol.key),
    ];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob, others: [await carol.keyPackage()]);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect((await pinIn(_c1, carol.id))!.side, MemberSide.theirs);

    // Generation 2 drops carol: her pin goes.
    await rig.offer(_c1, bob, generation: 2);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(await pinIn(_c1, carol.id), isNull);

    // Generation 3 holds her on another key, which the directory lists.
    final newKey = Uint8List.fromList(List.filled(32, 5));
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, newKey),
    ];
    rig.directory.clear();
    await rig.offer(
      _c1,
      bob,
      generation: 3,
      others: [await carol.keyPackage()],
    );
    rig.device.engine.describeMembers = onKey(carol.id, newKey);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);

    final carolPin = (await pinIn(_c1, carol.id))!;
    expect(carolPin.side, MemberSide.unattributed);
    expect(rigEq(carolPin.signatureKey, newKey), isTrue);
    await expectTainted(_c1, carol.id);
    expect((await pinIn(_c1, bob.id))!.side, MemberSide.theirs);
    final carolLines = linesOf(await rig.lines(_c1), carol.id);
    expect(carolLines, isNot(contains(SystemLine.deviceAdded)));
    expect(carolLines, contains(SystemLine.unknownDevice));
  });

  test('a device pinned by a discarded provisional group and joined on '
      'another key stays unknown', () async {
    final erin = await RigPeer.create('erin');
    final newKey = Uint8List.fromList(List.filled(32, 6));
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(erin.idString, newKey),
    ];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    // This device's own init pinned bob and erin (on her first key).
    await rig.seedProvisional(_c1, [bob, erin]);

    // Bob's init won: the provisional group and its pins go, and his
    // welcome holds erin on another key, which the directory lists.
    await rig.offer(_c1, bob, others: [await erin.keyPackage()]);
    rig.device.engine.describeMembers = onKey(erin.id, newKey);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);

    expect((await rig.device.vault.group(_c1, 1))!.provisional, isFalse);
    final erinPin = (await pinIn(_c1, erin.id))!;
    expect(erinPin.side, MemberSide.unattributed);
    expect(rigEq(erinPin.signatureKey, newKey), isTrue);
    await expectTainted(_c1, erin.id);
    expect((await pinIn(_c1, bob.id))!.side, MemberSide.theirs);
    expect(
      linesOf(await rig.lines(_c1), erin.id),
      isNot(contains(SystemLine.deviceAdded)),
    );
  });

  test('a missing key history is unreadable when the conversation has a '
      'group, a pin, a former pin or a mark', () async {
    final carol = await RigPeer.create('carol');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    final v = rig.device.vault;
    final withGroup = _conv(0xa1);
    final withPin = _conv(0xa2);
    final withFormer = _conv(0xa3);
    final withMark = _conv(0xa4);
    final withNothing = _conv(0xa5);
    MemberRecord carolPin(String c) => MemberRecord(
      conversationId: c,
      deviceId: carol.id,
      signatureKey: carol.key,
      side: MemberSide.theirs,
      since: const MlsPair(1, 1),
    );
    await v.transaction((tx) async {
      // A group of generation 1 already walked to its end.
      await tx.putGroup(
        GroupRecord(
          conversationId: withGroup,
          generation: 1,
          epoch: 1,
          state: rigBytes('a stored group'),
        ),
      );
      await tx.putConversationSync(
        withGroup,
        const ConversationSync(completedEpochs: [MlsPair(1, 1)]),
      );
      await tx.putMember(carolPin(withPin));
      await const FormerPins().putIn(tx, v, withFormer, [carolPin(withFormer)]);
      await tx.setJoinHighWater(withMark, const MlsPair(1, 0));
    });
    final all = [withGroup, withPin, withFormer, withMark, withNothing];
    for (final c in all) {
      await rig.accept(c);
      rig.header(c, 'ref-bob');
      await rig.offer(c, bob, generation: 2);
    }
    // The sync record `accept` wrote replaced the walked mark: put it back.
    await v.transaction(
      (tx) => tx.putConversationSync(
        withGroup,
        const ConversationSync(
          requestAccepted: true,
          completedEpochs: [MlsPair(1, 1)],
        ),
      ),
    );

    expect((await rig.crypto.processWelcomes()).toSet(), all.toSet());
    rig.clock.advance(const Duration(minutes: 3));
    for (final c in all) {
      await rig.crypto.attributeMembers(c);
    }

    for (final c in [withGroup, withPin, withFormer, withMark]) {
      expect(
        (await pinIn(c, bob.id))!.side,
        MemberSide.unattributed,
        reason: c,
      );
      // Never created as a fresh one.
      expect(await rig.keyHistory(c), isNull, reason: c);
      expect(await rig.lines(c), isEmpty, reason: c);
    }
    // One report per conversation.
    expect(rig.keyHistoryErrors, hasLength(4));
    // With no state at all the history starts empty and is written.
    expect((await pinIn(withNothing, bob.id))!.side, MemberSide.theirs);
    expect((await rig.keyHistoryIds(withNothing)).keys, [
      vaultDeviceIdHex(bob.id),
    ]);
  });

  test('a later join with a changed key stays unknown and is never written '
      'as deviceAdded', () async {
    final carol = await RigPeer.create('carol');
    final dave = await RigPeer.create('dave');
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, carol.key),
      rigKeyDevice(dave.idString, dave.key),
    ];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(
      _c1,
      bob,
      others: [await carol.keyPackage(), await dave.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);
    final v = rig.device.vault;
    MemberRecord pinOf(List<MemberRecord> all, Uint8List id) =>
        all.singleWhere((m) => rigEq(m.deviceId, id));
    expect(pinOf(await v.members(_c1), carol.id).side, MemberSide.theirs);

    // Generation 2 holds carol with another key; the directory lists it.
    final newKey = Uint8List.fromList(List.filled(32, 5));
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, newKey),
    ];
    rig.directory.clear();
    await rig.offer(
      _c1,
      bob,
      generation: 2,
      others: [await carol.keyPackage()],
    );
    rig.device.engine.describeMembers = (real) => [
      for (final m in real)
        rigEq(m.deviceId, carol.id)
            ? GroupMember(deviceId: carol.id, signaturePublicKey: newKey)
            : m,
    ];
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;
    // Past the recheck time, attribution runs again.
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);

    final carolPin = pinOf(await v.members(_c1), carol.id);
    expect(carolPin.side, MemberSide.unattributed);
    expect(rigEq(carolPin.signatureKey, newKey), isTrue);
    await expectTainted(_c1, carol.id);
    expect(pinOf(await v.members(_c1), bob.id).side, MemberSide.theirs);
    final carolLines = linesOf(await rig.lines(_c1), carol.id);
    expect(carolLines, isNot(contains(SystemLine.deviceAdded)));
    expect(carolLines, contains(SystemLine.unknownDevice));
    final state = await rig.crypto.describeState(_c1);
    expect(state.unknownDevicePresent, isTrue);
    expect(state.sendBlock, SendBlock.unknownDevice);

    // Generation 3 still holds carol on that key: re-pinned at its label,
    // still tainted, still never attributed.
    await rig.offer(
      _c1,
      bob,
      generation: 3,
      others: [await carol.keyPackage()],
    );
    rig.device.engine.describeMembers = (real) => [
      for (final m in real)
        rigEq(m.deviceId, carol.id)
            ? GroupMember(deviceId: carol.id, signaturePublicKey: newKey)
            : m,
    ];
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);
    final again = pinOf(await v.members(_c1), carol.id);
    expect(again.side, MemberSide.unattributed);
    expect(again.since, const MlsPair(3, 1));
    await expectTainted(_c1, carol.id);
    expect(
      linesOf(await rig.lines(_c1), carol.id),
      isNot(contains(SystemLine.deviceAdded)),
    );

    // Generation 4 no longer holds carol: her pin goes, her taint stays.
    final before = await rig.keyHistory(_c1);
    await rig.offer(_c1, bob, generation: 4);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    expect(
      (await v.members(_c1)).where((m) => rigEq(m.deviceId, carol.id)),
      isEmpty,
    );
    expect(await rig.keyHistory(_c1), before);
    await expectTainted(_c1, carol.id);
  });

  test('a rejoin on a third key stays unknown', () async {
    final carol = await RigPeer.create('carol');
    final k2 = Uint8List.fromList(List.filled(32, 2));
    final k3 = Uint8List.fromList(List.filled(32, 3));
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, k3),
    ];
    rig.header(_c1, 'ref-bob');
    // This device left generation 1, where carol was pinned theirs on k2:
    // the history holds her with that key.
    const formerPins = FormerPins();
    final v = rig.device.vault;
    await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key), (carol.id, k2)]);
    await v.transaction((tx) async {
      await tx.putConversationSync(
        _c1,
        const ConversationSync(requestAccepted: true),
      );
      await tx.setAfterPair(_c1, const MlsPair(1, 3));
      await tx.setJoinHighWater(_c1, const MlsPair(1, 0));
      await formerPins.putIn(tx, v, _c1, [
        MemberRecord(
          conversationId: _c1,
          deviceId: bob.id,
          signatureKey: bob.key,
          side: MemberSide.theirs,
          since: const MlsPair(1, 1),
        ),
        MemberRecord(
          conversationId: _c1,
          deviceId: carol.id,
          signatureKey: k2,
          side: MemberSide.theirs,
          since: const MlsPair(1, 1),
        ),
      ]);
    });

    // The rejoin holds carol on k3, which the directory lists.
    await rig.offer(
      _c1,
      bob,
      generation: 2,
      others: [await carol.keyPackage()],
    );
    rig.device.engine.describeMembers = (real) => [
      for (final m in real)
        rigEq(m.deviceId, carol.id)
            ? GroupMember(deviceId: carol.id, signaturePublicKey: k3)
            : m,
    ];
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);

    final carolPin = (await v.members(_c1))
        .singleWhere((m) => rigEq(m.deviceId, carol.id));
    expect(carolPin.side, MemberSide.unattributed);
    await expectTainted(_c1, carol.id);
    // Bob, on the key the history holds, gets his former side back.
    expect((await pinIn(_c1, bob.id))!.side, MemberSide.theirs);
    expect(
      linesOf(await rig.lines(_c1), carol.id),
      isNot(contains(SystemLine.deviceAdded)),
    );
  });

  test('a tainted device that changes key again at a join stays '
      'unknown', () async {
    final carol = await RigPeer.create('carol');
    final k3 = Uint8List.fromList(List.filled(32, 3));
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      rigKeyDevice(carol.idString, k3),
    ];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);
    final v = rig.device.vault;
    // Carol was tainted earlier (k2 was her second key) and holds no pin now
    // (she left), and no former pin holds her: only the history knows.
    await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], changed: [carol.id]);

    await rig.offer(
      _c1,
      bob,
      generation: 2,
      others: [await carol.keyPackage()],
    );
    rig.device.engine.describeMembers = (real) => [
      for (final m in real)
        rigEq(m.deviceId, carol.id)
            ? GroupMember(deviceId: carol.id, signaturePublicKey: k3)
            : m,
    ];
    expect(await rig.crypto.processWelcomes(), [_c1]);
    rig.device.engine.describeMembers = null;
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);

    final carolPin = (await v.members(_c1))
        .singleWhere((m) => rigEq(m.deviceId, carol.id));
    expect(carolPin.side, MemberSide.unattributed);
    expect(rigEq(carolPin.signatureKey, k3), isTrue);
    await expectTainted(_c1, carol.id);
    expect((await pinIn(_c1, bob.id))!.side, MemberSide.theirs);
    expect(
      linesOf(await rig.lines(_c1), carol.id),
      isNot(contains(SystemLine.deviceAdded)),
    );
  });

  test('an ordinary unknown device listed later is still attributed (a '
      'later join)', () async {
    final carol = await RigPeer.create('carol');
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
    await rig.offer(_c1, bob);
    expect(await rig.crypto.processWelcomes(), [_c1]);

    // Generation 2 adds carol, whom the counting fetch does not list.
    rig.clock.advance(const Duration(seconds: 61));
    await rig.offer(
      _c1,
      bob,
      generation: 2,
      others: [await carol.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [_c1]);
    final v = rig.device.vault;
    MemberRecord pinOf(List<MemberRecord> all, Uint8List id) =>
        all.singleWhere((m) => rigEq(m.deviceId, id));
    expect(pinOf(await v.members(_c1), carol.id).side, MemberSide.unattributed);
    expect(linesOf(await rig.lines(_c1), carol.id), [SystemLine.unknownDevice]);

    // A later attribution pass sees carol listed.
    rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
    rig.directory.clear();
    rig.clock.advance(const Duration(minutes: 3));
    await rig.crypto.attributeMembers(_c1);

    expect(pinOf(await v.members(_c1), carol.id).side, MemberSide.theirs);
    expect(
      linesOf(await rig.lines(_c1), carol.id),
      unorderedEquals([SystemLine.unknownDevice, SystemLine.deviceAdded]),
    );
    final state = await rig.crypto.describeState(_c1);
    expect(state.unknownDevicePresent, isFalse);
  });

  test('a welcome the engine refuses for good is acknowledged as permanent '
      'and paging continues', () async {
    final ids = [for (var i = 0; i < 12; i++) _conv(i)];
    final offers = <RigOffer>[];
    for (final id in ids) {
      offers.add(await rig.offer(id, bob));
    }
    // The whole first page is refused for good (evicted is not transient);
    // the engine answers again once that page was acknowledged.
    rig.device.engine.failAlways['joinFromWelcome'] = const MlsException(
      MlsErrorCode.evicted,
      'rig',
    );
    rig.server.onCall = (call) async {
      if (call == 'ackWelcomes') {
        rig.device.engine.failAlways.remove('joinFromWelcome');
      }
    };

    final joined = await rig.crypto.processWelcomes();

    expect(joined, ids.sublist(10));
    expect(rig.server.listedFor, hasLength(2));
    expect(await ackedIds(), [for (final o in offers) o.welcomeId]);
    for (final id in ids.sublist(0, 10)) {
      expect(await rig.device.vault.group(id, 1), isNull);
    }
  });

  test('settling a provisional group reads from the stored after-pair with '
      "the contract's page size", () async {
    await rig.dispose();
    late _Recording recording;
    rig = await RigCrypto.create(messaging: (s) => recording = _Recording(s));
    bob = await RigPeer.create('bob');
    final v = rig.device.vault;
    rig.server.addCommit(
      _c1,
      const MlsPair(1, 0),
      rigBytes('generation 1'),
      fromUser: 'user-b',
    );
    await v.transaction((tx) async {
      await tx.putConversationSync(_c1, const ConversationSync());
      await tx.setAfterPair(_c1, const MlsPair(1, 0));
      await tx.putGroup(
        GroupRecord(
          conversationId: _c1,
          generation: 2,
          epoch: 1,
          state: rigBytes('a provisional state'),
          provisional: true,
          provisionalCreatedAtMicros: rig.clock.now().microsecondsSinceEpoch,
          pending: PendingCommit(
            kind: PendingKind.init,
            builtOn: const MlsPair(2, 0),
            commit: rigBytes('this device init'),
          ),
        ),
      );
    });
    // Another device's init of generation 2 was stored first.
    await rig.offer(_c1, bob, generation: 2);

    expect(await rig.crypto.processWelcomes(), [_c1]);

    // [0] the welcome's server-pair read; [1] the settle read.
    expect(recording.commitCalls[1], (
      after: const MlsPair(1, 0),
      pageSize: kCommitPageSize,
    ));
    expect((await v.group(_c1, 2))!.provisional, isFalse);
  });

  test('an own init at or below the after-pair makes its welcome a '
      'permanent replay', () async {
    final v = rig.device.vault;
    final init = rigBytes('this device init');
    await v.transaction((tx) async {
      await tx.putConversationSync(_c1, const ConversationSync());
      await tx.setAfterPair(_c1, const MlsPair(1, 0));
      await tx.putGroup(
        GroupRecord(
          conversationId: _c1,
          generation: 1,
          epoch: 1,
          state: rigBytes('a provisional state'),
          provisional: true,
          provisionalCreatedAtMicros: rig.clock.now().microsecondsSinceEpoch,
          pending: PendingCommit(
            kind: PendingKind.init,
            builtOn: const MlsPair(1, 0),
            commit: init,
          ),
        ),
      );
    });
    rig.server.addCommit(_c1, const MlsPair(1, 0), init, fromUser: 'user-a');
    final w = rig.server.addWelcome(
      rig.device.deviceIdString,
      _c1,
      const MlsPair(1, 1),
      Uint8List(4),
    );
    final before = await rig.dump();
    rig.device.engine.calls.clear();

    expect(await rig.crypto.processWelcomes(), isEmpty);

    expect(await ackedIds(), [w]);
    expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
    expect(await rig.dump(), before);
  });

  test('a welcome listed again by a nested poll before the outer poll '
      'acknowledged it is acknowledged once', () async {
    final offer = await rig.offer(_c1, bob);
    // The server moves to generation 2 while the join runs: the catch-up
    // after the join switches generations and polls welcomes, which still
    // lists this welcome (the outer poll acknowledges after the page).
    var commitReads = 0;
    rig.server.onCall = (call) async {
      if (call == 'listConversationCommits' && ++commitReads == 2) {
        rig.server.addCommit(
          _c1,
          const MlsPair(2, 0),
          rigBytes('a reset of another device'),
          fromUser: 'user-b',
        );
      }
    };

    expect(await rig.crypto.processWelcomes(), [_c1]);

    expect(rig.server.listedFor.length, greaterThanOrEqualTo(2));
    expect(await ackedIds(), [offer.welcomeId]);
    expect(await rig.device.vault.group(_c1, 1), isNotNull);
  });

  test('two welcomes in one poll: the second join starts from the device '
      'state the first one stored', () async {
    final spy = _JoinSpy();
    rig.crypto = ConversationCrypto(
      session: rig.device.session,
      engine: () => spy,
      messaging: rig.messaging,
      directory: rig.directory,
      syncBudget: rig.syncBudget,
      locks: rig.locks,
      contexts: rig.contexts,
      known: rig.known,
      now: rig.clock.now,
      onChanged: rig.changed.add,
      onUnexpectedError: (e, _) => rig.unexpected.add(e),
    );
    await rig.offer(_c1, bob);
    await rig.offer(_c2, bob);
    final start = (await rig.device.vault.deviceState())!;

    expect((await rig.crypto.processWelcomes()).toSet(), {_c1, _c2});

    expect(spy.inputs, hasLength(2));
    expect(rigEq(spy.inputs[0], start), isTrue);
    expect(rigEq(spy.inputs[1], spy.outputs[0]), isTrue);
    expect(
      rigEq((await rig.device.vault.deviceState())!, spy.outputs[1]),
      isTrue,
    );
  });
}
