// Task 11 follow-up, fix round 1, ruling 1 (CR I-1 = SA M1): a new
// conversation's start applies the reset's own-device rule: it never adds
// an own device the user removed, and an unreadable removal queue means
// own devices from a fresh server own list only.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_record.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';
const _bob = 'ref-bob';
const _me = 'user-a';

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late GroupStarter starter;

  /// While set, a send that carries an init waits for it.
  Completer<void>? gate;

  /// Every id the seam was asked about, as the server shows it.
  var asked = <String>[];

  Future<kpb.ClaimedKeyPackage> packageOf(RigPeer p, {Uint8List? key}) async =>
      kpb.ClaimedKeyPackage(
        deviceId: p.idString,
        signaturePublicKey: key ?? p.key,
        keyPackage: await p.keyPackage(),
        hasKeyPackage_4: true,
      );

  /// Bob's listed devices; each claim for him hands out one package each.
  void peers(List<RigPeer> devices, {List<kpb.ClaimedKeyPackage>? extra}) {
    rig.keys.peers[_bob] = [
      for (final d in devices) rigKeyDevice(d.idString, d.key),
    ];
    rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: _c1,
      keyPackages: [for (final d in devices) await packageOf(d), ...?extra],
    );
  }

  /// This user's other devices: [listed] on the own list, [claimable] in
  /// the claim's answer (default: the listed ones).
  void siblings(List<RigPeer> listed, {List<RigPeer>? claimable}) {
    rig.keys.own.removeWhere((d) => d.deviceId != rig.device.deviceIdString);
    for (final d in listed) {
      rig.keys.own.add(rigKeyDevice(d.idString, d.key));
    }
    rig.keys.claims[_me] = () async => kpb.ClaimKeyPackagesResponse(
      keyPackages: [for (final d in claimable ?? listed) await packageOf(d)],
    );
  }

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
    wasRemovedByUser: (id) => rig.wasRemovedByUser(id),
    schedule: (delay, run) => rig.scheduled.add((delay: delay, run: run)),
    onUnexpectedError: (e, _) => rig.unexpected.add(e),
  );

  setUp(() async {
    gate = Completer<void>();
    asked = [];
    rig = await RigCrypto.create();
    rig.server.beforeSend = (send) async {
      final held = gate;
      if (send.mlsInit != null && held != null) await held.future;
    };
    bob = await RigPeer.create('bob');
    peers([bob]);
    rig.server.recipients[_bob] = _c1;
    rig.server.rows[_c1] = pb.Conversation(
      id: _c1,
      peer: common.AuthorSnapshot(userId: _bob),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    );
    build();
  });

  tearDown(() async {
    if (!(gate?.isCompleted ?? true)) gate!.complete();
    await starter.settled(_c1);
    await rig.sender.settled(_c1);
    final unexpected = [...rig.unexpected];
    await rig.dispose();
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  Future<StartOutcome> start() =>
      starter.startOrRoute(localId: 'local-1', peerUserId: _bob, text: 'hello');

  /// The devices the start's init welcomes (its stored pending record,
  /// read while the send is held).
  Future<Set<String>> welcomed() async =>
      (await rig.device.vault.group(_c1, 1))!.pending!.welcomeDeviceIds.toSet();

  Future<MemberRecord?> pin(RigPeer p) async {
    for (final m in await rig.device.vault.members(_c1)) {
      if (rigEq(m.deviceId, p.id)) return m;
    }
    return null;
  }

  void seam(bool Function(Uint8List id) removed) {
    rig.wasRemovedByUser = (id) async {
      asked.add(utf8.decode(id));
      return removed(id);
    };
  }

  void unreadableQueue() {
    rig.wasRemovedByUser = (id) async {
      asked.add(utf8.decode(id));
      throw StateError('The removal record cannot be read.');
    };
  }

  test('a start never adds a device the user removed', () async {
    final sib = await RigPeer.create('sib');
    final sib2 = await RigPeer.create('sib2');
    siblings([sib, sib2]);
    seam((id) => rigEq(id, sib.id));

    expect((await start()).result, StartResult.started);

    expect(await welcomed(), {bob.idString, sib2.idString});
    expect(await pin(sib), isNull);
    // Own-list devices only (fix round 5, R2).
    expect(asked.toSet(), {sib.idString, sib2.idString});
  });

  test('a start drops a peer claim that carries a removed own device\'s '
      'key under another id (the filter runs after the dedupe)', () async {
    final sib = await RigPeer.create('sib');
    // The server lists bob2 for bob; it signs with sib's key under its own
    // id (a real package, so only the dedupe can drop it).
    final bob2 = RigPeer.withKeyOf('bob2', sib);
    siblings([sib]);
    peers([bob, bob2]);
    seam((id) => rigEq(id, sib.id));

    expect((await start()).result, StartResult.started);

    expect(await welcomed(), {bob.idString});
    expect(await pin(bob2), isNull);
  });

  test('an unreadable removal queue: the start uses only fresh own devices '
      '(a kept own list adds none)', () async {
    final sib = await RigPeer.create('sib');
    siblings([sib]);
    // Lists read now; then the server removes sib and the directory's
    // calls are deferred, so the start's reads answer the kept lists.
    expect((await rig.directory.own(fresh: true)).readable, isTrue);
    expect((await rig.directory.peer(_bob, fresh: true)).readable, isTrue);
    rig.keys.own.removeWhere((d) => d.deviceId == sib.idString);
    rig.directoryBudget.pauseUntil(
      rig.clock.now().add(const Duration(minutes: 5)),
    );
    unreadableQueue();

    expect((await start()).result, StartResult.started);

    expect(await welcomed(), {bob.idString});
    expect(await pin(sib), isNull);
  });

  test('an unreadable removal queue with a fresh own list adds the own '
      'devices it shows', () async {
    final sib = await RigPeer.create('sib');
    siblings([sib]);
    unreadableQueue();

    expect((await start()).result, StartResult.started);

    expect(await welcomed(), {bob.idString, sib.idString});
  });

  test('a removal older than the queue\'s memory (expired mark) may be '
      're-added at a start', () async {
    final sib = await RigPeer.create('sib');
    siblings([sib]);
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
    final at = rig.clock.now().subtract(
      kRemovedByUserLimit + const Duration(minutes: 1),
    );
    await rig.device.vault.transaction(
      (tx) => tx.putSetting(
        kVaultSettingRemovalRecord,
        RemovalRecord(
          removed: [
            RemovalMark(
              deviceId: sib.idString,
              atMicros: at.microsecondsSinceEpoch,
              signatureKey: sib.key,
            ),
          ],
        ).encode(),
      ),
    );
    rig.wasRemovedByUser = runner.wasRemovedByUser;

    expect((await start()).result, StartResult.started);

    expect(await welcomed(), {bob.idString, sib.idString});
    await runner.idle();
  });
}
