// The shared harness of the reset tests (Task 10): `group_starter_reset_test`
// and `group_starter_reset_resume_test` (review m-7, a pure move of what was
// `main`'s scope in the first). One test file runs per isolate, so its state
// is top level; each file calls [registerResetHarness] first in `main`.
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:flutter_test/flutter_test.dart';

import 'e2ee_pipeline_rig.dart';

// The same values as the test files' own constants.
const _c1 = '11111111111111111111111111111111';
const _bob = 'ref-bob';
const _me = 'user-a';

/// Records the priority of every unit taken from the sync budget.
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

late RigCrypto rig;
late RigPeer bob;
late GroupStarter starter;
SpyBudget? spy;

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
  engine: rig.engineNow,
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
    syncBudget: spyBudget ? (clock) => spy = SpyBudget(clock) : null,
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

/// The harness's `setUp` and `tearDown`: call first in `main`.
void registerResetHarness() {
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
}

final garbage = rigBytes('a commit no engine can process');

/// Bob's next commit cannot be processed here: catch-up is stuck.
Future<void> makeStuck() async {
  rig.device.engine.failWireAlways[RigEngine.key(garbage)] = const MlsException(
    MlsErrorCode.badInput,
    'rig',
  );
  rig.server.addCommit(
    _c1,
    rig.server.current(_c1),
    garbage,
    fromUser: 'user-b',
  );
  expect(await rig.crypto.catchUp(_c1), CatchUpResult.stuck);
}

/// Stuck again in the current generation (a second unprocessable commit
/// of bob's).
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
