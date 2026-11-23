import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2ee_pipeline_rig.dart';

// The shared state and helpers of the removal-queue tests (Task 11), split
// over more than one test file. Each test file runs in its own isolate, so
// this top-level state belongs to one file's tests. Register
// [removalQueueTearDown] with `tearDown` in each file.

const String _c1 = '11111111111111111111111111111111';

late RigCrypto rig;
late RigPeer bob;
late RemovalQueueRunner runner;
late SpyBudget budget;
final List<RigScheduled> runnerScheduled = [];
final Map<String, RigOffer> offers = {};

/// Pipeline errors the running test expects (checked by the tearDown).
var expectedErrors = <String>[];

RemovalQueueRunner build() => RemovalQueueRunner(
  keys: rig.keys,
  directory: rig.directory,
  commits: rig.commits,
  upkeep: rig.upkeep,
  receiver: rig.receiver,
  crypto: rig.crypto,
  session: rig.device.session,
  engine: () => rig.device.engine,
  locks: rig.locks,
  contexts: rig.contexts,
  now: rig.clock.now,
  removedElsewhere: () => rig.removedElsewhere,
  schedule: (delay, run) {
    final entry = RigScheduled(delay, run);
    runnerScheduled.add(entry);
    return entry.cancel;
  },
  onUnexpectedError: (e, _) => rig.unexpected.add(e),
);

/// A rig whose key directory lists bob (and [peerListed]) for bob and
/// [ownListed] for the own user.
Future<void> setUpRig({
  List<RigPeer> ownListed = const [],
  List<RigPeer> peerListed = const [],
}) async {
  runnerScheduled.clear();
  offers.clear();
  rig = await RigCrypto.create(
    syncBudget: (clock) => budget = SpyBudget(clock),
  );
  bob = await RigPeer.create('bob');
  rig.keys.peers['ref-bob'] = [
    for (final p in [bob, ...peerListed]) rigKeyDevice(p.idString, p.key),
  ];
  rig.keys.own.addAll([
    for (final p in ownListed) rigKeyDevice(p.idString, p.key),
  ]);
  runner = build();
}

Future<void> removalQueueTearDown() async {
  await runner.idle();
  await rig.upkeep.idle();
  final unexpected = [
    for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
  ];
  final expected = expectedErrors;
  expectedErrors = [];
  await rig.dispose();
  expect(unexpected, expected, reason: 'unexpected pipeline errors');
}

pb.Conversation headerRow(
  String c, {
  Folder folder = Folder.FOLDER_INBOX,
  ConversationState state = ConversationState.CONVERSATION_STATE_ACCEPTED,
  bool canReply = true,
}) => pb.Conversation(
  id: c,
  peer: common.AuthorSnapshot(userId: 'ref-bob'),
  folder: folder,
  state: state,
  canReply: canReply,
);

/// This device joins [c] from bob's welcome with [others] in the group.
Future<void> join(
  String c, {
  List<RigPeer> others = const [],
  bool accepted = true,
}) async {
  if (accepted) await rig.accept(c);
  rig.server.rows[c] = accepted
      ? headerRow(c)
      : headerRow(
          c,
          folder: Folder.FOLDER_REQUESTS,
          state: ConversationState.CONVERSATION_STATE_REQUEST,
        );
  offers[c] = await rig.offer(
    c,
    bob,
    others: [for (final o in others) await o.keyPackage()],
  );
  expect(await rig.crypto.processWelcomes(), contains(c));
}

/// Commits applied, members attributed and one live pull of [c].
Future<void> synced([String c = _c1]) async {
  expect(await rig.crypto.catchUp(c), CatchUpResult.current);
  await rig.receiver.pullLive(c);
  expect(rig.contexts.of(c).syncedSinceStart, isTrue);
}

/// Bob commits [remove] on the server's current pair of [c].
Future<void> bobRemoves(String c, List<Uint8List> remove) async {
  final at = rig.server.current(c);
  final commit = await rigCommit(offers[c]!.add.group, remove: remove);
  rig.server.addCommit(c, at, commit.commit, fromUser: 'user-b');
}

/// A conversation [c] with a stored group (opaque state) whose sync
/// record says [accepted], with [mine] pinned as own devices and, when
/// given, one message created at [newestAtMicros].
Future<void> stateOnly(
  String c, {
  required bool accepted,
  List<RigPeer> mine = const [],
  int? newestAtMicros,
}) => rig.device.vault.transaction((tx) async {
  await tx.putConversationSync(c, ConversationSync(requestAccepted: accepted));
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
  if (newestAtMicros != null) {
    await tx.putMessage(
      StoredMessage(
        conversationId: c,
        messageId: 'm-$c',
        createdAtMicros: newestAtMicros,
        mine: false,
        state: StoredMessageState.visible,
        generation: 1,
        epoch: 1,
        content: Uint8List.fromList([1]),
      ),
    );
  }
});

Future<MemberRecord?> pin(RigPeer p, [String c = _c1]) async {
  for (final m in await rig.device.vault.members(c)) {
    if (rigEq(m.deviceId, p.id)) return m;
  }
  return null;
}

Future<ConversationSync> sync([String c = _c1]) async =>
    (await rig.device.vault.conversation(c))?.sync ?? const ConversationSync();

Future<void> updateSync(
  ConversationSync Function(ConversationSync s) change, [
  String c = _c1,
]) async {
  final next = change(await sync(c));
  await rig.device.vault.transaction((tx) => tx.putConversationSync(c, next));
}

/// The queue as stored in the vault (opened); null when absent.
Future<RemovalQueue?> stored() async {
  final raw = await rig.device.vault.setting(kVaultSettingRemovalQueue);
  return raw == null ? null : RemovalQueue.decode(raw);
}

List<RigCommitCall> requests([String? c]) => [
  for (final r in rig.server.commitRequests)
    if (c == null || r.conversationId == c) r,
];

Future<void> removeAndSettle(RigPeer p) async {
  await runner.removeDevice(p.idString);
  await runner.idle();
}

/// Runs the one timer the runner armed, as the timer would.
Future<void> runTimer() async {
  final live = [
    for (final e in runnerScheduled)
      if (!e.cancelled) e,
  ];
  expect(live, hasLength(1), reason: 'one queue timer');
  runnerScheduled.clear();
  live.single.run();
  await runner.idle();
}

bool queued(String c, RigPeer p) =>
    runner.queuedFor(c).any((d) => rigEq(d, p.id));

/// A sync budget that records the priority of every unit taken.
class SpyBudget extends SyncBudget {
  SpyBudget(RigClock clock)
    : super(perMinute: 100000, ownDeviceCount: () => 1, now: clock.now);

  final List<BudgetPriority> taken = [];

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    taken.add(priority);
    return super.take(priority, lane: lane);
  }
}
