import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/guarded_crypto_engine.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/former_pins.dart';
import 'package:dzeroth/features/messages/domain/e2ee/known_conversations.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';

/// Records every call, with the epoch of the stored group at that moment.
class _Sink implements EpochMessageSink {
  _Sink(this.vault);

  final SecureVault Function() vault;
  final List<String> calls = [];

  @override
  Future<void> completeEpoch(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) async {
    final g = await vault().group(conversationId, pair.generation);
    calls.add('complete ${pair.generation}:${pair.epoch} at ${g?.epoch}');
  }

  @override
  Future<void> markEpochUndecryptable(
    String conversationId,
    MlsPair pair, {
    required BudgetPriority priority,
  }) async {
    calls.add('undecryptable ${pair.generation}:${pair.epoch}');
  }
}

/// A sync budget that counts the units taken.
class _CountingBudget extends SyncBudget {
  _CountingBudget(DateTime Function() now)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: now);

  int taken = 0;

  @override
  Future<void> take(BudgetPriority priority) {
    taken++;
    return super.take(priority);
  }
}

/// Records the `after` of every `ListConversationCommits` call.
class _Recording extends RigMessaging {
  _Recording(RigServer server) : super(server, 'user-a');

  final List<MlsPair?> afters = [];

  @override
  Future<pb.ListConversationCommitsResponse> listConversationCommits({
    required String conversationId,
    required MlsPair? after,
    int pageSize = 0,
  }) {
    afters.add(after);
    return super.listConversationCommits(
      conversationId: conversationId,
      after: after,
      pageSize: pageSize,
    );
  }
}

/// Rewrites the commit event of every `process` call (the fake engine never
/// removes and adds one id in a single commit; the contract allows it).
class _EventRewrite extends RigEngine {
  MlsCommitEvent Function(MlsCommitEvent event)? rewrite;

  @override
  Future<ProcessResult> process(
    Uint8List deviceState,
    Uint8List groupState,
    Uint8List wire,
  ) async {
    final real = await super.process(deviceState, groupState, wire);
    final event = real.event;
    final f = rewrite;
    if (f == null || event is! MlsCommitEvent) return real;
    return ProcessResult(groupState: real.groupState, event: f(event));
  }
}

/// The rig's key directory with a hook that runs before every peer lookup
/// (between the start of an attribution and its write body).
class _HookKeys implements KeysRepository {
  _HookKeys(this.inner);

  final RigKeys inner;
  void Function()? beforePeer;

  @override
  Future<kpb.ListMyKeyDevicesResponse> listMine() => inner.listMine();

  @override
  Future<kpb.GetKeyDevicesResponse> getDevices(List<String> userIds) {
    beforePeer?.call();
    return inner.getDevices(userIds);
  }

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late _Sink sink;

  /// The `keyHistory.read` reports the running test expects (checked and
  /// reset by the shared tearDown).
  var unreadableHistories = 0;

  void rebuild({CryptoEngine Function()? engine}) {
    rig.crypto = ConversationCrypto(
      session: rig.device.session,
      engine: engine ?? () => rig.device.engine,
      messaging: rig.messaging,
      directory: rig.directory,
      syncBudget: rig.syncBudget,
      locks: rig.locks,
      contexts: rig.contexts,
      known: rig.known,
      now: rig.clock.now,
      onChanged: rig.changed.add,
      onUnexpectedError: (e, _) => rig.unexpected.add(e),
    )..sink = sink;
  }

  Future<void> setUpRig({
    RigMessaging Function(RigServer server)? messaging,
  }) async {
    rig = await RigCrypto.create(messaging: messaging);
    bob = await RigPeer.create('bob');
    sink = _Sink(() => rig.device.vault);
    rig.crypto.sink = sink;
    rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
  }

  tearDown(() async {
    final refused = rig.server.refusedAcks.length;
    // An unreadable key history fails closed, so a test could pass under
    // one without meaning to: only a test that says so may meet one.
    final unreadable = rig.keyHistoryErrors.length;
    final expected = unreadableHistories;
    unreadableHistories = 0;
    expect(unreadable, expected, reason: 'unreadable key histories');
    await rig.dispose();
    // The client swallows a refused ack: every test fails on one.
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
  });

  /// This device joins [c] from bob's welcome (generation 1), with the
  /// devices of [others] in the group too.
  Future<RigOffer> join(
    String c, {
    bool accepted = true,
    List<RigPeer> others = const [],
    int generation = 1,
  }) async {
    if (accepted) await rig.accept(c);
    rig.header(c, 'ref-bob');
    final offer = await rig.offer(
      c,
      bob,
      generation: generation,
      others: [for (final p in others) await p.keyPackage()],
    );
    expect(await rig.crypto.processWelcomes(), [c]);
    return offer;
  }

  /// Bob commits on [offer]'s group, built on the server's current pair.
  Future<MlsPair> bobCommit(
    RigOffer offer,
    String c, {
    List<RigPeer> add = const [],
    List<Uint8List> remove = const [],
  }) async {
    final at = rig.server.current(c);
    final r = await rigCommit(
      offer.add.group,
      add: [for (final p in add) await p.keyPackage()],
      remove: remove,
    );
    rig.server.addCommit(c, at, r.commit, fromUser: 'user-b');
    return at;
  }

  Future<MemberRecord?> pin(String c, Uint8List id) async {
    for (final m in await rig.device.vault.members(c)) {
      if (rigEq(m.deviceId, id)) return m;
    }
    return null;
  }

  int count(List<String> calls, String name) =>
      calls.where((c) => c == name).length;

  /// [id] is tainted in [c]'s key history (in `changed`, its key no longer
  /// kept), and the history was read: a refusal from an unreadable history
  /// would pass the pin assertions too.
  Future<void> expectTainted(String c, Uint8List id) async {
    final hex = vaultDeviceIdHex(id);
    expect(await rig.keyHistoryChanged(c), contains(hex));
    expect((await rig.keyHistoryIds(c)).keys, isNot(contains(hex)));
    expect(rig.keyHistoryErrors, isEmpty);
  }

  /// [id] is recorded in [c]'s key history with [key] and is not tainted.
  Future<void> expectRecorded(String c, Uint8List id, Uint8List key) async {
    final hex = vaultDeviceIdHex(id);
    expect((await rig.keyHistoryIds(c))[hex], base64Encode(key));
    expect(await rig.keyHistoryChanged(c), isNot(contains(hex)));
  }

  List<String> linesOf(List<SystemLineContent> lines, Uint8List id) => [
    for (final l in lines)
      if (rigEq(l.deviceId ?? const [], id)) l.line,
  ];

  group('commits', () {
    setUp(() => setUpRig());

    test('commits are applied in order and the after-pair follows', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      await bobCommit(offer, _c1, add: [dave]);
      await bobCommit(offer, _c1, remove: [carol.id]);
      rig.device.engine.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      final v = rig.device.vault;
      expect((await v.group(_c1, 1))!.epoch, 4);
      expect((await v.conversation(_c1))!.afterPair, const MlsPair(1, 3));
      expect(count(rig.device.engine.calls, 'process'), 3);
      expect(await pin(_c1, carol.id), isNull);
      expect(await pin(_c1, dave.id), isNotNull);
      final sync = (await v.conversation(_c1))!.sync;
      // Only a stored generation's walked LAST epoch is kept (L6's check):
      // an epoch a commit closed is never a stored group's epoch again.
      expect(sync.completedEpochs, isEmpty);
      expect(sync.epochMustAdvance, isFalse);
      // A second pass has nothing to do.
      rig.device.engine.calls.clear();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(rig.device.engine.calls, isNot(contains('process')));
    });

    test("the epoch's messages are completed before its commit is "
        'applied', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      await bobCommit(offer, _c1, add: [dave]);
      sink.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      // Each epoch once, while the stored group was still at that epoch.
      expect(sink.calls, ['complete 1:1 at 1', 'complete 1:2 at 2']);
    });

    test('an own commit is recognised by bytes and confirmed, never '
        'processed', () async {
      final carol = await RigPeer.create('carol');
      await join(_c1);
      final v = rig.device.vault;
      final engine = rig.device.engine.inner;
      final stored = (await v.group(_c1, 1))!;
      final commit = await engine.commitChange(
        (await v.deviceState())!,
        stored.state,
        addKeyPackages: [await carol.keyPackage()],
      );
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: commit.groupState,
            pending: PendingCommit(
              kind: PendingKind.change,
              builtOn: const MlsPair(1, 1),
              commit: commit.commit,
              welcome: commit.welcome,
              welcomeDeviceIds: [carol.idString],
            ),
          ),
        ),
      );
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 1),
        commit.commit,
        fromUser: 'user-a',
      );
      rig.device.engine.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(rig.device.engine.calls, contains('confirmCommit'));
      expect(rig.device.engine.calls, isNot(contains('process')));
      final group = (await v.group(_c1, 1))!;
      expect(group.epoch, 2);
      expect(group.pending, isNull);
      expect((await v.conversation(_c1))!.afterPair, const MlsPair(1, 1));
      // The member the own commit added is pinned (to be attributed).
      expect(await pin(_c1, carol.id), isNotNull);
    });

    test('a winning commit from another device drops the pending '
        'record', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final offer = await join(_c1);
      final v = rig.device.vault;
      final stored = (await v.group(_c1, 1))!;
      final mine = await rig.device.engine.inner.commitChange(
        (await v.deviceState())!,
        stored.state,
        addKeyPackages: [await dave.keyPackage()],
      );
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: mine.groupState,
            pending: PendingCommit(
              kind: PendingKind.change,
              builtOn: const MlsPair(1, 1),
              commit: mine.commit,
            ),
          ),
        ),
      );
      await bobCommit(offer, _c1, add: [carol]);
      rig.device.engine.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(rig.device.engine.calls, contains('process'));
      expect(rig.device.engine.calls, isNot(contains('confirmCommit')));
      final group = (await v.group(_c1, 1))!;
      expect(group.epoch, 2);
      expect(group.pending, isNull);
      expect(await pin(_c1, carol.id), isNotNull);
      expect(await pin(_c1, dave.id), isNull);
    });

    test('a removed member loses its pin and gets one deviceRemoved row with '
        'its side', () async {
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      expect(await rig.lines(_c1), isEmpty);

      await bobCommit(offer, _c1, remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // A second pass writes nothing more.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await pin(_c1, carol.id), isNull);
      final lines = await rig.lines(_c1);
      expect(lines, hasLength(1));
      expect(lines.single.line, SystemLine.deviceRemoved);
      expect(lines.single.side, MemberSide.theirs);
      expect(rigEq(lines.single.deviceId!, carol.id), isTrue);
    });

    test('an added member is pinned unattributed until attribution', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      rig.keys.peerFails = true;

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      final added = (await pin(_c1, carol.id))!;
      expect(added.side, MemberSide.unattributed);
      expect(added.since, const MlsPair(1, 2));
      expect(rigEq(added.signatureKey, carol.key), isTrue);

      rig.keys.peerFails = false;
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      final lines = await rig.lines(_c1);
      expect(lines, hasLength(1));
      expect(lines.single.line, SystemLine.deviceAdded);
      expect(lines.single.side, MemberSide.theirs);
    });

    test('a member whose signature key changed under the same device id is '
        'unattributed, never re-pinned to its side', () async {
      final offer = await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      final carol = await RigPeer.create('carol');
      await bobCommit(offer, _c1, add: [carol]);
      final newKey = Uint8List.fromList(List.filled(32, 9));
      // The group now reports bob's id with another key.
      rig.device.engine.describeMembers = (real) => [
        for (final m in real)
          rigEq(m.deviceId, bob.id)
              ? GroupMember(deviceId: bob.id, signaturePublicKey: newKey)
              : m,
      ];

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;

      final changed = (await pin(_c1, bob.id))!;
      expect(changed.side, MemberSide.unattributed);
      expect(rigEq(changed.signatureKey, newKey), isTrue);
      await expectTainted(_c1, bob.id);
      final state = await rig.crypto.describeState(_c1);
      expect(state.unattributedPresent, isTrue);
      expect(state.sendBlock, isNot(SendBlock.none));
    });

    test('a device whose key changed stays an unknown device even when the '
        'directory lists the new key', () async {
      final offer = await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      final carol = await RigPeer.create('carol');
      final newKey = Uint8List.fromList(List.filled(32, 9));
      // The directory now lists bob's id with the new key (and carol).
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, newKey),
        rigKeyDevice(carol.idString, carol.key),
      ];
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [carol]);
      rig.device.engine.describeMembers = (real) => [
        for (final m in real)
          rigEq(m.deviceId, bob.id)
              ? GroupMember(deviceId: bob.id, signaturePublicKey: newKey)
              : m,
      ];

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // Past the recheck time, attribution runs again: still unknown.
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;

      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      await expectTainted(_c1, bob.id);
      // A bystander of the same commit is attributed as usual.
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      final bobLines = [
        for (final l in await rig.lines(_c1))
          if (rigEq(l.deviceId ?? const [], bob.id)) l.line,
      ];
      expect(bobLines, [SystemLine.unknownDevice]);
      final state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isTrue);
      expect(state.sendBlock, SendBlock.unknownDevice);
    });

    test('an unaccepted conversation with a changed key stays unknown after '
        'acceptance even when the new key is listed', () async {
      final offer = await join(_c1, accepted: false);
      // Unaccepted, the lookup still pins bob from the list.
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      final carol = await RigPeer.create('carol');
      final newKey = Uint8List.fromList(List.filled(32, 9));
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, newKey),
        rigKeyDevice(carol.idString, carol.key),
      ];
      await bobCommit(offer, _c1, add: [carol]);
      rig.device.engine.describeMembers = (real) => [
        for (final m in real)
          rigEq(m.deviceId, bob.id)
              ? GroupMember(deviceId: bob.id, signaturePublicKey: newKey)
              : m,
      ];

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;
      // Tainted in the commit's transaction although unaccepted; no row yet.
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      await expectTainted(_c1, bob.id);
      expect(linesOf(await rig.lines(_c1), bob.id), isEmpty);

      // Accepted later (a restart between): still unknown, now with its row.
      await rig.restart();
      rig.crypto.sink = sink;
      await rig.accept(_c1);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      expect(linesOf(await rig.lines(_c1), bob.id), [SystemLine.unknownDevice]);
      final state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isTrue);
      expect(state.sendBlock, SendBlock.unknownDevice);
    });

    test('a device that leaves keeps its key history', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      final newKey = Uint8List.fromList(List.filled(32, 4));
      await bobCommit(offer, _c1, add: [dave]);
      rig.device.engine.describeMembers = (real) => [
        for (final m in real)
          rigEq(m.deviceId, carol.id)
              ? GroupMember(deviceId: carol.id, signaturePublicKey: newKey)
              : m,
      ];
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;
      await expectTainted(_c1, carol.id);
      await expectRecorded(_c1, dave.id, dave.key);
      final before = await rig.keyHistory(_c1);

      // The tainted device and an ordinary one both leave.
      await bobCommit(offer, _c1, remove: [carol.id, dave.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await pin(_c1, carol.id), isNull);
      expect(await pin(_c1, dave.id), isNull);
      // Nothing ever leaves the history: the taint and the recorded key stay.
      expect(await rig.keyHistory(_c1), before);
      await expectTainted(_c1, carol.id);
      await expectRecorded(_c1, dave.id, dave.key);
    });

    test('a changed key stays unknown after this device is removed and '
        'rejoins on that key', () async {
      final carol = await RigPeer.create('carol');
      final newKey = Uint8List.fromList(List.filled(32, 9));
      List<GroupMember> bobOnNewKey(List<GroupMember> real) => [
        for (final m in real)
          rigEq(m.deviceId, bob.id)
              ? GroupMember(deviceId: bob.id, signaturePublicKey: newKey)
              : m,
      ];
      final offer = await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      await bobCommit(offer, _c1, add: [carol]);
      rig.device.engine.describeMembers = bobOnNewKey;
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await expectTainted(_c1, bob.id);

      // This device is removed: the former pins keep bob on the new key.
      await bobCommit(offer, _c1, remove: [rig.device.deviceId]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      expect(await rig.device.vault.members(_c1), isEmpty);

      // A rejoin in generation 2 with bob on that key, which is listed now.
      rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, newKey)];
      rig.directory.clear();
      await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      rig.device.engine.describeMembers = null;

      final bobPin = (await pin(_c1, bob.id))!;
      expect(bobPin.side, MemberSide.unattributed);
      expect(rigEq(bobPin.signatureKey, newKey), isTrue);
      await expectTainted(_c1, bob.id);
      expect(
        linesOf(await rig.lines(_c1), bob.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
    });

    test('a changed key stays unknown after the device is removed and added '
        'again on that key', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final erin = await RigPeer.create('erin');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      final newKey = Uint8List.fromList(List.filled(32, 4));
      List<GroupMember> carolOnNewKey(List<GroupMember> real) => [
        for (final m in real)
          rigEq(m.deviceId, carol.id)
              ? GroupMember(deviceId: carol.id, signaturePublicKey: newKey)
              : m,
      ];
      await bobCommit(offer, _c1, add: [dave]);
      rig.device.engine.describeMembers = carolOnNewKey;
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      // Removed by one commit, added again on the same new key by a later
      // one; the directory lists that key.
      await bobCommit(offer, _c1, remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await pin(_c1, carol.id), isNull);
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, newKey),
        rigKeyDevice(dave.idString, dave.key),
        rigKeyDevice(erin.idString, erin.key),
      ];
      rig.directory.clear();
      await bobCommit(offer, _c1, add: [carol, erin]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      rig.device.engine.describeMembers = null;

      final carolPin = (await pin(_c1, carol.id))!;
      expect(carolPin.side, MemberSide.unattributed);
      expect(rigEq(carolPin.signatureKey, newKey), isTrue);
      expect((await pin(_c1, erin.id))!.side, MemberSide.theirs);
      await expectTainted(_c1, carol.id);
      expect(
        linesOf(await rig.lines(_c1), carol.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
    });

    test('a commit that removes and re-adds a device id with another key '
        'taints it', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      final newKey = Uint8List.fromList(List.filled(32, 6));
      // One commit (the contract allows an id in both lists): carol is
      // removed and added again with another key.
      final engine = _EventRewrite();
      engine.rewrite = (e) => MlsCommitEvent(
        epoch: e.epoch,
        committerDeviceId: e.committerDeviceId,
        added: [...e.added, carol.id],
        addedSignatureKeys: [...e.addedSignatureKeys, newKey],
        removed: [...e.removed, carol.id],
        selfRemoved: e.selfRemoved,
      );
      engine.describeMembers = (real) => [
        for (final m in real)
          rigEq(m.deviceId, carol.id)
              ? GroupMember(deviceId: carol.id, signaturePublicKey: newKey)
              : m,
      ];
      rebuild(engine: () => engine);
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, newKey),
        rigKeyDevice(dave.idString, dave.key),
      ];
      rig.directory.clear();
      await bobCommit(offer, _c1, add: [dave]);

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      final carolPin = (await pin(_c1, carol.id))!;
      expect(carolPin.side, MemberSide.unattributed);
      expect(rigEq(carolPin.signatureKey, newKey), isTrue);
      await expectTainted(_c1, carol.id);
      // A bystander of the same commit is attributed as usual.
      expect((await pin(_c1, dave.id))!.side, MemberSide.theirs);
      expect(
        linesOf(await rig.lines(_c1), carol.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
    });

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

    test('a device removed by one commit and re-added on another key by a '
        'later commit stays unknown', () async {
      final carol = await RigPeer.create('carol');
      final erin = await RigPeer.create('erin');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);

      // Commit N removes carol: her pin goes, her recorded key does not.
      await bobCommit(offer, _c1, remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await pin(_c1, carol.id), isNull);

      // Commit N+1 adds her again on another key, which the directory lists.
      final newKey = Uint8List.fromList(List.filled(32, 4));
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, newKey),
        rigKeyDevice(erin.idString, erin.key),
      ];
      rig.directory.clear();
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [carol, erin]);
      rig.device.engine.describeMembers = onKey(carol.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      rig.device.engine.describeMembers = null;

      final carolPin = (await pin(_c1, carol.id))!;
      expect(carolPin.side, MemberSide.unattributed);
      expect(rigEq(carolPin.signatureKey, newKey), isTrue);
      await expectTainted(_c1, carol.id);
      expect((await pin(_c1, erin.id))!.side, MemberSide.theirs);
      final carolLines = linesOf(await rig.lines(_c1), carol.id);
      expect(carolLines, isNot(contains(SystemLine.deviceAdded)));
      expect(carolLines, contains(SystemLine.unknownDevice));
    });

    test('a device seen only while unaccepted, dropped by a join and re-added '
        'on another key stays unknown after acceptance', () async {
      final carol = await RigPeer.create('carol');
      final erin = await RigPeer.create('erin');
      await join(_c1, accepted: false, others: [carol]);
      expect(await pin(_c1, carol.id), isNotNull);
      expect(await rig.lines(_c1), isEmpty);

      // Generation 2 no longer holds carol: her pin goes.
      final second = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(await pin(_c1, carol.id), isNull);

      // A commit of generation 2 adds her on another key, which is listed.
      final newKey = Uint8List.fromList(List.filled(32, 4));
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, newKey),
        rigKeyDevice(erin.idString, erin.key),
      ];
      rig.directory.clear();
      await bobCommit(second, _c1, add: [carol, erin]);
      rig.device.engine.describeMembers = onKey(carol.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await rig.lines(_c1), isEmpty);

      await rig.accept(_c1);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      await rig.crypto.attributeMembers(_c1);
      rig.device.engine.describeMembers = null;

      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      await expectTainted(_c1, carol.id);
      expect((await pin(_c1, erin.id))!.side, MemberSide.theirs);
      expect(linesOf(await rig.lines(_c1), carol.id), [
        SystemLine.unknownDevice,
      ]);
    });

    test('a device id that returns to its first key stays unknown', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final erin = await RigPeer.create('erin');
      rig.keys.peers['ref-bob']!
        ..add(rigKeyDevice(carol.idString, carol.key))
        ..add(rigKeyDevice(dave.idString, dave.key))
        ..add(rigKeyDevice(erin.idString, erin.key));
      final offer = await join(_c1, others: [carol]);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);

      // Another key under her id, then her first key again; the directory
      // lists the first key all along.
      final newKey = Uint8List.fromList(List.filled(32, 4));
      await bobCommit(offer, _c1, add: [dave]);
      rig.device.engine.describeMembers = onKey(carol.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;
      await bobCommit(offer, _c1, add: [erin]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      final carolPin = (await pin(_c1, carol.id))!;
      expect(rigEq(carolPin.signatureKey, carol.key), isTrue);
      expect(carolPin.side, MemberSide.unattributed);
      await expectTainted(_c1, carol.id);
      expect((await pin(_c1, erin.id))!.side, MemberSide.theirs);
      expect(
        linesOf(await rig.lines(_c1), carol.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
    });

    test('a tainted device re-added on a third key stays unknown', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final erin = await RigPeer.create('erin');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      final k2 = Uint8List.fromList(List.filled(32, 2));
      final k3 = Uint8List.fromList(List.filled(32, 3));
      await bobCommit(offer, _c1, add: [dave]);
      rig.device.engine.describeMembers = onKey(carol.id, k2);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await expectTainted(_c1, carol.id);
      await bobCommit(offer, _c1, remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await pin(_c1, carol.id), isNull);

      // Added again on a third key, which the directory lists.
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, k3),
        rigKeyDevice(dave.idString, dave.key),
        rigKeyDevice(erin.idString, erin.key),
      ];
      rig.directory.clear();
      await bobCommit(offer, _c1, add: [carol, erin]);
      rig.device.engine.describeMembers = onKey(carol.id, k3);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      rig.device.engine.describeMembers = null;

      final carolPin = (await pin(_c1, carol.id))!;
      expect(rigEq(carolPin.signatureKey, k3), isTrue);
      expect(carolPin.side, MemberSide.unattributed);
      await expectTainted(_c1, carol.id);
      expect((await pin(_c1, erin.id))!.side, MemberSide.theirs);
      expect(
        linesOf(await rig.lines(_c1), carol.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
    });

    test('a commit that pins nothing new leaves the key history bytes '
        'unchanged', () async {
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final dave = await RigPeer.create('dave');
      final offer = await join(_c1, others: [carol, dave]);
      final before = await rig.sealedSetting('messages.e2ee.keys.$_c1');
      expect(before, isNotNull);

      await bobCommit(offer, _c1, remove: [carol.id]);
      await bobCommit(offer, _c1, remove: [dave.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.crypto.attributeMembers(_c1);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 3);
      expect(await rig.sealedSetting('messages.e2ee.keys.$_c1'), before);
      expect(rig.keyHistoryErrors, isEmpty);
    });

    test('the key history is one sealed setting per conversation whose value '
        'holds no id or key in clear', () async {
      const c2 = '22222222222222222222222222222222';
      final carol = await RigPeer.create('carol');
      await join(_c1);
      await join(c2, others: [carol]);

      expect(await rig.keyHistory(_c1), {
        'v': 1,
        'ids': {vaultDeviceIdHex(bob.id): base64Encode(bob.key)},
        'changed': <Object?>[],
        'held': <String, Object?>{},
        'closed': false,
        'allow': 256,
      });
      // This device is never recorded.
      expect((await rig.keyHistoryIds(c2)).keys.toSet(), {
        vaultDeviceIdHex(bob.id),
        vaultDeviceIdHex(carol.id),
      });
      // No vault-wide marker is left.
      expect(
        await rig.device.vault.setting('messages.e2ee.keyChanged'),
        isNull,
      );
      for (final c in [_c1, c2]) {
        final sealed = latin1.decode(
          (await rig.sealedSetting('messages.e2ee.keys.$c'))!,
        );
        for (final clear in [
          vaultDeviceIdHex(bob.id),
          utf8.decode(bob.id),
          base64Encode(bob.key),
          latin1.decode(bob.key),
          '"ids"',
          c,
        ]) {
          expect(sealed, isNot(contains(clear)));
        }
      }
    });

    test('selfRemoved, a removal, a join drop and a provisional discard leave '
        'the key history unchanged', () async {
      const c2 = '22222222222222222222222222222222';
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final erin = await RigPeer.create('erin');
      final offer = await join(_c1, others: [carol, dave]);
      final history = await rig.keyHistory(_c1);
      expect((history!['ids']! as Map<String, Object?>).keys, hasLength(3));

      // A removal by a commit.
      await bobCommit(offer, _c1, remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await pin(_c1, carol.id), isNull);
      expect(await rig.keyHistory(_c1), history);

      // A join that drops a device.
      final second = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(await pin(_c1, dave.id), isNull);
      expect(await rig.keyHistory(_c1), history);

      // selfRemoved.
      await bobCommit(second, _c1, remove: [rig.device.deviceId]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      expect(await rig.device.vault.members(_c1), isEmpty);
      expect(await rig.keyHistory(_c1), history);

      // A provisional group (bob and erin pinned) discarded for the winner's
      // welcome, which holds bob only.
      rig.header(c2, 'ref-bob');
      await rig.seedProvisional(c2, [bob, erin]);
      final provisional = await rig.keyHistory(c2);
      await rig.offer(c2, bob);
      expect(await rig.crypto.processWelcomes(), [c2]);
      expect((await rig.device.vault.group(c2, 1))!.provisional, isFalse);
      expect(await pin(c2, erin.id), isNull);
      expect(await rig.keyHistory(c2), provisional);
      expect(rig.keyHistoryErrors, isEmpty);
    });

    test('applying a commit for a stored group not yet in the known set '
        'notes it as ever encrypted', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      // The known set lost the id (a migrated v1 group was never in it).
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingKnownConversations,
          rigBytes('{"v":1,"ids":[],"peers":{}}'),
        ),
      );
      await rig.known.load(rig.device.vault);
      expect(rig.known.contains(_c1), isFalse);
      await bobCommit(offer, _c1, add: [carol]);
      rig.messaging.noted.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(rig.known.contains(_c1), isTrue);
      expect([for (final n in rig.messaging.noted) n.id], [_c1]);
      expect(rig.messaging.noted.single.session, rig.messaging.cacheSession);
    });

    test('attribution that adds a conversation not yet in the known set '
        'notes it as ever encrypted', () async {
      rig.keys.peerFails = true;
      await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      // The known set lost the id (a migrated v1 group was never in it).
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingKnownConversations,
          rigBytes('{"v":1,"ids":[],"peers":{}}'),
        ),
      );
      await rig.known.load(rig.device.vault);
      rig.messaging.noted.clear();

      rig.keys.peerFails = false;
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect(rig.known.contains(_c1), isTrue);
      expect(rig.known.peerOf(_c1), 'ref-bob');
      expect([for (final n in rig.messaging.noted) n.id], [_c1]);
      expect(rig.messaging.noted.single.session, rig.messaging.cacheSession);

      // A ref added for an id already known notes nothing more.
      rig.messaging.noted.clear();
      await rig.crypto.attributeMembers(_c1);
      expect(rig.messaging.noted, isEmpty);
    });

    test('a NONE conversation is notEncrypted', () async {
      final before = await rig.dump();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.notEncrypted);
      expect(rig.server.calls, ['listConversationCommits']);
      expect(await rig.dump(), before);
      expect(rig.known.contains(_c1), isFalse);
      final state = await rig.crypto.describeState(_c1);
      expect(state.phase, ConversationPhase.notEncrypted);
    });

    test('a device waiting for a welcome is in the known set after a '
        'restart', () async {
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 0),
        rigBytes('an init of another device'),
        fromUser: 'user-b',
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      final sync = (await rig.device.vault.conversation(_c1))!.sync;
      expect(sync.firstSawGeneration, 1);
      expect(
        sync.firstSawGenerationAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      expect([for (final n in rig.messaging.noted) n.id], [_c1]);

      await rig.restart();
      expect(rig.known.contains(_c1), isTrue);
      final again = KnownConversations(session: rig.device.session);
      await again.load(rig.device.vault);
      expect(again.contains(_c1), isTrue);
    });
  });

  group('attribution', () {
    setUp(() => setUpRig());

    test('attribution: own list match is mine with a deviceAdded row, peer '
        'list match is theirs, no match with readable lists is '
        'unknownDevice', () async {
      final sib = await RigPeer.create('sib');
      final carol = await RigPeer.create('carol');
      final eve = await RigPeer.create('eve');
      rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1);
      // The peer fetch counts from 60 s after this run knew it accepted.
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [sib, carol, eve]);

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await pin(_c1, sib.id))!.side, MemberSide.mine);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      final lines = await rig.lines(_c1);
      String? sideOf(String line, Uint8List id) => lines
          .singleWhere((l) => l.line == line && rigEq(l.deviceId!, id))
          .side;
      expect(lines, hasLength(3));
      expect(sideOf(SystemLine.deviceAdded, sib.id), MemberSide.mine);
      expect(sideOf(SystemLine.deviceAdded, carol.id), MemberSide.theirs);
      expect(
        lines.where(
          (l) =>
              l.line == SystemLine.unknownDevice && rigEq(l.deviceId!, eve.id),
        ),
        hasLength(1),
      );
      final state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isTrue);
      expect(state.sendBlock, SendBlock.unknownDevice);
      expect(state.unattributedPresent, isTrue);
      expect(state.myDeviceCount, 2);
      expect(state.theirDeviceCount, 2);

      // Once per device and pair: another pass adds no row.
      await rig.crypto.attributeMembers(_c1);
      expect(await rig.lines(_c1), hasLength(3));
    });

    test('an ordinary unknown device that is listed later is '
        'attributed', () async {
      final eve = await RigPeer.create('eve');
      final offer = await join(_c1);
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect(linesOf(await rig.lines(_c1), eve.id), [SystemLine.unknownDevice]);
      await expectRecorded(_c1, eve.id, eve.key);

      // The directory lists eve now (Task 9's recheck re-attributes).
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(eve.idString, eve.key));
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, eve.id))!.side, MemberSide.theirs);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        unorderedEquals([SystemLine.unknownDevice, SystemLine.deviceAdded]),
      );
      final state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isFalse);
      expect(state.unattributedPresent, isFalse);
    });

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

    Future<void> corruptHistory(String c) => rig.device.vault.transaction(
      (tx) => tx.putSetting('messages.e2ee.keys.$c', rigBytes('{"v":1')),
    );

    Future<String> rawHistory(String c) async =>
        utf8.decode((await rig.device.vault.setting('messages.e2ee.keys.$c'))!);

    test('a pin missing from the key history makes it unreadable and is never '
        'attributed', () async {
      final eve = await RigPeer.create('eve');
      final carol = await RigPeer.create('carol');
      rig.keys.peerFails = true;
      final offer = await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      final history = await rig.keyHistory(_c1);
      // A pin no writer admitted (a writer that forgot, or an edited file).
      await rig.device.vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: eve.id,
            signatureKey: eve.key,
            side: MemberSide.unattributed,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      rig.keys.peerFails = false;
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(eve.idString, eve.key),
        rigKeyDevice(carol.idString, carol.key),
      ];
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      // A later commit does not repair it either.
      await bobCommit(offer, _c1, add: [carol]);
      rig.device.engine.describeMembers = (real) => [
        ...real,
        GroupMember(deviceId: eve.id, signaturePublicKey: eve.key),
      ];
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      // The whole record is unreadable: nobody else is attributed either.
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      expect(await rig.lines(_c1), isEmpty);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
      expect(await rig.keyHistory(_c1), history);
    });

    test('at the cap a new device id stays unknown, the history closes, and '
        'recorded devices stay attributable', () async {
      final dave = await RigPeer.create('dave');
      final eve = await RigPeer.create('eve');
      final offer = await join(_c1, others: [dave]);
      expect((await pin(_c1, dave.id))!.side, MemberSide.unattributed);
      // The history is at its allowance: bob, dave and 254 ids long gone.
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key), (dave.id, dave.key)],
        fillers: 254,
      );
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(dave.idString, dave.key),
        rigKeyDevice(eve.idString, eve.key),
      ];
      rig.directory.clear();
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve]);

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      final history = (await rig.keyHistory(_c1))!;
      expect(history['closed'], isTrue);
      expect(history['allow'], 256);
      final ids = history['ids']! as Map<String, Object?>;
      expect(ids, hasLength(256));
      expect(ids.keys, isNot(contains(vaultDeviceIdHex(eve.id))));
      expect(history['changed'], isEmpty);
      // Not admitted, but remembered with the key it was first seen with.
      expect(history['held'], {
        vaultDeviceIdHex(eve.id): base64Encode(eve.key),
      });
      // Recorded devices keep working.
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect((await pin(_c1, dave.id))!.side, MemberSide.theirs);
      // The refused device shows as an unknown device and blocks sending.
      final eveLines = linesOf(await rig.lines(_c1), eve.id);
      expect(eveLines, [SystemLine.unknownDevice]);
      final state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isTrue);
      expect(state.sendBlock, SendBlock.unknownDevice);
      expect(state.keyHistoryClosed, isTrue);
      expect(state.mayAllowMoreDevices, isTrue);
      expect(rig.keyHistoryErrors, isEmpty);
    });

    test('a closed key history admits no new id after a later commit or '
        'join', () async {
      final eve = await RigPeer.create('eve');
      final frank = await RigPeer.create('frank');
      final offer = await join(_c1);
      await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], closed: true);
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(eve.idString, eve.key),
        rigKeyDevice(frank.idString, frank.key),
      ];
      rig.directory.clear();
      final closed = (await rig.keyHistory(_c1))!;
      final eveHeld = {vaultDeviceIdHex(eve.id): base64Encode(eve.key)};

      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      // Not admitted (`ids` is as it was), but remembered with its key.
      expect(await rig.keyHistory(_c1), {...closed, 'held': eveHeld});

      await rig.offer(
        _c1,
        bob,
        generation: 2,
        others: [await eve.keyPackage(), await frank.keyPackage()],
      );
      expect(await rig.crypto.processWelcomes(), [_c1]);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, frank.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect(await rig.keyHistory(_c1), {
        ...closed,
        'held': {
          ...eveHeld,
          vaultDeviceIdHex(frank.id): base64Encode(frank.key),
        },
      });
      expect([
        for (final l in await rig.lines(_c1))
          if (l.line == SystemLine.deviceAdded) l,
      ], isEmpty);
      expect(rig.keyHistoryErrors, isEmpty);
    });

    test('a key change of a held id at a join taints it', () async {
      final eve = await RigPeer.create('eve');
      final eveHex = vaultDeviceIdHex(eve.id);
      final k2 = Uint8List.fromList(List.filled(32, 7));
      final offer = await join(_c1);
      // At its allowance: bob and 255 ids long gone.
      await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], fillers: 255);
      rig.clock.advance(const Duration(seconds: 61));
      // eve is first seen on K1 while the history is full: held.
      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await rig.keyHistoryHeld(_c1), {eveHex: base64Encode(eve.key)});
      expect((await rig.keyHistory(_c1))!['closed'], isTrue);

      // A join whose tree has eve on K2; the directory lists K2.
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(eve.idString, k2),
      ];
      rig.directory.clear();
      await rig.offer(
        _c1,
        bob,
        generation: 2,
        others: [await eve.keyPackage()],
      );
      rig.device.engine.describeMembers = onKey(eve.id, k2);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      rig.device.engine.describeMembers = null;
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      // Tainted, no longer held, pinned unattributed on K2, never added.
      await expectTainted(_c1, eve.id);
      expect(await rig.keyHistoryHeld(_c1), isEmpty);
      final evePin = (await pin(_c1, eve.id))!;
      expect(evePin.side, MemberSide.unattributed);
      expect(rigEq(evePin.signatureKey, k2), isTrue);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);

      // Allowing new devices never makes it attributable.
      expect(await rig.crypto.allowNewDevices(_c1), isTrue);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
      await expectTainted(_c1, eve.id);
      expect(
        (await rig.crypto.describeState(_c1)).unknownDevicePresent,
        isTrue,
      );
    });

    test('allowing new devices clears closed, raises the allowance by 256, '
        'admits the overflow-refused pins and drops no id or taint', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final eve = await RigPeer.create('eve');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(dave.idString, dave.key));
      final offer = await join(_c1, others: [dave]);
      // At its allowance: bob, dave, a tainted id and 253 ids long gone.
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key), (dave.id, dave.key)],
        changed: [carol.id],
        fillers: 253,
      );
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(eve.idString, eve.key));
      rig.directory.clear();
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      final closed = (await rig.keyHistory(_c1))!;
      expect(closed['closed'], isTrue);
      expect(closed['held'], {vaultDeviceIdHex(eve.id): base64Encode(eve.key)});
      var state = await rig.crypto.describeState(_c1);
      expect(state.keyHistoryClosed, isTrue);
      expect(state.mayAllowMoreDevices, isTrue);
      rig.changed.clear();

      expect(await rig.crypto.allowNewDevices(_c1), isTrue);

      final open = (await rig.keyHistory(_c1))!;
      expect(open['closed'], isFalse);
      expect(open['allow'], 512);
      expect(open['held'], isEmpty);
      // Nothing dropped: every id with its key, the taint, plus eve.
      expect(open['changed'], [vaultDeviceIdHex(carol.id)]);
      expect(open['ids'], {
        ...closed['ids']! as Map<String, Object?>,
        vaultDeviceIdHex(eve.id): base64Encode(eve.key),
      });
      state = await rig.crypto.describeState(_c1);
      expect(state.keyHistoryClosed, isFalse);
      expect(state.mayAllowMoreDevices, isFalse);
      expect(rig.changed, [_c1]);
      // Admitted is not attributed: the lists decide, at the next pass.
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await pin(_c1, eve.id))!.side, MemberSide.theirs);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        unorderedEquals([SystemLine.unknownDevice, SystemLine.deviceAdded]),
      );
      // A tainted id stays refused on its key however wide the allowance.
      await bobCommit(offer, _c1, add: [carol]);
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      rig.directory.clear();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);

      // Not closed any more: a second call changes nothing.
      final before = await rig.keyHistory(_c1);
      expect(await rig.crypto.allowNewDevices(_c1), isFalse);
      expect(await rig.keyHistory(_c1), before);
      expect(rig.keyHistoryErrors, isEmpty);
    });

    test('a key change while the history is closed taints the id, and '
        'allowing new devices never admits it', () async {
      final eve = await RigPeer.create('eve');
      final frank = await RigPeer.create('frank');
      final eveHex = vaultDeviceIdHex(eve.id);
      final frankHex = vaultDeviceIdHex(frank.id);
      final offer = await join(_c1);
      // Really full: bob and 255 ids long gone.
      await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], fillers: 255);
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve, frank]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // Both are remembered with the key first seen, outside the allowance.
      expect(await rig.keyHistoryHeld(_c1), {
        eveHex: base64Encode(eve.key),
        frankHex: base64Encode(frank.key),
      });
      expect((await rig.keyHistory(_c1))!['closed'], isTrue);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);

      // A commit changes eve's key while the history is closed. The rig's
      // engine refuses an empty commit, so the commit that carries the
      // change removes a device added just before: it adds nobody.
      final newKey = Uint8List.fromList(List.filled(32, 9));
      final gone = await RigPeer.create('gone');
      await bobCommit(offer, _c1, add: [gone]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await bobCommit(offer, _c1, remove: [gone.id]);
      rig.device.engine.describeMembers = onKey(eve.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await expectTainted(_c1, eve.id);
      expect(await rig.keyHistoryHeld(_c1), {
        frankHex: base64Encode(frank.key),
        vaultDeviceIdHex(gone.id): base64Encode(gone.key),
      });
      // One entry over the allowance, and still readable.
      expect(await rig.keyHistoryIds(_c1), hasLength(256));
      expect((await rig.keyHistory(_c1))!['allow'], 256);

      // The user allows new devices; the directory lists eve's new key.
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(eve.idString, newKey),
        rigKeyDevice(frank.idString, frank.key),
      ];
      rig.directory.clear();
      expect(await rig.crypto.allowNewDevices(_c1), isTrue);
      final open = (await rig.keyHistory(_c1))!;
      expect(open['allow'], 512);
      expect(open['closed'], isFalse);
      expect(open['held'], isEmpty);
      expect(open['changed'], [eveHex]);
      final ids = open['ids']! as Map<String, Object?>;
      expect(ids.keys, isNot(contains(eveHex)));
      expect(ids[frankHex], base64Encode(frank.key));
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;

      final evePin = (await pin(_c1, eve.id))!;
      expect(evePin.side, MemberSide.unattributed);
      expect(rigEq(evePin.signatureKey, newKey), isTrue);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
      await expectTainted(_c1, eve.id);
      // The device held beside it, never changed, is attributed.
      expect((await pin(_c1, frank.id))!.side, MemberSide.theirs);
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
    });

    test('a removal and re-add on another key while closed taints the '
        'id', () async {
      final eve = await RigPeer.create('eve');
      final frank = await RigPeer.create('frank');
      final eveHex = vaultDeviceIdHex(eve.id);
      final offer = await join(_c1);
      await rig.putKeyHistory(_c1, ids: [(bob.id, bob.key)], fillers: 255);
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await rig.keyHistoryHeld(_c1), {eveHex: base64Encode(eve.key)});

      // Removed: the pin goes, what the history remembers does not.
      await bobCommit(offer, _c1, remove: [eve.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await pin(_c1, eve.id), isNull);
      expect(await rig.keyHistoryHeld(_c1), {eveHex: base64Encode(eve.key)});

      // Added again on another key, with a bystander.
      final newKey = Uint8List.fromList(List.filled(32, 6));
      await bobCommit(offer, _c1, add: [eve, frank]);
      rig.device.engine.describeMembers = onKey(eve.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await expectTainted(_c1, eve.id);
      expect(await rig.keyHistoryHeld(_c1), {
        vaultDeviceIdHex(frank.id): base64Encode(frank.key),
      });

      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(eve.idString, newKey),
        rigKeyDevice(frank.idString, frank.key),
      ];
      rig.directory.clear();
      expect(await rig.crypto.allowNewDevices(_c1), isTrue);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;

      final evePin = (await pin(_c1, eve.id))!;
      expect(evePin.side, MemberSide.unattributed);
      expect(rigEq(evePin.signatureKey, newKey), isTrue);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
      await expectTainted(_c1, eve.id);
      expect((await pin(_c1, frank.id))!.side, MemberSide.theirs);
    });

    test('the allowance stops at 1024', () async {
      const c2 = '22222222222222222222222222222222';
      const c3 = '33333333333333333333333333333333';
      await join(_c1);
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key)],
        closed: true,
        allow: 768,
      );
      expect(await rig.crypto.allowNewDevices(_c1), isTrue);
      expect((await rig.keyHistory(_c1))!['allow'], 1024);
      expect((await rig.keyHistory(_c1))!['closed'], isFalse);

      // Closed again at the maximum: no further exit.
      await rig.putKeyHistory(
        _c1,
        ids: [(bob.id, bob.key)],
        closed: true,
        allow: 1024,
      );
      final full = await rig.keyHistory(_c1);
      var state = await rig.crypto.describeState(_c1);
      expect(state.keyHistoryClosed, isTrue);
      expect(state.mayAllowMoreDevices, isFalse);
      expect(await rig.crypto.allowNewDevices(_c1), isFalse);
      expect(await rig.keyHistory(_c1), full);
      expect(rig.keyHistoryErrors, isEmpty);
      expect(rig.unexpected, isEmpty);

      // An unreadable history is never reopened or rewritten.
      await join(c2);
      await corruptHistory(c2);
      expect(await rig.crypto.allowNewDevices(c2), isFalse);
      expect(await rawHistory(c2), '{"v":1');
      state = await rig.crypto.describeState(c2);
      expect(state.keyHistoryClosed, isFalse);
      expect(state.mayAllowMoreDevices, isFalse);
      // A conversation with nothing stored gets no history from it.
      expect(await rig.crypto.allowNewDevices(c3), isFalse);
      expect(await rig.keyHistory(c3), isNull);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
    });

    test('a key history that fails to open is unreadable, and commits still '
        'apply', () async {
      final carol = await RigPeer.create('carol');
      rig.keys.peerFails = true;
      final offer = await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      // The stored bytes are replaced by bytes the vault cannot open.
      const key = 'messages.e2ee.keys.$_c1';
      final garbage = Uint8List.fromList(List.generate(64, (i) => i * 7 % 251));
      await rig.replaySealedSetting(key, garbage);

      rig.keys.peerFails = false;
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      await bobCommit(offer, _c1, add: [carol]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      // The commit was applied; nobody is attributed; nothing was rewritten.
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      expect(await rig.lines(_c1), isEmpty);
      expect(await rig.sealedSetting(key), garbage);
      final state = await rig.crypto.describeState(_c1);
      expect(state.keyHistoryClosed, isFalse);
      expect(state.mayAllowMoreDevices, isFalse);
      expect(await rig.crypto.allowNewDevices(_c1), isFalse);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
    });

    test('an unreadable key history refuses every unattributed member of that '
        'conversation and none of another', () async {
      const c2 = '22222222222222222222222222222222';
      rig.keys.peerFails = true;
      await join(_c1);
      await join(c2);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect((await pin(c2, bob.id))!.side, MemberSide.unattributed);
      await corruptHistory(_c1);

      rig.keys.peerFails = false;
      rig.clock.advance(const Duration(minutes: 3));
      for (final c in [_c1, c2, _c1, c2]) {
        await rig.crypto.attributeMembers(c);
      }

      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect((await pin(c2, bob.id))!.side, MemberSide.theirs);
      // No display row from a history that cannot be read.
      expect(await rig.lines(_c1), isEmpty);
      // Reported once for that conversation.
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
      expect(await rawHistory(_c1), '{"v":1');
      final state = await rig.crypto.describeState(_c1);
      expect(state.unattributedPresent, isTrue);
      expect(state.sendBlock, isNot(SendBlock.none));
    });

    test('an unreadable key history keeps sided pins at a join and is never '
        'overwritten by a key-changing commit, a join or '
        'attribution', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, others: [carol]);
      final bobBefore = (await pin(_c1, bob.id))!;
      expect(bobBefore.side, MemberSide.theirs);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      await corruptHistory(_c1);

      // A commit that changes carol's key and adds dave; all are listed.
      final newKey = Uint8List.fromList(List.filled(32, 9));
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, newKey),
        rigKeyDevice(dave.idString, dave.key),
      ];
      rig.directory.clear();
      await bobCommit(offer, _c1, add: [dave]);
      rig.device.engine.describeMembers = onKey(carol.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, dave.id))!.side, MemberSide.unattributed);

      // A join of generation 2 with all three: bob's sided pin is kept as
      // it was, the others stay unattributed.
      await rig.offer(
        _c1,
        bob,
        generation: 2,
        others: [await carol.keyPackage(), await dave.keyPackage()],
      );
      expect(await rig.crypto.processWelcomes(), [_c1]);
      rig.device.engine.describeMembers = null;
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      final bobAfter = (await pin(_c1, bob.id))!;
      expect(bobAfter.side, MemberSide.theirs);
      expect(bobAfter.since, bobBefore.since);
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, dave.id))!.side, MemberSide.unattributed);
      expect([
        for (final l in await rig.lines(_c1))
          if (l.line == SystemLine.deviceAdded ||
              l.line == SystemLine.unknownDevice)
            l,
      ], isEmpty);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
      // Never overwritten, by the commit, the join or attribution.
      expect(await rawHistory(_c1), '{"v":1');
    });

    test('a deleted key history with pins present refuses everyone and is not '
        'recreated', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      rig.keys.peerFails = true;
      final offer = await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      // The row is deleted from the vault file; the pins stay.
      await rig.deleteSettingRow('messages.e2ee.keys.$_c1');
      expect(await rig.keyHistory(_c1), isNull);

      rig.keys.peerFails = false;
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, carol.key),
        rigKeyDevice(dave.idString, dave.key),
      ];
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.offer(
        _c1,
        bob,
        generation: 2,
        others: [await carol.keyPackage(), await dave.keyPackage()],
      );
      expect(await rig.crypto.processWelcomes(), [_c1]);
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      for (final p in [bob, carol, dave]) {
        expect((await pin(_c1, p.id))!.side, MemberSide.unattributed);
        // No device row of any kind from a history that is not there.
        expect(linesOf(await rig.lines(_c1), p.id), isEmpty);
      }
      // Not recreated by attribution, the commit or the join.
      expect(await rig.keyHistory(_c1), isNull);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
    });

    test('an older sealed key history replayed over a newer one is '
        'unreadable', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final gone = await RigPeer.create('gone');
      final offer = await join(_c1, others: [carol]);
      expect((await pin(_c1, carol.id))!.side, MemberSide.theirs);
      const key = 'messages.e2ee.keys.$_c1';
      // The older value already records every device pinned later, so only
      // carol's key can contradict it.
      await bobCommit(offer, _c1, add: [dave, gone]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await expectRecorded(_c1, dave.id, dave.key);
      final old = (await rig.sealedSetting(key))!;

      // Carol is tainted by a commit that adds nobody; then the older
      // sealed value is put back.
      final newKey = Uint8List.fromList(List.filled(32, 4));
      await bobCommit(offer, _c1, remove: [gone.id]);
      rig.device.engine.describeMembers = onKey(carol.id, newKey);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.device.engine.describeMembers = null;
      await expectTainted(_c1, carol.id);
      await rig.replaySealedSetting(key, old);
      // It opens and decodes: the seal binds no counter.
      await expectRecorded(_c1, carol.id, carol.key);
      // Every other pin agrees with it: bob and dave on their keys.
      await expectRecorded(_c1, bob.id, bob.key);
      await expectRecorded(_c1, dave.id, dave.key);
      expect([
        for (final m in await rig.device.vault.members(_c1)) m.deviceId,
      ], hasLength(4));

      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, newKey),
        rigKeyDevice(dave.idString, dave.key),
      ];
      rig.directory.clear();
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);

      // Carol's current pin contradicts the replayed record.
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, dave.id))!.side, MemberSide.unattributed);
      expect(
        linesOf(await rig.lines(_c1), carol.id),
        isNot(contains(SystemLine.deviceAdded)),
      );
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
      expect(await rig.sealedSetting(key), old);
    });

    test('describeState never reports an unreadable key history', () async {
      rig.keys.peerFails = true;
      await join(_c1);
      await corruptHistory(_c1);

      // It reads the history without a lock, so it must not spend the one
      // report of this conversation.
      for (var i = 0; i < 2; i++) {
        final state = await rig.crypto.describeState(_c1);
        expect(state.keyHistoryClosed, isFalse);
        expect(state.mayAllowMoreDevices, isFalse);
      }
      expect(rig.keyHistoryErrors, isEmpty);
      expect(rig.unexpected, isEmpty);

      // A write body that meets it still reports it, once.
      rig.keys.peerFails = false;
      rig.clock.advance(const Duration(minutes: 3));
      await rig.crypto.attributeMembers(_c1);
      await rig.crypto.describeState(_c1);
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      unreadableHistories = 1;
    });

    test('an unmatched member seen 30 s after acceptance is pending, not '
        'unknown; the fetch at 60 s decides', () async {
      final frank = await RigPeer.create('frank');
      final offer = await join(_c1);
      rig.clock.advance(const Duration(seconds: 30));
      await bobCommit(offer, _c1, add: [frank]);

      // Right after acceptance the server lists active devices only.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await pin(_c1, frank.id))!.side, MemberSide.unattributed);
      expect(await rig.lines(_c1), isEmpty);
      var state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isFalse);
      expect(state.sendBlock, SendBlock.notSynced);

      // At 60 s the full registered list shows frank, inactive.
      rig.clock.advance(const Duration(seconds: 30));
      rig.keys.peers['ref-bob']!.add(
        rigKeyDevice(frank.idString, frank.key)..inactive = true,
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await pin(_c1, frank.id))!.side, MemberSide.theirs);
      final lines = await rig.lines(_c1);
      expect(lines, hasLength(1));
      expect(lines.single.line, SystemLine.deviceAdded);
      expect(lines.single.side, MemberSide.theirs);
      state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isFalse);
      expect(state.unattributedPresent, isFalse);
    });

    test('attribution with an unreadable list sets deviceListUnverifiable '
        'and writes no unknownDevice row', () async {
      final eve = await RigPeer.create('eve');
      final offer = await join(_c1);
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve]);
      rig.keys.peerFails = true;

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect(await rig.lines(_c1), isEmpty);
      final state = await rig.crypto.describeState(_c1);
      expect(state.deviceListUnverifiable, isTrue);
      expect(state.unknownDevicePresent, isFalse);
      expect(state.unattributedPresent, isTrue);
      expect(state.sendBlock, isNot(SendBlock.none));
    });

    group('deferred lists', () {
      late SyncBudget directoryBudget;

      Future<RigPeer> deferred() async {
        final eve = await RigPeer.create('eve');
        directoryBudget = SyncBudget(
          perMinute: 100000,
          ownDeviceCount: () => 1,
          now: rig.clock.now,
        );
        rig.directory = DeviceDirectory(
          keys: rig.keys,
          budget: directoryBudget,
          now: rig.clock.now,
        );
        rebuild();
        final offer = await join(_c1);
        rig.clock.advance(const Duration(seconds: 61));
        await bobCommit(offer, _c1, add: [eve]);
        // RATE_LIMITED for two hours.
        directoryBudget.pauseUntil(
          rig.clock.now().add(const Duration(hours: 2)),
        );
        return eve;
      }

      test('attribution with a deferred list writes nothing, keeps notSynced '
          'and shows no warning for up to 30 minutes', () async {
        final eve = await deferred();
        final keysCalls = rig.keys.getCalls.length;

        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        expect(rig.keys.getCalls.length, keysCalls);
        expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
        expect(await rig.lines(_c1), isEmpty);
        var state = await rig.crypto.describeState(_c1);
        expect(state.sendBlock, SendBlock.notSynced);
        expect(state.deviceListUnverifiable, isFalse);
        expect(state.unknownDevicePresent, isFalse);

        rig.clock.advance(const Duration(minutes: 29));
        await rig.crypto.attributeMembers(_c1);
        state = await rig.crypto.describeState(_c1);
        expect(state.sendBlock, SendBlock.notSynced);
        expect(state.deviceListUnverifiable, isFalse);
        expect(await rig.lines(_c1), isEmpty);
      });

      test('a deferral over 30 minutes with an unattributed member sets '
          'deviceListUnverifiable', () async {
        final eve = await deferred();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        rig.clock.advance(const Duration(minutes: 31));
        await rig.crypto.attributeMembers(_c1);

        final state = await rig.crypto.describeState(_c1);
        expect(state.deviceListUnverifiable, isTrue);
        expect(state.unknownDevicePresent, isFalse);
        expect(state.sendBlock, isNot(SendBlock.none));
        expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
        expect(await rig.lines(_c1), isEmpty);
      });
    });

    test('in an unaccepted conversation attribution writes no row and never '
        'reports an unknown device', () async {
      final sib = await RigPeer.create('sib');
      final eve = await RigPeer.create('eve');
      rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));
      final offer = await join(_c1, accepted: false);
      rig.clock.advance(const Duration(minutes: 5));
      await bobCommit(offer, _c1, add: [sib, eve]);

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await pin(_c1, sib.id))!.side, MemberSide.mine);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect(await rig.lines(_c1), isEmpty);
      final state = await rig.crypto.describeState(_c1);
      expect(state.unknownDevicePresent, isFalse);
      expect(state.requestAccepted, isFalse);
    });

    test('an unreadable list in an unaccepted conversation is retried and '
        'writes no row', () async {
      rig.keys.peerFails = true;
      await join(_c1, accepted: false);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect(rig.contexts.of(_c1).attributionPending, isTrue);

      rig.keys.peerFails = false;
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect(await rig.lines(_c1), isEmpty);
      expect(rig.contexts.of(_c1).attributionPending, isFalse);
    });

    test('syncedSinceStart is true only at the server pair with no '
        'attribution pending and one completed live pull of that '
        'pair', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      final context = rig.contexts.of(_c1);
      // At the server pair, attribution done, but no live pull yet.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(context.syncedSinceStart, isFalse);

      context.livePulledAt = const MlsPair(1, 1);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(context.syncedSinceStart, isTrue);

      // A new commit: the live pull was of the old pair.
      await bobCommit(offer, _c1, add: [carol]);
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(context.syncedSinceStart, isFalse);

      // The live pull of the new pair, but attribution is pending.
      context.livePulledAt = const MlsPair(1, 2);
      rig.keys.peerFails = true;
      final dave = await RigPeer.create('dave');
      await bobCommit(offer, _c1, add: [dave]);
      context.livePulledAt = const MlsPair(1, 3);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(context.attributionPending, isTrue);
      expect(context.syncedSinceStart, isFalse);

      rig.keys.peerFails = false;
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(dave.idString, dave.key));
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(context.attributionPending, isFalse);
      expect(context.syncedSinceStart, isTrue);
    });
  });

  group('the first-join baseline', () {
    setUp(() => setUpRig());

    /// The stored baseline pair of [c], read from the sealed setting.
    Future<MlsPair?> baselineOf(String c) async {
      final raw = await rig.device.vault.setting('messages.e2ee.baseline');
      if (raw == null) return null;
      final m = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
      expect(m['v'], 1);
      final pair = (m['byConv']! as Map<String, Object?>)[c] as List<Object?>?;
      return pair == null ? null : MlsPair(pair[0]! as int, pair[1]! as int);
    }

    test('a first join of an unaccepted request, a restart, then acceptance '
        'writes no peer deviceAdded row and no own alert on a brand-new '
        'vault', () async {
      final sib = await RigPeer.create('sib');
      // While the request is unaccepted the lookup finds nobody.
      rig.keys.peers['ref-bob'] = [];
      await join(_c1, accepted: false, others: [sib]);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect((await pin(_c1, sib.id))!.side, MemberSide.unattributed);
      expect(await rig.lines(_c1), isEmpty);

      await rig.restart();
      rig.crypto.sink = sink;
      await rig.accept(_c1);
      rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
      rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect((await pin(_c1, sib.id))!.side, MemberSide.mine);
      expect(await rig.lines(_c1), isEmpty);
    });

    test('the baseline entry is removed once every member of that join is '
        'attributed', () async {
      rig.keys.peerFails = true;
      await join(_c1);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);
      expect(await baselineOf(_c1), const MlsPair(1, 1));

      rig.keys.peerFails = false;
      await rig.crypto.attributeMembers(_c1);

      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect(await rig.lines(_c1), isEmpty);
      expect(await baselineOf(_c1), isNull);
    });

    test('a later join replaces the baseline', () async {
      rig.keys.peerFails = true;
      await join(_c1);
      expect(await baselineOf(_c1), const MlsPair(1, 1));

      final carol = await RigPeer.create('carol');
      await rig.offer(
        _c1,
        bob,
        generation: 2,
        others: [await carol.keyPackage()],
      );
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(await rig.device.vault.group(_c1, 2), isNotNull);
      expect(await baselineOf(_c1), isNull);

      // After a restart nothing of the later join is a baseline: carol, a
      // key never pinned before, gets her row.
      await rig.restart();
      rig.crypto.sink = sink;
      rig.keys.peerFails = false;
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      final carolLines = [
        for (final l in await rig.lines(_c1))
          if (rigEq(l.deviceId ?? const [], carol.id)) l,
      ];
      expect(carolLines, hasLength(1));
      expect(carolLines.single.line, SystemLine.deviceAdded);
      expect(carolLines.single.side, MemberSide.theirs);
    });
  });

  group('locked entry points', () {
    setUp(() => setUpRig());

    test('processWelcomesHeld, catchUpLocked and attributeMembersLocked work '
        'under a held lock', () async {
      await rig.accept(_c1);
      rig.header(_c1, 'ref-bob');
      rig.keys.peerFails = true;
      await rig.offer(_c1, bob);

      // No group yet: the welcome is joined, then catch-up runs.
      expect(
        await rig.locks.run(_c1, () => rig.crypto.processWelcomesHeld(_c1)),
        CatchUpResult.current,
      );
      expect(await rig.device.vault.group(_c1, 1), isNotNull);
      expect(rig.server.welcomesFor(rig.device.deviceIdString), isEmpty);
      expect((await pin(_c1, bob.id))!.side, MemberSide.unattributed);

      expect(
        await rig.locks.run(_c1, () => rig.crypto.catchUpLocked(_c1)),
        CatchUpResult.current,
      );

      rig.keys.peerFails = false;
      await rig.locks.run(_c1, () => rig.crypto.attributeMembersLocked(_c1));
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
    });

    test('an unheld call of a locked entry point trips the assert', () async {
      expect(() => rig.crypto.catchUpLocked(_c1), throwsAssertionError);
      expect(() => rig.crypto.processWelcomesHeld(_c1), throwsAssertionError);
      expect(
        () => rig.crypto.attributeMembersLocked(_c1),
        throwsAssertionError,
      );
      // Holding another conversation's lock is not holding this one.
      const c2 = '22222222222222222222222222222222';
      await rig.locks.run(c2, () async {
        expect(() => rig.crypto.catchUpLocked(_c1), throwsAssertionError);
      });
    });
  });

  group('stuck and interrupted', () {
    setUp(() => setUpRig());

    test('a gap, bad_input at the needed pair, an own-leaf commit without '
        'from_self and a from_self own-leaf commit without a pending record '
        'are each stuck and store nothing', () async {
      final carol = await RigPeer.create('carol');
      final dave = await RigPeer.create('dave');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      await bobCommit(offer, _c1, add: [dave]);
      final before = await rig.dump();

      Future<void> stuck(String why) async {
        rig.server.calls.clear();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck, reason: why);
        expect(await rig.dump(), before, reason: why);
        // Stuck within the generation: no welcome poll, no ack.
        expect(rig.server.calls.toSet(), {
          'listConversationCommits',
        }, reason: why);
        expect(
          (await rig.crypto.describeState(_c1)).sendBlock,
          SendBlock.stuck,
          reason: why,
        );
      }

      // 1. A gap: the commit at (1, 1) is not returned.
      rig.server.rewriteCommits = (real) {
        if (real.commits.isNotEmpty &&
            real.commits.first.mlsEpoch.toInt() == 1) {
          real.commits.removeAt(0);
        }
        return real;
      };
      await stuck('gap');
      rig.server.rewriteCommits = null;

      // 2. bad_input for the commit at the needed pair.
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.badInput,
        'rig',
      );
      await stuck('bad_input');

      // 3. own_leaf for a commit not marked from_self (a forgery).
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.ownLeaf,
        'rig',
      );
      await stuck('own_leaf without from_self');

      // The rig's commits are applied once nothing fails.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(
        (await rig.crypto.describeState(_c1)).sendBlock,
        isNot(SendBlock.stuck),
      );

      // 4. A from_self own-leaf commit without a pending record: this
      // device built a commit and lost its pending record (R7).
      const c2 = '22222222222222222222222222222222';
      await join(c2);
      final v = rig.device.vault;
      final lost = await rig.device.engine.inner.commitChange(
        (await v.deviceState())!,
        (await v.group(c2, 1))!.state,
        addKeyPackages: [await (await RigPeer.create('erin')).keyPackage()],
      );
      rig.server.addCommit(
        c2,
        const MlsPair(1, 1),
        lost.commit,
        fromUser: 'user-a',
      );
      final before2 = await rig.dump();
      rig.device.engine.calls.clear();
      expect(await rig.crypto.catchUp(c2), CatchUpResult.stuck);
      expect(await rig.dump(), before2);
      expect(rig.device.engine.calls, contains('process'));
      expect(rig.device.engine.calls, isNot(contains('confirmCommit')));
      expect((await rig.crypto.describeState(c2)).sendBlock, SendBlock.stuck);
    });

    test(
      'a remembered stuck answer comes before a provisional group',
      () async {
        final v = rig.device.vault;
        await v.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 1,
              epoch: 1,
              state: rigBytes('a provisional state'),
              provisional: true,
              provisionalCreatedAtMicros: rig.clock
                  .now()
                  .microsecondsSinceEpoch,
              pending: PendingCommit(
                kind: PendingKind.init,
                builtOn: const MlsPair(1, 0),
                commit: rigBytes('this device init'),
              ),
            ),
          ),
        );
        // The transaction that stored the provisional group wrote the key
        // history too (empty: no pin is seeded here).
        await rig.putKeyHistory(_c1);
        rig.contexts.of(_c1).stuck = true;

        final state = await rig.crypto.describeState(_c1);

        expect(state.phase, ConversationPhase.stuck);
        expect(state.sendBlock, SendBlock.stuck);
      },
    );

    test('a deadline during process is interrupted, not stuck', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      final before = await rig.dump();
      for (final code in [
        MlsErrorCode.deadline,
        MlsErrorCode.unavailable,
        MlsErrorCode.internal,
      ]) {
        rig.device.engine.failNext['process'] = MlsException(code, 'rig');
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
        expect(await rig.dump(), before);
        expect(
          (await rig.crypto.describeState(_c1)).phase,
          isNot(ConversationPhase.stuck),
        );
      }
      // Nothing was skipped: the commit is applied on the next pass.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
    });

    test('a commit result arriving after its deadline is not stored', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      final guarded = GuardedCryptoEngine(
        create: () => rig.device.engine,
        deadline: const Duration(seconds: 30),
      );
      rebuild(engine: () => guarded);
      final late = Completer<void>();
      rig.device.engine.holdNextProcess = late.future;
      final before = await rig.dump();

      // Fake time: the engine's deadline passes while process is held.
      final clock = FakeAsync();
      CatchUpResult? result;
      clock.run((_) {
        rig.crypto.catchUp(_c1).then((r) => result = r);
      });
      for (var i = 0; i < 1000; i++) {
        if (rig.device.engine.calls.contains('process')) break;
        clock.elapse(Duration.zero);
      }
      expect(rig.device.engine.calls, contains('process'));
      clock.elapse(const Duration(seconds: 31));
      expect(result, CatchUpResult.interrupted);
      // The result arrives late.
      late.complete();
      clock
        ..flushMicrotasks()
        ..flushTimers();

      expect(await rig.dump(), before);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 1);
      // The next pass applies it.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
    });
  });

  group('generations', () {
    setUp(() => setUpRig());

    test('selfRemoved deletes the group and pins, keeps the pins as former '
        'pins, and waits', () async {
      final offer = await join(_c1);
      await bobCommit(offer, _c1, remove: [rig.device.deviceId]);

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);

      final v = rig.device.vault;
      expect(await v.groups(_c1), isEmpty);
      expect(await v.members(_c1), isEmpty);
      final former = await const FormerPins().of(v, _c1);
      expect(former, hasLength(2));
      expect(
        former.singleWhere((m) => rigEq(m.deviceId, bob.id)).side,
        MemberSide.theirs,
      );
      final record = (await v.conversation(_c1))!;
      expect(record.sync.firstSawGeneration, 1);
      expect(
        record.sync.firstSawGenerationAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      expect(record.afterPair, const MlsPair(1, 1));
      expect(
        (await rig.crypto.describeState(_c1)).phase,
        ConversationPhase.waitingForWelcome,
      );
    });

    test("a lower generation's group is deleted only after its last epoch's "
        'messages were completed', () async {
      const c2 = '22222222222222222222222222222222';
      // 1. A welcome of generation 2 met by an ordinary poll before any
      // catch-up walked generation 1 to its end: generation 1 is walked
      // first (its last epoch completed), then generation 2 is joined in
      // place, which deletes generation 1. Acknowledged once.
      await join(_c1);
      final reset = await rig.offer(_c1, bob, generation: 2);
      sink.calls.clear();
      rig.server.acks.clear();
      expect(await rig.crypto.processWelcomes(), [_c1]);
      final v = rig.device.vault;
      expect(sink.calls, ['complete 1:1 at 1']);
      expect(await v.group(_c1, 1), isNull);
      expect((await v.group(_c1, 2))!.epoch, 1);
      expect([for (final a in rig.server.acks) ...a.ids], [reset.welcomeId]);
      // The new generation's pins are the ones its join wrote: nothing of
      // generation 1's walk landed on them.
      final pins = await v.members(_c1);
      expect(pins, hasLength(2));
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
      expect((await pin(_c1, rig.device.deviceId))!.side, MemberSide.mine);
      expect(await rig.lines(_c1), hasLength(1)); // the encryptionReset row

      // 2. Catch-up meets the reset first: it completes generation 1's last
      // epoch, then joins generation 2, which deletes generation 1.
      await join(c2);
      await rig.offer(c2, bob, generation: 2);
      sink.calls.clear();
      expect(await rig.crypto.catchUp(c2), CatchUpResult.current);
      expect(sink.calls, ['complete 1:1 at 1']);
      expect(await v.group(c2, 2), isNotNull);
      expect(await v.group(c2, 1), isNull);
    });

    test('a welcome for a later generation first walks one commit still to '
        'apply in the old one', () async {
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      final reset = await rig.offer(_c1, bob, generation: 2);
      rig.device.engine.calls.clear();
      sink.calls.clear();
      rig.server.acks.clear();

      expect(await rig.crypto.processWelcomes(), [_c1]);

      // (1, 1) was applied, generation 1's last epoch completed, then the
      // welcome of 2 joined.
      expect(count(rig.device.engine.calls, 'process'), 1);
      expect(count(rig.device.engine.calls, 'joinFromWelcome'), 1);
      expect(sink.calls, ['complete 1:1 at 1', 'complete 1:2 at 2']);
      final v = rig.device.vault;
      expect(await v.group(_c1, 1), isNull);
      expect((await v.group(_c1, 2))!.epoch, 1);
      expect((await v.conversation(_c1))!.afterPair, const MlsPair(2, 0));
      expect([for (final a in rig.server.acks) ...a.ids], [reset.welcomeId]);
    });

    test('a welcome joined by the generation switch never starts another '
        'walk, even with a lower generation still unwalked', () async {
      await join(_c1);
      final v = rig.device.vault;
      // A second final group beside generation 1 (as an own init settled
      // there would leave it); neither generation is walked.
      final g1 = (await v.group(_c1, 1))!;
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      await rig.offer(_c1, bob, generation: 3);

      expect(
        await rig.crypto.processWelcomes().timeout(const Duration(seconds: 10)),
        [_c1],
      );
      expect(await v.group(_c1, 3), isNotNull);
      expect(await v.group(_c1, 2), isNull);
      expect(await v.group(_c1, 1), isNull);
    });

    test('a lower generation left behind by a switch is marked undecryptable '
        'and deleted at the join', () async {
      await join(_c1);
      final v = rig.device.vault;
      // Generation 2 stored beside generation 1, which catch-up never walks
      // (it walks the highest only).
      final g1 = (await v.group(_c1, 1))!;
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 1,
            state: g1.state,
          ),
        ),
      );
      await rig.offer(_c1, bob, generation: 3);
      sink.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(sink.calls, contains('undecryptable 1:1'));
      expect(sink.calls, isNot(contains('complete 1:1 at 1')));
      expect(await v.group(_c1, 3), isNotNull);
      expect(await v.group(_c1, 2), isNull);
      expect(await v.group(_c1, 1), isNull);
      expect((await v.conversation(_c1))!.sync.completedEpochs, isEmpty);

      // A later ordinary welcome starts no extra catch-up.
      rig.device.engine.calls.clear();
      sink.calls.clear();
      await rig.offer(_c1, bob, generation: 4);
      expect(await rig.crypto.processWelcomes(), [_c1]);
      expect(sink.calls, ['complete 3:1 at 1']);
      expect(await v.groups(_c1), hasLength(1));
    });

    test('a reset seen from generation 1: remaining commits of 1 applied, '
        'epoch-0 record never applied, welcome of 2 joined, one '
        'encryptionReset row', () async {
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      final reset = await rig.offer(_c1, bob, generation: 2);
      rig.device.engine.calls.clear();
      sink.calls.clear();
      rig.server.acks.clear();
      rig.server.listedFor.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      // The welcome was listed for this device and acknowledged once.
      expect(rig.server.listedFor, isNotEmpty);
      expect(rig.server.listedFor.toSet(), {rig.device.deviceIdString});
      expect(rig.server.acks, hasLength(1));
      expect(rig.server.acks.single.deviceId, rig.device.deviceIdString);
      expect(rig.server.acks.single.ids, [reset.welcomeId]);

      // Only generation 1's (1, 1) commit was processed.
      expect(count(rig.device.engine.calls, 'process'), 1);
      expect(count(rig.device.engine.calls, 'joinFromWelcome'), 1);
      expect(sink.calls, ['complete 1:1 at 1', 'complete 1:2 at 2']);
      final v = rig.device.vault;
      expect(await v.group(_c1, 1), isNull);
      expect((await v.group(_c1, 2))!.epoch, 1);
      expect((await v.conversation(_c1))!.afterPair, const MlsPair(2, 0));
      final resets = [
        for (final l in await rig.lines(_c1))
          if (l.line == SystemLine.encryptionReset) l,
      ];
      expect(resets, hasLength(1));
      // carol is not in generation 2: her pin goes without a line.
      expect(await pin(_c1, carol.id), isNull);
      expect(
        (await rig.lines(_c1)).where((l) => l.line == SystemLine.deviceRemoved),
        isEmpty,
      );
      expect((await pin(_c1, bob.id))!.side, MemberSide.theirs);
    });

    test('two resets in one day leave two encryptionReset rows, and '
        're-processing a join adds none', () async {
      await join(_c1);
      await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      final third = await rig.offer(_c1, bob, generation: 3);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      Future<int> resets() async =>
          (await rig.lines(_c1))
              .where((l) => l.line == SystemLine.encryptionReset)
              .length;
      expect(await resets(), 2);

      // The server hands out generation 3's welcome again.
      rig.server.addWelcome(
        rig.device.deviceIdString,
        _c1,
        third.label,
        third.add.welcome,
      );
      await rig.crypto.processWelcomes();
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await resets(), 2);
    });

    test('a stuck generation is not reset: its epoch is marked undecryptable '
        'and the new generation is joined', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      await rig.offer(_c1, bob, generation: 2);
      rig.device.engine.failNext['process'] = const MlsException(
        MlsErrorCode.badInput,
        'rig',
      );
      sink.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      // The epoch's messages were walked before the commit was tried; the
      // commit was unusable, so the epoch is also marked (brief step 6).
      expect(sink.calls, ['complete 1:1 at 1', 'undecryptable 1:1']);
      expect(await rig.device.vault.group(_c1, 1), isNull);
      expect(await rig.device.vault.group(_c1, 2), isNotNull);
      expect(
        (await rig.crypto.describeState(_c1)).phase,
        ConversationPhase.ready,
      );
    });

    test('a same-generation re-add joined before catch-up writes no '
        'encryptionReset row', () async {
      await join(_c1);
      final second = await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      Future<int> resets() async =>
          (await rig.lines(_c1))
              .where((l) => l.line == SystemLine.encryptionReset)
              .length;
      expect(await resets(), 1);

      // Bob removes this device at (2, 1) and adds it back at (2, 2); the
      // welcome poll runs before any catch-up.
      await bobCommit(second, _c1, remove: [rig.device.deviceId]);
      final at = rig.server.current(_c1);
      final readd = await rigCommit(
        second.add.group,
        add: [await rigKeyPackage(rig.device)],
      );
      rig.server.addCommit(_c1, at, readd.commit, fromUser: 'user-b');
      rig.server.addWelcome(rig.device.deviceIdString, _c1, at, readd.welcome);
      expect(await rig.crypto.processWelcomes(), [_c1]);

      expect((await rig.device.vault.group(_c1, 2))!.epoch, 3);
      expect(await resets(), 1);
    });

    test('no system row of any kind is written in an unaccepted '
        'conversation', () async {
      final carol = await RigPeer.create('carol');
      final eve = await RigPeer.create('eve');
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(carol.idString, carol.key));
      final offer = await join(_c1, accepted: false, others: [carol]);
      rig.clock.advance(const Duration(minutes: 5));
      await bobCommit(offer, _c1, remove: [carol.id]);
      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.device.vault.group(_c1, 2), isNotNull);
      expect(await rig.lines(_c1), isEmpty);
    });

    test('no welcome for the new generation: waitingForWelcome and the '
        'first-saw time is recorded once and never moved', () async {
      await join(_c1);
      rig.server.addCommit(
        _c1,
        const MlsPair(2, 0),
        rigBytes('a reset of another device'),
        fromUser: 'user-b',
      );
      final first = rig.clock.now();
      rig.device.engine.calls.clear();
      rig.server.calls.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      expect(rig.device.engine.calls, isNot(contains('process')));
      // Welcomes were polled; nothing was acknowledged.
      expect(rig.server.calls, contains('listWelcomes'));
      expect(rig.server.calls, isNot(contains('ackWelcomes')));
      rig.clock.advance(const Duration(hours: 1));
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);

      final v = rig.device.vault;
      final sync = (await v.conversation(_c1))!.sync;
      expect(sync.firstSawGeneration, 2);
      expect(sync.firstSawGenerationAtMicros, first.microsecondsSinceEpoch);
      // Generation 1's last epoch, walked to its end, and nothing else.
      expect(sync.completedEpochs, const [MlsPair(1, 1)]);
      // The old generation's group is kept until a newer one is stored.
      expect(await v.group(_c1, 1), isNotNull);
      final state = await rig.crypto.describeState(_c1);
      expect(state.phase, ConversationPhase.waitingForWelcome);
      expect(state.sendBlock, SendBlock.waitingForWelcome);
      expect(state.resetAllowedAt, first.add(const Duration(hours: 24)));
    });

    test('a welcome joined during catch-up of the same conversation, and a '
        'catch-up started by a join, finish without taking the lock '
        'twice', () async {
      // A catch-up started by a join (the join holds the lock).
      final offer = await join(_c1).timeout(const Duration(seconds: 10));
      expect(rig.server.calls, contains('listConversationCommits'));
      expect(rig.contexts.of(_c1).attributionPending, isFalse);

      // A welcome joined during catch-up (the catch-up holds the lock).
      final carol = await RigPeer.create('carol');
      await bobCommit(offer, _c1, add: [carol]);
      await rig.offer(_c1, bob, generation: 2);
      expect(
        await rig.crypto.catchUp(_c1).timeout(const Duration(seconds: 10)),
        CatchUpResult.current,
      );
      expect(await rig.device.vault.group(_c1, 2), isNotNull);
      // The lock is free again.
      expect(
        await rig.crypto.catchUp(_c1).timeout(const Duration(seconds: 10)),
        CatchUpResult.current,
      );
    });
  });

  group('failing transactions', () {
    setUp(() => setUpRig());

    /// Unloads the known set the first time `describe` runs inside an
    /// applied commit's write body: the known-set write, last in that
    /// transaction after the group, pins and marks, then fails and the whole
    /// transaction must roll back (the join test's trick). Returns how often
    /// it fired.
    int Function() failNextApply() {
      var fired = 0;
      rig.device.engine.describeMembers = (real) {
        fired++;
        rig.known.clear();
        return real;
      };
      return () => fired;
    }

    test('a failing transaction while applying a commit stores '
        'nothing', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      final before = await rig.dump();
      final fired = failNextApply();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      rig.device.engine.describeMembers = null;

      expect(fired(), greaterThan(0));
      expect(await rig.dump(), before);
      expect(await pin(_c1, carol.id), isNull);

      // A retry applies it.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect((await pin(_c1, carol.id))!.side, MemberSide.unattributed);
      expect(rig.unexpected, isEmpty);
    });

    test("a failing transaction while applying this device's removal stores "
        'nothing', () async {
      final offer = await join(_c1);
      await bobCommit(offer, _c1, remove: [rig.device.deviceId]);
      final before = await rig.dump();
      final fired = failNextApply();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.interrupted);
      rig.device.engine.describeMembers = null;

      expect(fired(), 1);
      expect(await rig.dump(), before);

      // A retry applies it.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.waitingForWelcome);
      final v = rig.device.vault;
      expect(await v.groups(_c1), isEmpty);
      expect(await v.members(_c1), isEmpty);
      expect(await const FormerPins().of(v, _c1), hasLength(2));
      expect(rig.unexpected, isEmpty);
    });

    test('a failing transaction during attribution stores nothing', () async {
      // The peer lookup runs after the attribution started (the known set
      // loaded) and before its write body: unloading the known set there
      // makes the transaction's known-set write, after the pins and rows,
      // fail.
      final keys = _HookKeys(rig.keys);
      rig.directory = DeviceDirectory(
        keys: keys,
        budget: SyncBudget(
          perMinute: 100000,
          ownDeviceCount: () => 1,
          now: rig.clock.now,
        ),
        now: rig.clock.now,
      );
      rebuild();
      final eve = await RigPeer.create('eve');
      final offer = await join(_c1);
      rig.clock.advance(const Duration(seconds: 61));
      await bobCommit(offer, _c1, add: [eve]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);
      expect(linesOf(await rig.lines(_c1), eve.id), [SystemLine.unknownDevice]);
      // The directory lists eve now: attribution pins her theirs.
      rig.keys.peers['ref-bob']!.add(rigKeyDevice(eve.idString, eve.key));
      rig.clock.advance(const Duration(minutes: 3));
      final before = await rig.dump();
      var fired = 0;
      keys.beforePeer = () {
        fired++;
        rig.known.clear();
      };

      await rig.crypto.attributeMembers(_c1);
      keys.beforePeer = null;

      expect(fired, 1);
      expect(await rig.dump(), before);
      expect((await pin(_c1, eve.id))!.side, MemberSide.unattributed);

      // A retry attributes her.
      await rig.crypto.attributeMembers(_c1);
      expect((await pin(_c1, eve.id))!.side, MemberSide.theirs);
      expect(
        linesOf(await rig.lines(_c1), eve.id),
        unorderedEquals([SystemLine.unknownDevice, SystemLine.deviceAdded]),
      );
      expect(
        (await rig.crypto.describeState(_c1)).unknownDevicePresent,
        isFalse,
      );
      expect(rig.unexpected, isEmpty);
    });
  });

  group('paging and budgets', () {
    late _Recording recording;

    setUp(
      () => setUpRig(messaging: (server) => recording = _Recording(server)),
    );

    test('more is followed from the last returned commit', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      // 52 commits: one full page of 50, then 2.
      for (var i = 0; i < 26; i++) {
        await bobCommit(offer, _c1, add: [carol]);
        await bobCommit(offer, _c1, remove: [carol.id]);
      }
      recording.afters.clear();

      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(recording.afters, const [MlsPair(1, 0), MlsPair(1, 50)]);
      expect((await rig.device.vault.group(_c1, 1))!.epoch, 53);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(1, 52),
      );
    });

    test('a server that always has another commit page ends a catch-up pass '
        'after the page cap and resumes next time', () async {
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      // 24 real commits, built on (1, 1) to (1, 24).
      for (var i = 0; i < 12; i++) {
        await bobCommit(offer, _c1, add: [carol]);
        await bobCommit(offer, _c1, remove: [carol.id]);
      }
      // One commit a page, and always "more" (a page past the last commit
      // is empty, which ends a pass on its own).
      rig.server.rewriteCommits = (real) => pb.ListConversationCommitsResponse(
        commits: real.commits.take(1),
        more: true,
        mlsGeneration: real.mlsGeneration,
        mlsEpoch: real.mlsEpoch,
      );
      recording.afters.clear();
      final v = rig.device.vault;

      expect(
        await rig.crypto.catchUp(_c1).timeout(const Duration(seconds: 30)),
        CatchUpResult.interrupted,
      );
      // 20 pages (the cap): the commits on (1, 1) to (1, 20) are applied
      // and stored, nothing past them.
      expect(recording.afters, [for (var e = 0; e < 20; e++) MlsPair(1, e)]);
      expect((await v.group(_c1, 1))!.epoch, 21);
      expect((await v.conversation(_c1))!.afterPair, const MlsPair(1, 20));

      recording.afters.clear();
      expect(
        await rig.crypto.catchUp(_c1).timeout(const Duration(seconds: 30)),
        CatchUpResult.current,
      );
      // The next pass goes on from the stored after-pair and applies the
      // rest.
      expect(recording.afters, [for (var e = 20; e < 25; e++) MlsPair(1, e)]);
      expect((await v.group(_c1, 1))!.epoch, 25);
      expect((await v.conversation(_c1))!.afterPair, const MlsPair(1, 24));
      expect(await pin(_c1, carol.id), isNull);
      expect(rig.unexpected, isEmpty);
    });

    test('every sync RPC takes one budget unit', () async {
      final budget = _CountingBudget(rig.clock.now);
      rig.syncBudget = budget;
      rebuild();
      final carol = await RigPeer.create('carol');
      final offer = await join(_c1);
      await bobCommit(offer, _c1, add: [carol]);
      await rig.offer(_c1, bob, generation: 2);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      // listWelcomes, ackWelcomes, listConversationCommits, listMlsMessages.
      expect(rig.server.calls, isNotEmpty);
      expect(budget.taken, rig.server.calls.length);
    });
  });
}
