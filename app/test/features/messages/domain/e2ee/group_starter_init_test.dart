import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/former_pins.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/fake_vault_world.dart';

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';
const _c3 = '33333333333333333333333333333333';
const _bob = 'ref-bob';
const _me = 'user-a';

final RegExp _keyShape = RegExp(r'^[0-9a-f]{32}$');

/// Cuts `randomBytes` answers of [cutLength] bytes by one byte.
class _CutRandomEngine extends RigEngine {
  int? cutLength;

  @override
  Future<Uint8List> randomBytes(int length) async {
    final bytes = await super.randomBytes(length);
    return length == cutLength ? bytes.sublist(0, length - 1) : bytes;
  }
}

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late GroupStarter starter;
  var publicIdsOff = false;

  /// When set, a send that carries an init waits for it (the send is in
  /// flight, under the conversation lock).
  Completer<void>? gate;

  GroupStarter build({VaultSession? session}) => starter = GroupStarter(
    crypto: rig.crypto,
    sender: rig.sender,
    receiver: rig.receiver,
    session: session ?? rig.device.session,
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
    publicIdsOff: () => publicIdsOff,
    schedule: (delay, run) => rig.scheduled.add((delay: delay, run: run)),
    onUnexpectedError: (e, _) => rig.unexpected.add(e),
  );

  pb.Conversation header(
    String id,
    String ref, {
    bool accepted = true,
    bool encrypted = false,
  }) => pb.Conversation(
    id: id,
    peer: common.AuthorSnapshot(userId: ref),
    folder: Folder.FOLDER_INBOX,
    canReply: true,
    state: accepted
        ? ConversationState.CONVERSATION_STATE_ACCEPTED
        : ConversationState.CONVERSATION_STATE_REQUEST,
    lastMessage: encrypted ? pb.MessagePreview(encrypted: true) : null,
  );

  Future<kpb.ClaimedKeyPackage> packageOf(RigPeer p, {Uint8List? key}) async =>
      kpb.ClaimedKeyPackage(
        deviceId: p.idString,
        signaturePublicKey: key ?? p.key,
        keyPackage: await p.keyPackage(),
        hasKeyPackage_4: true,
      );

  /// [ref] is a user with the devices [devices], whose 1:1 conversation with
  /// this user is [conversation]; every claim hands out one package each.
  void person(
    String ref,
    String conversation,
    List<RigPeer> devices, {
    bool accepted = true,
  }) {
    rig.keys.peers[ref] = [
      for (final d in devices) rigKeyDevice(d.idString, d.key),
    ];
    rig.keys.claims[ref] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: conversation,
      keyPackages: [for (final d in devices) await packageOf(d)],
    );
    rig.server.recipients[ref] = conversation;
    rig.server.rows[conversation] = header(
      conversation,
      ref,
      accepted: accepted,
    );
  }

  /// An own sibling device, listed and claimable.
  Future<RigPeer> sibling(String name) async {
    final sib = await RigPeer.create(name);
    rig.keys.own.add(rigKeyDevice(sib.idString, sib.key));
    final earlier = rig.keys.claims[_me];
    rig.keys.claims[_me] = () async {
      final before = earlier == null ? null : await earlier();
      return kpb.ClaimKeyPackagesResponse(
        keyPackages: [...?before?.keyPackages, await packageOf(sib)],
      );
    };
    return sib;
  }

  Future<void> newRig({RigEngine? engine}) async {
    rig = await RigCrypto.create(engine: engine);
    rig.server.beforeSend = (send) async {
      final held = gate;
      if (send.mlsInit != null && held != null) await held.future;
    };
    bob = await RigPeer.create('bob');
    person(_bob, _c1, [bob]);
    build();
  }

  setUp(() async {
    publicIdsOff = false;
    gate = null;
    await newRig();
  });

  tearDown(() async {
    if (!(gate?.isCompleted ?? true)) gate!.complete();
    final refused = rig.server.refusedAcks.length;
    final unexpected = [...rig.unexpected];
    await rig.dispose();
    expect(refused, 0, reason: 'the rig refused an AckWelcomes call');
    expect(unexpected, isEmpty, reason: 'unexpected pipeline errors');
  });

  Future<StartOutcome> start({
    String localId = 'local-1',
    String peer = _bob,
    String? conversationId,
    String text = 'hello',
  }) => starter.startOrRoute(
    localId: localId,
    peerUserId: peer,
    conversationId: conversationId,
    text: text,
  );

  /// Everything the start of [id] set going has ended.
  Future<void> done([String id = _c1]) async {
    await starter.settled(id);
    await rig.sender.settled(id);
  }

  Future<List<OutboxItem>> rows() async =>
      (await rig.device.vault.outbox()).items;

  Future<GroupRecord?> groupOf([String id = _c1]) =>
      rig.device.vault.group(id, 1);

  List<RigSend> inits() => [
    for (final s in rig.server.sends)
      if (s.mlsInit != null) s,
  ];

  /// This device joins [id] from [owner]'s welcome, in an accepted
  /// conversation (the vault is then not brand new).
  Future<void> joined(
    String id,
    RigPeer owner, {
    List<Uint8List>? others,
  }) async {
    await rig.accept(id);
    await rig.offer(id, owner, others: others ?? const []);
    expect(await rig.crypto.processWelcomes(), [id]);
  }

  const unknown = (error: NetworkException('timed out'), stored: false);

  group('routing', () {
    test('a claim answering a known conversation id of another peer is '
        'refused, never enqueued there', () async {
      expect(
        dmConversationId('uid-alpha-0001', 'uid-bravo-0002'),
        '5c4a01bed77c1e50f3e62a40d3fed130',
        reason: 'the Go ConversationID of these two uids',
      );
      expect(
        dmConversationId('uid-bravo-0002', 'uid-alpha-0001'),
        '5c4a01bed77c1e50f3e62a40d3fed130',
      );

      // _c2 is known as the conversation with carol; the claim for bob
      // answers it.
      await rig.known.add(_c2, peerUserId: 'ref-carol');
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c2,
        keyPackages: [await packageOf(bob)],
      );
      var r = await start();
      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(await groupOf(_c2), isNull);
      expect(await groupOf(), isNull);
      expect(rig.server.sends, isEmpty);

      // Public ids off: the client computes the id itself.
      publicIdsOff = true;
      person(_bob, _c1, [bob]);
      r = await start();
      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(await groupOf(), isNull);
      expect(rig.server.sends, isEmpty);

      final real = dmConversationId(_me, _bob);
      person(_bob, real, [bob]);
      r = await start();
      expect(r.result, StartResult.started);
      expect(r.conversationId, real);
      await done(real);
    });

    test('flag off or unknown routes to plaintext and makes no key-directory '
        'call', () async {
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        await rig.device.session.onFlagChanged(flag, uid: _me);
        final r = await start();
        expect(r.result, StartResult.plaintext, reason: '$flag');
        expect(r.conversationId, isNull);
      }
      expect(rig.keys.getCalls, isEmpty);
      expect(rig.keys.listCalls, 0);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, isEmpty);
    });

    test('a peer with no listed device (a readable, empty list) routes to '
        'plaintext and nothing is claimed', () async {
      rig.keys.peers[_bob] = [];
      final r = await start();
      expect(r.result, StartResult.plaintext);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rows(), isEmpty);
      expect(await groupOf(), isNull);
    });

    test('an unreadable lookup sends nothing and is retryable', () async {
      rig.keys.peerFails = true;
      var r = await start();
      expect(r.result, StartResult.lookupFailed);
      expect(r.cause, isNull);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, isEmpty);

      rig.keys.peerFails = false;
      r = await start();
      expect(r.result, StartResult.started);
      await done();
    });

    test('a deferred lookup starts encryption from the last readable '
        'non-empty list', () async {
      rig.keys.peers['ref-dave'] = [];
      await rig.directory.own();
      await rig.directory.peer(_bob);
      await rig.directory.peer('ref-dave');
      rig.clock.advance(const Duration(minutes: 31));
      rig.keys.peerError = const RateLimitedException(
        'slow down',
        retryAfter: Duration(minutes: 1),
      );

      rig.device.engine.calls.clear();

      // No readable list at all.
      var r = await start(peer: 'ref-carol');
      expect(r.result, StartResult.lookupFailed);
      // The last readable list was empty: never plaintext on a deferral.
      r = await start(peer: 'ref-dave');
      expect(r.result, StartResult.lookupFailed);
      // Refused by the routing itself: the start (whose first step draws
      // the report key) was never entered.
      expect(rig.device.engine.calls, isNot(contains('randomBytes')));
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, isEmpty);

      // Review M4: a deferred list older than the reuse window is not used
      // to check claimed packages (a device removed since could be added).
      r = await start();
      expect(r.result, StartResult.lookupFailed);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rows(), isEmpty);

      // Lists read within the reuse window, then a deferral: the start
      // goes on from them.
      rig.keys.peerError = null;
      rig.clock.advance(const Duration(minutes: 2));
      await rig.directory.own(fresh: true);
      await rig.directory.peer(_bob, fresh: true);
      rig.clock.advance(const Duration(minutes: 10));
      rig.keys.peerError = const RateLimitedException(
        'slow down',
        retryAfter: Duration(minutes: 1),
      );
      expect((await start(peer: 'ref-carol')).result, StartResult.lookupFailed);
      final lists = rig.keys.listCalls;
      final gets = rig.keys.getCalls.length;
      r = await start();
      expect(r.result, StartResult.started);
      // Both fresh lookups were deferred (no call was made for them).
      expect(rig.keys.listCalls, lists);
      expect(rig.keys.getCalls, hasLength(gets));
      expect(rig.keys.claimCalls.single.userId, _bob);
      await done();
      expect((await groupOf())!.provisional, isFalse);
    });

    test('a conversation that becomes known while routing waits is not '
        'routed to plaintext', () async {
      // During the device lookup (a readable, empty list).
      rig.keys.peers[_bob] = [];
      rig.keys.onGet = () => rig.known.add(_c1, peerUserId: _bob);
      var r = await start();
      expect(r.result, StartResult.unavailable);
      rig.keys.onGet = () => rig.known.add(_c2);
      rig.keys.peers['ref-carol'] = [];
      r = await start(peer: 'ref-carol', conversationId: _c2);
      expect(r.result, StartResult.unavailable);
      rig.keys.onGet = null;

      // With the flag off, during the cache read before the flag branch.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      rig.server.onCacheRead = () => rig.known.add(_c3, peerUserId: 'ref-dave');
      r = await start(peer: 'ref-dave');
      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, isEmpty);
    });

    test('a draft addressed by an unknown id for a peer whose stored ref '
        'names another conversation is refused', () async {
      await rig.known.add(_c2, peerUserId: _bob);
      for (final flag in [E2eeFlag.on, E2eeFlag.off]) {
        await rig.device.session.onFlagChanged(flag, uid: _me);
        final r = await start(conversationId: _c1);
        expect(r.result, StartResult.unavailable, reason: '$flag');
      }
      expect(await rows(), isEmpty);
      expect(rig.keys.getCalls, isEmpty);
      expect(rig.keys.claimCalls, isEmpty);
    });

    test('R1 refuses a recipient whose cached row is of a known '
        'conversation, and a known conversation is unavailable while this '
        'device is removed elsewhere', () async {
      // The cached row for carol is _c3, which the vault knows (no stored
      // ref of this id kind, no cache marker).
      rig.server.rows[_c3] = header(_c3, 'ref-carol');
      await rig.known.add(_c3);
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      var r = await start(peer: 'ref-carol');
      expect(r.result, StartResult.unavailable);

      await rig.known.add(_c1, peerUserId: _bob);
      rig.removedElsewhere = true;
      r = await start();
      expect(r.result, StartResult.unavailable);
      expect(r.conversationId, _c1);
      r = await start(conversationId: _c3);
      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(rig.keys.getCalls, isEmpty);
    });

    test(
      'a CANNOT_MESSAGE lookup is lookupFailed with the typed cause',
      () async {
        rig.keys.peerError = const CannotMessageException();
        final r = await start();
        expect(r.result, StartResult.lookupFailed);
        expect(r.cause, isA<CannotMessageException>());
        expect(rig.keys.claimCalls, isEmpty);
        expect(await rows(), isEmpty);
      },
    );

    test('startOrRoute resolves a recipient through the stored peer refs '
        'before any lookup', () async {
      await joined(_c1, bob);
      await rig.known.add(_c1, peerUserId: _bob);
      final lookups = rig.keys.getCalls.length;
      rig.keys.peerFails = true;

      final r = await start();

      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      expect(rig.keys.claimCalls, isEmpty);
      await done();
      // The lookups after the routing are the sender's own sync.
      expect(lookups, lessThanOrEqualTo(rig.keys.getCalls.length));
      expect(inits(), isEmpty);
      expect((await groupOf())!.provisional, isFalse);
    });

    test('a conversation in the known set is never routed to plaintext, with '
        'the flag off too', () async {
      await rig.known.add(_c1);
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);

      var r = await start(conversationId: _c1);
      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      await done();
      var saved = (await rig.device.vault.outbox(conversationId: _c1)).items;
      expect(saved.single.stage, OutboxStage.plain);

      // A conversation the cache ever knew as encrypted.
      rig.server.everEncrypted.add(_c2);
      r = await start(localId: 'local-2', conversationId: _c2);
      expect(r.result, StartResult.joinedExisting);
      await done(_c2);
      saved = (await rig.device.vault.outbox(conversationId: _c2)).items;
      expect(saved.single.localId, 'local-2');

      // R1: a recipient the stored refs do not resolve, whose cached row
      // carries the encrypted marker.
      rig.server.rows[_c3] = header(_c3, 'ref-carol', encrypted: true);
      r = await start(localId: 'local-3', peer: 'ref-carol');
      expect(r.result, StartResult.unavailable);
      expect(await rows(), hasLength(2));

      expect(rig.keys.getCalls, isEmpty);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.sends, isEmpty);
    });

    test('a vault on this device that is not open is never plaintext, '
        'whatever the flag says', () async {
      // The vault knows _c1 as the conversation with bob; the drift cache
      // holds no marker for it.
      await rig.known.add(_c1, peerUserId: _bob);
      // The vault's writes close (its lock was taken): no vault to ask.
      rig.device.owner!.steal();
      await pumpEventQueue();
      expect(rig.device.session.vault, isNull);
      expect(rig.device.session.vaultKnown, isTrue);
      // A known set that was cleared with the vault (sign-out wiring).
      rig.known.clear();

      for (final flag in [E2eeFlag.off, E2eeFlag.unknown, E2eeFlag.on]) {
        await rig.device.session.onFlagChanged(flag, uid: _me);
        expect(rig.device.session.vault, isNull);
        for (final id in [null, _c1]) {
          final r = await start(conversationId: id);
          expect(r.result, StartResult.unavailable, reason: '$flag $id');
        }
      }
      expect(rig.keys.getCalls, isEmpty);
      expect(rig.keys.listCalls, 0);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.sends, isEmpty);
    });

    test('with no open vault, plaintext is answered only when the session '
        'says this device has none', () async {
      // The known-vault marker cannot be read at sign-in with the flag off:
      // whether this device has a vault is not known.
      final world = FakeVaultWorld()..markers.failKnownReads = true;
      final unknownVault = world.launch();
      await unknownVault.onSignedIn(_me, flag: E2eeFlag.off);
      expect(unknownVault.vault, isNull);
      expect(unknownVault.vaultKnown, isFalse);
      expect(unknownVault.status.value, VaultStatus.unavailable);
      build(session: unknownVault);
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        await unknownVault.onFlagChanged(flag, uid: _me);
        expect(unknownVault.status.value, VaultStatus.unavailable);
        for (final id in [null, _c1]) {
          final r = await start(conversationId: id);
          expect(r.result, StartResult.unavailable, reason: '$flag $id');
        }
      }

      // The marker was read and there is none: the flag decides (R1).
      final none = FakeVaultWorld().launch();
      await none.onSignedIn(_me, flag: E2eeFlag.off);
      expect(none.status.value, VaultStatus.off);
      build(session: none);
      expect((await start()).result, StartResult.plaintext);

      // A platform with no vault at all.
      final unsupported = FakeVaultWorld().launch(supported: false);
      await unsupported.onSignedIn(_me, flag: E2eeFlag.off);
      expect(unsupported.status.value, VaultStatus.unsupported);
      build(session: unsupported);
      expect((await start()).result, StartResult.plaintext);

      expect(rig.keys.getCalls, isEmpty);
      expect(rig.keys.listCalls, 0);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.sends, isEmpty);
    });
  });

  group('the own-device alert', () {
    test('an own-side device never pinned before gets the own-device alert '
        'at init', () async {
      final sib = await sibling('sib');
      // 1. A brand-new vault: none.
      var r = await start();
      expect(r.result, StartResult.started);
      await done();
      expect((await groupOf())!.provisional, isFalse);
      expect(await rig.lines(_c1), isEmpty);

      // 2. A request: nothing now (Task 9 writes it at acceptance).
      final carol = await RigPeer.create('carol');
      final sib2 = await sibling('sib2');
      person('ref-carol', _c2, [carol], accepted: false);
      r = await start(localId: 'local-2', peer: 'ref-carol');
      expect(r.result, StartResult.started);
      await done(_c2);
      expect((await groupOf(_c2))!.provisional, isFalse);
      expect(
        (await rig.device.vault.conversation(_c2))!.sync.requestAccepted,
        isFalse,
      );
      expect(await rig.lines(_c2), isEmpty);

      // 3. Accepted: written with the success, never while provisional, and
      // only for the pair this vault never pinned mine before.
      final dave = await RigPeer.create('dave');
      person('ref-dave', _c3, [dave]);
      gate = Completer<void>();
      r = await start(localId: 'local-3', peer: 'ref-dave');
      expect(r.result, StartResult.started);
      expect((await groupOf(_c3))!.provisional, isTrue);
      expect(await rig.lines(_c3), isEmpty);
      gate!.complete();
      await done(_c3);
      final lines = await rig.lines(_c3);
      expect(lines, hasLength(1));
      expect(lines.single.line, SystemLine.deviceAdded);
      expect(lines.single.side, MemberSide.mine);
      expect(rigEq(lines.single.deviceId!, sib2.id), isTrue);
      expect(rigEq(lines.single.deviceId!, sib.id), isFalse);
    });

    test('an ACCEPTED init does not count its own pins as seen', () async {
      // Another accepted conversation pins another own device.
      final old = await RigPeer.create('old');
      rig.keys.own.add(rigKeyDevice(old.idString, old.key));
      await joined(_c2, bob, others: [await old.keyPackage()]);
      rig.keys.own.removeLast();
      final sib = await sibling('sib');

      expect((await start()).result, StartResult.started);
      await done();

      // sib is pinned mine in _c1 itself: that never counts as seen.
      final pin = (await rig.device.vault.members(_c1))
          .singleWhere((m) => rigEq(m.deviceId, sib.id));
      expect(pin.side, MemberSide.mine);
      final lines = await rig.lines(_c1);
      expect(lines, hasLength(1));
      expect(rigEq(lines.single.deviceId!, sib.id), isTrue);

      // Settled once: a later resume writes nothing more.
      await starter.resumeProvisional();
      expect(await rig.lines(_c1), hasLength(1));
    });

    test('a single-device account gets the own-device alert for the first '
        'own-side device met at init', () async {
      // The vault already stored a group of another accepted conversation,
      // with no other own device in it: it is not exempt.
      await joined(_c2, bob);
      final sib = await sibling('sib');

      expect((await start()).result, StartResult.started);
      await done();

      final lines = await rig.lines(_c1);
      expect(lines, hasLength(1));
      expect(lines.single.line, SystemLine.deviceAdded);
      expect(lines.single.side, MemberSide.mine);
      expect(rigEq(lines.single.deviceId!, sib.id), isTrue);
    });
  });

  group('start', () {
    test('start claims for the peer and for my other devices, checks every '
        'package and addresses the welcome to the usable ones', () async {
      final sib = await sibling('sib');
      gate = Completer<void>();
      rig.device.engine.calls.clear();

      final r = await start();

      expect(r.result, StartResult.started);
      expect(r.conversationId, _c1);
      expect(
        [for (final c in rig.keys.claimCalls) (c.userId, c.excludeDeviceId)],
        [(_bob, ''), (_me, rig.device.deviceIdString)],
      );
      expect(_keyShape.hasMatch(rig.keys.claimCalls.first.key), isTrue);
      expect(
        rig.keys.claimCalls.first.key,
        isNot(rig.keys.claimCalls.last.key),
      );
      expect(
        rig.device.engine.calls.where((c) => c == 'inspectKeyPackage'),
        hasLength(2),
      );
      final pending = (await groupOf())!.pending!;
      expect(pending.welcomeDeviceIds.toSet(), {bob.idString, sib.idString});
      final sides = {
        for (final m in await rig.device.vault.members(_c1))
          String.fromCharCodes(m.deviceId): m.side,
      };
      expect(sides, {
        rig.device.deviceIdString: MemberSide.mine,
        bob.idString: MemberSide.theirs,
        sib.idString: MemberSide.mine,
      });
      gate!.complete();
      await done();
    });

    test(
      'the group id is mlsGroupId(conversation id from the claim, 1)',
      () async {
        gate = Completer<void>();
        await start();
        final description = await rig.device.engine.inner.describe(
          (await groupOf())!.state,
        );
        expect(rigEq(description.groupId, mlsGroupId(_c1, 1)), isTrue);
        expect(description.epoch, 1);
        expect(description.hasPendingCommit, isFalse);
        gate!.complete();
        await done();
      },
    );

    test('a package failing R3 is left out and the start goes on with the '
        'rest', () async {
      final bob2 = await RigPeer.create('bob2');
      rig.keys.peers[_bob] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(bob2.idString, bob2.key),
      ];
      // The claim names another key for bob2 than the directory lists.
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [
          await packageOf(bob),
          await packageOf(bob2, key: Uint8List.fromList(List.filled(32, 7))),
        ],
      );
      gate = Completer<void>();

      expect((await start()).result, StartResult.started);

      expect((await groupOf())!.pending!.welcomeDeviceIds, [bob.idString]);
      final pinned = await rig.device.vault.members(_c1);
      expect(pinned.any((m) => rigEq(m.deviceId, bob2.id)), isFalse);
      expect(pinned, hasLength(2));
      gate!.complete();
      await done();
    });

    test(
      'no usable peer package is peerHasNoDevice and nothing is stored',
      () async {
        rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
          conversationId: _c1,
          keyPackages: [
            await packageOf(bob, key: Uint8List.fromList(List.filled(32, 7))),
          ],
        );
        final before = await rig.dump();

        final r = await start();

        expect(r.result, StartResult.peerHasNoDevice);
        expect(await rig.dump(), before);
        expect(rig.known.contains(_c1), isFalse);
        expect(rig.server.sends, isEmpty);
      },
    );

    test('the provisional group, its pending init, the pins and the encrypted '
        'row are one transaction and no mark is written', () async {
      // An engine failure after the group was built stores nothing of it.
      final before = await rig.dump();
      rig.device.engine.failNext['encrypt'] = const MlsException(
        MlsErrorCode.internal,
        'rig',
      );
      expect((await start()).result, StartResult.unavailable);
      expect(await rig.dump(), before);
      expect(rig.known.contains(_c1), isFalse);

      gate = Completer<void>();
      expect((await start()).result, StartResult.started);

      final g = (await groupOf())!;
      expect(g.provisional, isTrue);
      expect(g.epoch, 1);
      expect(
        g.provisionalCreatedAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      final pending = g.pending!;
      expect(pending.kind, PendingKind.init);
      expect(pending.builtOn, const MlsPair(1, 0));
      expect(pending.welcomeDeviceIds, [bob.idString]);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.encrypted);
      expect((row.generation, row.epoch), (1, 1));
      expect(row.localId, 'local-1');
      expect(row.recipientUserId, _bob);
      expect(row.conversationId, isNull);
      expect(_keyShape.hasMatch(row.idempotencyKey), isTrue);
      expect(row.expectedMessageId, expectedMessageId(_me, row.idempotencyKey));
      expect(
        rigEq(row.reportCommitment, reportCommitment(row.content)),
        isTrue,
      );
      expect(decodeMessageContentLenient(row.content).text, 'hello');
      final init = pb.MlsInit.fromBuffer(row.init!);
      expect(rigEq(init.commit, pending.commit), isTrue);
      expect(rigEq(init.welcome, pending.welcome!), isTrue);
      expect(init.welcomeDeviceIds, [bob.idString]);
      expect(
        await rig.device.vault.hasSent(
          _c1,
          const MlsPair(1, 1),
          sentDigest(row.ciphertext),
        ),
        isTrue,
      );
      final record = await rig.device.vault.conversation(_c1);
      expect(record?.afterPair, isNull);
      expect(record?.joinHighWater, isNull);
      expect(rig.known.contains(_c1), isTrue);
      expect(rig.known.peerOf(_c1), _bob);
      // The key history is written with the provisional group.
      expect((await rig.keyHistoryIds(_c1)).keys, [vaultDeviceIdHex(bob.id)]);
      expect(rig.messaging.noted.map((n) => n.id), contains(_c1));
      gate!.complete();
      await done();

      // A draft addressed by conversation id is stored under that id.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      gate = Completer<void>();
      final r = await start(
        localId: 'local-2',
        peer: 'ref-carol',
        conversationId: _c2,
      );
      expect(r.result, StartResult.started);
      final second = (await rows()).single;
      expect(second.conversationId, _c2);
      expect(second.recipientUserId, isNull);
      gate!.complete();
      await done(_c2);
    });

    test(
      'the request carries mls_init, pair (1, 1) and the stored bytes',
      () async {
        gate = Completer<void>();
        await start();
        final row = (await rows()).single;
        gate!.complete();
        await done();

        final send = rig.server.sends.single;
        expect(send.key, row.idempotencyKey);
        expect(send.pair, const MlsPair(1, 1));
        expect(send.recipientUserId, _bob);
        expect(send.conversationId, isNull);
        expect(rigEq(send.mlsInit!, row.init!), isTrue);
        expect(rigEq(send.ciphertext, row.ciphertext), isTrue);
        expect(rigEq(send.commitment, row.reportCommitment), isTrue);
        expect(rig.device.confirmStoredCalls, contains(row.idempotencyKey));
      },
    );

    test('success clears provisional and writes after-pair (1, 0)', () async {
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      // The response's id is not the row's: stored under the expected id.
      rig.server.sendResponseId = 'f' * 32;
      gate!.complete();
      await done();

      final g = (await groupOf())!;
      expect(g.provisional, isFalse);
      expect(g.pending, isNull);
      expect(g.epoch, 1);
      final record = (await rig.device.vault.conversation(_c1))!;
      expect(record.afterPair, const MlsPair(1, 0));
      expect(record.joinHighWater, isNull);
      expect(record.sync.requestAccepted, isTrue);
      expect(await rows(), isEmpty);
      final message = (await rig.device.vault.message(
        _c1,
        row.expectedMessageId,
      ))!;
      expect(message.mine, isTrue);
      expect(message.state, StoredMessageState.visible);
      expect(rigEq(message.content!, row.content), isTrue);
      expect(await rig.device.vault.hasMessage(_c1, 'f' * 32), isFalse);
      expect(rig.unexpected.map((e) => (e as E2eePipelineError).step), [
        'start.responseId',
      ]);
      rig.unexpected.clear();
    });

    test('a group that appeared before the lock is used instead '
        '(joinedExisting)', () async {
      final answer = rig.keys.claims[_bob]!;
      rig.keys.claims[_bob] = () async {
        // Another device's start is joined while the claim is in flight.
        await rig.offer(_c1, bob);
        expect(await rig.crypto.processWelcomes(), [_c1]);
        return answer();
      };

      final r = await start();

      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      await done();
      expect((await groupOf())!.provisional, isFalse);
      expect(inits(), isEmpty);
      final left = await rows();
      expect(
        left.every((r) => r.init == null && r.conversationId == _c1),
        isTrue,
      );
    });

    test('a claimed device the key history refuses is never added, and an '
        'unreadable history starts nothing', () async {
      // Bob's device id was seen in this conversation with two keys.
      await rig.putKeyHistory(_c1, changed: [bob.id]);
      var before = await rig.dump();
      expect((await start()).result, StartResult.peerHasNoDevice);
      expect(await rig.dump(), before);

      // A conversation with a mark and no key history: unreadable.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      await rig.device.vault.transaction(
        (tx) => tx.setJoinHighWater(_c2, const MlsPair(1, 0)),
      );
      before = await rig.dump();
      final r = await start(localId: 'local-2', peer: 'ref-carol');
      expect(r.result, StartResult.unavailable);
      expect(await rig.dump(), before);
      expect(rig.server.sends, isEmpty);
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      rig.unexpected.clear();
    });

    test('a claim answering a known conversation with no stored peer ref is '
        'refused unless the id is proven to be this peer\'s', () async {
      // _c2 was joined from a welcome; no attribution stored a peer ref.
      await joined(_c2, bob);
      expect(rig.known.contains(_c2), isTrue);
      expect(rig.known.peerOf(_c2), isNull);
      final dave = await RigPeer.create('dave');
      person('ref-dave', _c2, [dave]);
      rig.server.rows.remove(_c2);

      // Public ids on: the id cannot be computed, and nothing stored says
      // _c2 is dave's. The message never goes into that conversation.
      var r = await start(peer: 'ref-dave');
      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, isEmpty);

      // Raw uids: the computed id proves it.
      publicIdsOff = true;
      final real = dmConversationId(_me, 'ref-erin');
      final erin = await RigPeer.create('erin');
      await joined(real, bob);
      expect(rig.known.peerOf(real), isNull);
      person('ref-erin', real, [erin]);
      rig.server.rows.remove(real);
      r = await start(localId: 'local-2', peer: 'ref-erin');
      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, real);
      await done(real);
      expect(inits(), isEmpty);
    });

    test('a group that appears before the lock for an unproven id takes no '
        'row', () async {
      // The claim for dave answers _c2; while the own-side claim is in
      // flight, _c2 is joined from a welcome (no peer ref is stored).
      final dave = await RigPeer.create('dave');
      person('ref-dave', _c2, [dave]);
      rig.server.rows.remove(_c2);
      await sibling('sib');
      final own = rig.keys.claims[_me]!;
      rig.keys.claims[_me] = () async {
        await joined(_c2, bob);
        return own();
      };

      final r = await start(peer: 'ref-dave');

      expect(rig.known.peerOf(_c2), isNull);
      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, isEmpty);
    });

    test('the per-target claim cap is tryAgainTomorrow', () async {
      for (final name in [
        'keys_claims_per_target_daily',
        'keys_claims_daily',
      ]) {
        rig.keys.claimErrors[_bob] = RateLimitedException(
          'cap',
          limitName: name,
        );
        final r = await start();
        expect(r.result, StartResult.tryAgainTomorrow, reason: name);
        expect(r.cause, isA<RateLimitedException>());
      }
      expect(await rows(), isEmpty);
      expect(await groupOf(), isNull);
      expect(rig.known.contains(_c1), isFalse);
    });

    test('an init addresses at most 9 other devices and drops own devices '
        'first', () async {
      final theirs = [
        bob,
        for (var i = 2; i <= 8; i++) await RigPeer.create('bob$i'),
      ];
      person(_bob, _c1, theirs);
      final sib = await sibling('sib');
      final sib2 = await sibling('sib2');
      gate = Completer<void>();

      expect((await start()).result, StartResult.started);

      final welcomed = (await groupOf())!.pending!.welcomeDeviceIds;
      expect(welcomed, hasLength(9));
      expect(
        welcomed.toSet().containsAll([for (final p in theirs) p.idString]),
        isTrue,
      );
      expect(
        [sib.idString, sib2.idString].where(welcomed.contains),
        hasLength(1),
      );
      expect(await rig.device.vault.members(_c1), hasLength(10));
      gate!.complete();
      await done();
    });

    test('a listed device the claim leaves out is not claimed again the same '
        'IST day', () async {
      rig.keys.claims[_bob] = () async =>
          kpb.ClaimKeyPackagesResponse(conversationId: _c1);

      expect((await start()).result, StartResult.peerHasNoDevice);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await rig.ledger.emptyClaimTried(bob.id), isTrue);
      expect((await start()).result, StartResult.peerHasNoDevice);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await rows(), isEmpty);
    });

    test('an empty claim for a listed device is not repeated the same IST '
        'day', () async {
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [
          kpb.ClaimedKeyPackage(
            deviceId: bob.idString,
            signaturePublicKey: bob.key,
            hasKeyPackage_4: false,
          ),
        ],
      );

      expect((await start()).result, StartResult.peerHasNoDevice);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await rig.ledger.emptyClaimTried(bob.id), isTrue);

      expect((await start()).result, StartResult.peerHasNoDevice);
      expect(rig.keys.claimCalls, hasLength(1));

      rig.clock.advance(const Duration(hours: 24));
      expect((await start()).result, StartResult.peerHasNoDevice);
      expect(rig.keys.claimCalls, hasLength(2));
      expect(await rows(), isEmpty);
    });

    test(
      'a start outcome has no text form that shows the conversation id',
      () async {
        gate = Completer<void>();
        final r = await start();
        expect(r.conversationId, _c1);
        expect(r.toString(), isNot(contains(_c1)));
        gate!.complete();
        await done();
      },
    );

    test('a random answer of another length stores nothing', () async {
      await rig.dispose();
      final engine = _CutRandomEngine();
      await newRig(engine: engine);
      final before = await rig.dump();
      for (final length in [16, kReportKeyBytes]) {
        engine.cutLength = length;
        expect((await start()).result, StartResult.unavailable);
      }
      expect(await rig.dump(), before);
      expect(rig.server.sends, isEmpty);
      expect(rig.unexpected.map((e) => (e as E2eePipelineError).step), [
        'start.random',
      ]);
      rig.unexpected.clear();
    });
  });

  group('the init send', () {
    test('a timeout resends the identical request', () async {
      rig.server.sendScript.add(unknown);

      expect((await start()).result, StartResult.started);
      await done();

      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[0].mlsInit, isNotNull);
      expect(rig.server.sends[0].same(rig.server.sends[1]), isTrue);
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
    });

    test('a restart with a provisional group resends the same bytes', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      expect(rig.server.sends, hasLength(2));

      await rig.restart();
      build();
      await starter.resumeProvisional();
      await done();

      expect(rig.server.sends, hasLength(3));
      expect(rig.server.sends[0].same(rig.server.sends[2]), isTrue);
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
    });

    test('STALE_EPOCH deletes the provisional group, joins from the winner\'s '
        'welcome and re-encrypts under a new key', () async {
      // Bob's own start reached the server first.
      await rig.offer(_c1, bob);
      Uint8List? historyWhileProvisional;
      rig.server.onCall = (call) async {
        if (call == 'sendEncrypted') {
          historyWhileProvisional ??= await rig.sealedSetting(
            'messages.e2ee.keys.$_c1',
          );
        }
      };

      expect((await start()).result, StartResult.started);
      await done();

      final first = rig.server.sends.first;
      expect(first.mlsInit, isNotNull);
      final g = (await groupOf())!;
      expect(g.provisional, isFalse);
      expect(g.pending, isNull);
      expect(rig.device.engine.calls, contains('joinFromWelcome'));
      // The history written with the provisional group is still there, and
      // bob's device is attributable in the joined group.
      expect(historyWhileProvisional, isNotNull);
      expect(
        (await rig.keyHistoryIds(_c1)).keys,
        contains(vaultDeviceIdHex(bob.id)),
      );
      expect(await rig.keyHistoryChanged(_c1), isEmpty);
      final last = rig.server.sends.last;
      expect(last.mlsInit, isNull);
      expect(last.conversationId, _c1);
      expect(last.key, isNot(first.key));
      expect(last.pair, const MlsPair(1, 1));
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(
          _c1,
          expectedMessageId(_me, last.key),
        ),
        isTrue,
      );
      expect(
        await rig.device.vault.hasMessage(
          _c1,
          expectedMessageId(_me, first.key),
        ),
        isFalse,
      );
    });

    test('a STALE_EPOCH that does not name the claim\'s conversation deletes '
        'nothing', () async {
      for (final named in [_c2, null]) {
        rig.server.sendScript.add((
          error: StaleEpochException(
            'stale',
            generation: 1,
            epoch: 1,
            conversationId: named,
          ),
          stored: false,
        ));
        if (named == _c2) {
          await start();
        } else {
          await starter.resumeProvisional();
        }
        await done();
        expect((await groupOf())!.provisional, isTrue, reason: '$named');
        expect((await rows()).single.init, isNotNull);
        expect(await rig.device.vault.members(_c1), hasLength(2));
      }
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[0].same(rig.server.sends[1]), isTrue);
      expect(rig.unexpected.map((e) => (e as E2eePipelineError).step), [
        'start.staleConversation',
      ]);
      rig.unexpected.clear();
    });

    test('a replay check is not confused by the loser\'s own marks', () async {
      final offer = await rig.offer(_c1, bob);
      MlsPair? afterWhileProvisional = const MlsPair(9, 9);
      MlsPair? highWhileProvisional = const MlsPair(9, 9);
      rig.server.onCall = (call) async {
        if (call == 'sendEncrypted' && rig.server.sends.isEmpty) {
          final record = await rig.device.vault.conversation(_c1);
          afterWhileProvisional = record?.afterPair;
          highWhileProvisional = record?.joinHighWater;
        }
      };

      await start();
      await done();

      // The provisional group wrote no mark, so the welcome labelled (1, 0)
      // is above both marks and is joined.
      expect(afterWhileProvisional, isNull);
      expect(highWhileProvisional, isNull);
      final record = (await rig.device.vault.conversation(_c1))!;
      expect(record.joinHighWater, const MlsPair(1, 0));
      expect(record.afterPair, const MlsPair(1, 0));
      expect(rig.server.acks.expand((a) => a.ids), [offer.welcomeId]);
      expect((await groupOf())!.provisional, isFalse);
    });

    test('a first-attempt CANNOT_MESSAGE deletes the provisional group and '
        'fails the row', () async {
      rig.server.sendScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      Uint8List? history;
      rig.server.onCall = (call) async {
        if (call == 'sendEncrypted') {
          history = await rig.sealedSetting('messages.e2ee.keys.$_c1');
        }
      };

      expect((await start()).result, StartResult.started);
      await done();

      expect(rig.server.sends, hasLength(1));
      expect(await groupOf(), isNull);
      expect(await rig.device.vault.members(_c1), isEmpty);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.init, isNull);
      expect(row.ciphertext, isEmpty);
      expect(row.lastError, 'CannotMessageException');
      expect(row.conversationId, _c1);
      expect(row.localId, 'local-1');
      // The discard never touches the key history.
      expect(
        rigEq((await rig.sealedSetting('messages.e2ee.keys.$_c1'))!, history!),
        isTrue,
      );
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.error, isA<CannotMessageException>());
      expect(shown.retryable, isFalse);
    });

    test('FEATURE_DISABLED on a retry with the expected id in ListMessages is '
        'a success', () async {
      rig.server.sendScript.addAll([
        (error: const NetworkException('timed out'), stored: true),
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();

      expect(rig.server.sends, hasLength(2));
      expect(rig.server.calls, contains('listMlsMessages'));
      final g = (await groupOf())!;
      expect(g.provisional, isFalse);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(1, 0),
      );
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
      expect(await rows(), isEmpty);
    });

    test('on a retry, a STALE_EPOCH or a refusal never deletes a group whose '
        'init is the first stored commit', () async {
      // The first attempt was stored and its answer lost. The retry is
      // answered STALE_EPOCH (the server's replay record is gone).
      rig.server.sendScript.addAll([
        (error: const NetworkException('timed out'), stored: true),
        (
          error: const StaleEpochException(
            'stale',
            generation: 1,
            epoch: 1,
            conversationId: _c1,
          ),
          stored: false,
        ),
      ]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();

      expect((await groupOf())!.provisional, isFalse);
      expect(await rig.device.vault.members(_c1), hasLength(2));
      expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(1, 0),
      );
      // The message came back as the live pull's echo.
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );

      // A refusal on a retry, with the stored message not on the first
      // ListMessages page (50 newer messages): the commit check decides.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      rig.server.sendScript.addAll([
        (error: const NetworkException('timed out'), stored: true),
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      var hidden = false;
      rig.server.rewriteLive = (real) {
        if (hidden) return real;
        hidden = true;
        return pb.ListMessagesResponse(conversation: real.conversation);
      };
      await start(localId: 'local-2', peer: 'ref-carol');
      await done(_c2);

      expect(hidden, isTrue);
      expect((await groupOf(_c2))!.provisional, isFalse);
      expect(await rig.device.vault.members(_c2), hasLength(2));
      expect(await rows(), isEmpty);
    });

    test('FEATURE_DISABLED on a retry without it is a refusal', () async {
      rig.server.sendScript.addAll([
        unknown,
        (error: const FeatureDisabledException('off'), stored: false),
      ]);

      await start();
      await done();

      expect(rig.server.sends, hasLength(2));
      expect(await groupOf(), isNull);
      expect(await rig.device.vault.members(_c1), isEmpty);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, 'FeatureDisabledException');
      expect(row.init, isNull);
    });

    test('text typed while provisional waits at stage plain and goes out '
        'after success', () async {
      gate = Completer<void>();
      expect((await start()).result, StartResult.started);

      final r = await start(localId: 'local-2', text: 'second');
      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      expect(rig.keys.claimCalls, hasLength(1));
      final waiting = (await rig.device.vault.outbox(conversationId: _c1))
          .items;
      expect(waiting.single.stage, OutboxStage.plain);
      expect(waiting.single.localId, 'local-2');
      final shown = await rig.sender.outgoing(_c1);
      expect(shown.single.status, OutgoingStatus5a.waiting);
      expect(shown.single.waitingOn, SendBlock.provisional);
      expect(rig.server.sends.where((s) => s.mlsInit == null), isEmpty);

      gate!.complete();
      await done();

      expect(await rows(), isEmpty);
      expect(rig.server.sends, hasLength(2));
      final second = rig.server.sends.last;
      expect(second.mlsInit, isNull);
      expect(second.conversationId, _c1);
      expect(second.pair, const MlsPair(1, 1));
      expect(
        await rig.device.vault.hasMessage(
          _c1,
          expectedMessageId(_me, second.key),
        ),
        isTrue,
      );
    });

    test('an init is not sent while a member is unattributed, the flag is '
        'off or this device was removed elsewhere', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect(rig.server.sends, hasLength(2));

      // Removed elsewhere.
      rig.removedElsewhere = true;
      await starter.resumeProvisional();
      await done();
      rig.removedElsewhere = false;
      // The flag is not on.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      await starter.resumeProvisional();
      await done();
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      // A member is not attributable.
      await rig.device.vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: bob.id,
            signatureKey: bob.key,
            side: MemberSide.unattributed,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      await starter.resumeProvisional();
      await done();

      expect(rig.server.sends, hasLength(2));
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.init, isNotNull);
    });
  });

  group('a new start for a known conversation (review F1, option c)', () {
    /// A first message to bob whose init the server refused on the first
    /// attempt with [error]: known, no group, a failed stage-plain row.
    Future<void> refusedOnce([
      AppException error = const RateLimitedException(
        'slow down',
        retryAfter: Duration(minutes: 1),
      ),
    ]) async {
      rig.server.sendScript.add((error: error, stored: false));
      expect((await start()).result, StartResult.started);
      await done();
      expect(await groupOf(), isNull);
      expect((await rows()).single.lastError, isNotNull);
      expect(rig.known.peerOf(_c1), _bob);
      rig.keys.claimCalls.clear();
    }

    /// The user discards the failed row of [refusedOnce]: known, no group,
    /// no row (a new send is then the head row, review 3d).
    Future<void> discardFailed() async {
      await rig.sender.discard('local-1');
      expect(await rows(), isEmpty);
    }

    const cap = RateLimitedException(
      'cap',
      limitName: 'keys_claims_per_target_daily',
    );

    /// After [refusedOnce] and the discard of its failed row, a second
    /// message (the head row, not failed): saved, and no new start.
    Future<void> expectNoNewStart({
      String peer = _bob,
      String? conversationId,
    }) async {
      await discardFailed();
      final r = await start(
        localId: 'local-2',
        peer: peer,
        conversationId: conversationId,
        text: 'second',
      );
      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      await done();
      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      final left = await rows();
      expect(left.map((r) => r.localId), ['local-2']);
      expect(left.every((r) => r.stage == OutboxStage.plain), isTrue);
      expect(rig.server.sends, hasLength(1));
    }

    test('after the failed row is discarded, a new send starts again from '
        'fresh claims with the new row, and the id stays known', () async {
      await refusedOnce();
      final refused = rig.server.sends.single;
      await discardFailed();

      final r = await start(localId: 'local-2', text: 'second');

      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      await done();
      expect(rig.keys.claimCalls.single.userId, _bob);
      expect(rig.known.contains(_c1), isTrue);
      final g = (await groupOf())!;
      expect(g.provisional, isFalse);
      expect(await rows(), isEmpty);
      // The new row went out as the new group's init, under its own key.
      expect(rig.server.sends, hasLength(2));
      final again = rig.server.sends[1];
      expect(again.mlsInit, isNotNull);
      expect(again.key, isNot(refused.key));
      final stored = (await rig.device.vault.message(
        _c1,
        expectedMessageId(_me, again.key),
      ))!;
      expect(decodeMessageContentLenient(stored.content!).text, 'second');
    });

    test('a new send behind a failed head row makes no claim and leaves the '
        'head failed; the retry of the head sends both in order', () async {
      await refusedOnce();
      final refused = rig.server.sends.single;

      final r = await start(localId: 'local-2', text: 'second');

      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c1);
      await done();
      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      var left = await rows();
      expect(left.map((r) => r.localId), ['local-1', 'local-2']);
      expect(left.every((r) => r.stage == OutboxStage.plain), isTrue);
      expect(left.first.lastError, 'RateLimitedException');
      expect(left.last.lastError, isNull);
      final shown = await rig.sender.outgoing(_c1);
      expect(shown.first.status, OutgoingStatus5a.failed);
      expect(shown.last.status, OutgoingStatus5a.waiting);
      expect(rig.server.sends, hasLength(1));

      // The user's retry of the failed head: it goes out first, as the new
      // group's init under a NEW key; the second message after it.
      await starter.retryStart('local-1');
      await done();

      expect(rig.keys.claimCalls.single.userId, _bob);
      expect((await groupOf())!.provisional, isFalse);
      left = await rows();
      expect(left, isEmpty);
      expect(rig.server.sends, hasLength(3));
      final again = rig.server.sends[1];
      expect(again.mlsInit, isNotNull);
      expect(again.key, isNot(refused.key));
      expect(rig.server.sends[2].mlsInit, isNull);
      final first = (await rig.device.vault.message(
        _c1,
        expectedMessageId(_me, again.key),
      ))!;
      expect(decodeMessageContentLenient(first.content!).text, 'hello');
      expect(
        await rig.device.vault.hasMessage(
          _c1,
          expectedMessageId(_me, rig.server.sends[2].key),
        ),
        isTrue,
      );
    });

    test('the retry of a row behind a failed head row starts nothing and '
        'changes neither row', () async {
      await refusedOnce();
      await start(localId: 'local-2', text: 'second');
      await done();

      await starter.retryStart('local-2');
      await done();

      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      final left = await rows();
      expect(left.map((r) => r.localId), ['local-1', 'local-2']);
      expect(left.first.lastError, 'RateLimitedException');
      expect(rig.server.sends, hasLength(1));
    });

    test('the retry of a later row starts with the oldest waiting row when '
        'that row is not failed', () async {
      await refusedOnce();
      await discardFailed();
      // Two rows saved while nothing may start (the flag is not on).
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      await start(localId: 'local-2', text: 'second');
      await start(localId: 'local-3', text: 'third');
      await done();
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      expect(rig.keys.claimCalls, isEmpty);

      await starter.retryStart('local-3');
      await done();

      expect(rig.keys.claimCalls.single.userId, _bob);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, hasLength(3));
      final init = rig.server.sends[1];
      expect(init.mlsInit, isNotNull);
      final first = (await rig.device.vault.message(
        _c1,
        expectedMessageId(_me, init.key),
      ))!;
      expect(decodeMessageContentLenient(first.content!).text, 'second');
      expect(rig.server.sends[2].mlsInit, isNull);
    });

    test('a retry whose claim fails keeps the row failed and retryable, and '
        'a later retry starts', () async {
      await refusedOnce();
      rig.keys.claimErrors[_bob] = const NetworkException('no network');

      await starter.retryStart('local-1');
      await done();

      expect(rig.keys.claimCalls, hasLength(1));
      expect(await groupOf(), isNull);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, 'RateLimitedException');
      var shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(shown.error, isA<RateLimitedException>());
      expect(shown.tryTomorrow, isFalse);

      // The peer's list cannot be read: the same.
      rig.keys.claimErrors.clear();
      rig.keys.peerFails = true;
      await starter.retryStart('local-1');
      await done();
      shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(rig.keys.claimCalls, hasLength(1));

      // The network is back.
      rig.keys.peerFails = false;
      await starter.retryStart('local-1');
      await done();
      expect(rig.keys.claimCalls, hasLength(2));
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[1].mlsInit, isNotNull);
    });

    test('one new start per conversation at a time: a second trigger while '
        'the claim is in flight makes no second claim', () async {
      await refusedOnce();
      final answer = rig.keys.claims[_bob]!;
      final entered = Completer<void>();
      final release = Completer<void>();
      rig.keys.claims[_bob] = () async {
        // Only the first claim is held in flight.
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return answer();
      };

      final first = starter.retryStart('local-1');
      await entered.future;
      // The user taps retry again while the first start's claim is out.
      await starter.retryStart('local-1');

      expect(rig.keys.claimCalls, hasLength(1));
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, 'RateLimitedException');

      release.complete();
      await first;
      await done();
      expect(rig.keys.claimCalls, hasLength(1));
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, hasLength(2));

      // The single flight ended with the start: a later one is not refused.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      rig.server.sendScript.add((
        error: const DegradedModeException('degraded'),
        stored: false,
      ));
      await start(localId: 'local-3', peer: 'ref-carol');
      await done(_c2);
      rig.keys.claimErrors['ref-carol'] = const NetworkException('down');
      await starter.retryStart('local-3');
      rig.keys.claimErrors.clear();
      await starter.retryStart('local-3');
      await done(_c2);
      expect((await groupOf(_c2))!.provisional, isFalse);
    });

    test(
      'no new start while a row of the conversation no longer opens',
      () async {
        await refusedOnce();
        // The first row's sealed content no longer opens: only its place in
        // the order is known.
        await rig.device.db.customStatement(
          "UPDATE vault_outbox SET content = x'0102030405'",
        );
        expect(
          (await rig.device.vault.outbox(conversationId: _c1)).unreadableKeys,
          hasLength(1),
        );

        // A later message would become the new group's first message.
        final r = await start(localId: 'local-2', text: 'second');
        expect(r.result, StartResult.joinedExisting);
        await done();
        expect(rig.keys.claimCalls, isEmpty);
        expect(await groupOf(), isNull);

        await starter.retryStart('local-2');
        await done();
        expect(rig.keys.claimCalls, isEmpty);
        expect(await groupOf(), isNull);
        final row = (await rows()).single;
        expect(row.localId, 'local-2');
        expect(row.stage, OutboxStage.plain);
        expect(rig.server.sends, hasLength(1));
        // The sender's own stop at that row.
        final reports = [
          for (final e in rig.unexpected) (e as E2eePipelineError).step,
        ];
        rig.unexpected.clear();
        expect(reports, ['send.outbox.unreadable']);
      },
    );

    test('a retry at the per-target claim cap leaves the row failed with '
        'tryTomorrow', () async {
      await refusedOnce();
      rig.keys.claimErrors[_bob] = cap;

      await starter.retryStart('local-1');
      await done();

      expect(rig.keys.claimCalls, hasLength(1));
      expect(await groupOf(), isNull);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, 'RateLimitedException');
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.tryTomorrow, isTrue);
      expect(shown.retryable, isTrue);
      expect(rig.server.sends, hasLength(1));
    });

    test(
      'the user\'s retry of the failed row starts again from fresh claims',
      () async {
        await refusedOnce();

        await starter.retryStart('local-1');
        await done();

        expect(rig.keys.claimCalls.single.userId, _bob);
        expect((await groupOf())!.provisional, isFalse);
        expect(await rows(), isEmpty);
        expect(rig.server.sends, hasLength(2));
        expect(rig.server.sends[1].mlsInit, isNotNull);
        expect(rig.server.sends[1].key, isNot(rig.server.sends[0].key));
      },
    );

    test(
      'a refused init is never started again by a background trigger',
      () async {
        await refusedOnce();

        await starter.resumeProvisional();
        await rig.sender.drain(_c1);
        await done();
        await rig.restart();
        build();
        await starter.resumeProvisional();
        await done();

        expect(rig.keys.claimCalls, isEmpty);
        expect(await groupOf(), isNull);
        expect((await rows()).single.stage, OutboxStage.plain);
        expect(rig.server.sends, hasLength(1));
      },
    );

    test('no new start while a mark shows this device was a member', () async {
      await refusedOnce();
      await rig.device.vault.transaction(
        (tx) => tx.setJoinHighWater(_c1, const MlsPair(1, 0)),
      );
      await expectNoNewStart();
    });

    test('no new start while a first-saw generation is stored', () async {
      await refusedOnce();
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c1,
          ConversationSync(
            firstSawGeneration: 1,
            firstSawGenerationAtMicros: rig.clock.now().microsecondsSinceEpoch,
          ),
        ),
      );
      await expectNoNewStart();
    });

    test('no new start while former pins are stored', () async {
      await refusedOnce();
      final v = rig.device.vault;
      await v.transaction(
        (tx) => const FormerPins().putIn(tx, v, _c1, [
          MemberRecord(
            conversationId: _c1,
            deviceId: bob.id,
            signatureKey: bob.key,
            side: MemberSide.theirs,
            since: const MlsPair(1, 1),
          ),
        ]),
      );
      await expectNoNewStart();
    });

    test('no new start for another peer than the stored peer ref', () async {
      await refusedOnce();
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-carol'] = [rigKeyDevice(carol.idString, carol.key)];
      await expectNoNewStart(peer: 'ref-carol', conversationId: _c1);
    });

    test('no new start with the flag not on', () async {
      await refusedOnce();
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      await expectNoNewStart();
    });

    test('no new start in this run after CANNOT_MESSAGE', () async {
      await refusedOnce(const CannotMessageException());
      await expectNoNewStart();
    });
  });

  group('the pending init row (review I4)', () {
    test('pendingInit answers for a recipient-addressed and an id-addressed '
        'init row, and null after a settle or a discard', () async {
      expect(await starter.pendingInit(conversationId: _c1), isNull);
      gate = Completer<void>();
      await start();
      // The sender lists nothing for it: the row is addressed by recipient.
      expect(await rig.sender.outgoing(_c1), isEmpty);
      for (final shown in [
        await starter.pendingInit(conversationId: _c1),
        await starter.pendingInit(recipientUserId: _bob),
      ]) {
        expect(shown!.localId, 'local-1');
        expect(shown.conversationId, _c1);
        expect(shown.status, OutgoingStatus5a.sending);
        expect(shown.waitingOn, SendBlock.none);
        expect(decodeMessageContentLenient(shown.content).text, 'hello');
        expect(shown.error, isNull);
      }
      expect(await starter.pendingInit(conversationId: _c2), isNull);
      expect(await starter.pendingInit(recipientUserId: 'ref-carol'), isNull);
      gate!.complete();
      await done();
      // Settled: the message is stored, nothing is pending.
      expect(await starter.pendingInit(conversationId: _c1), isNull);
      expect(await starter.pendingInit(recipientUserId: _bob), isNull);

      // Addressed by conversation id; then discarded on a refusal.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      gate = Completer<void>();
      rig.server.sendScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await start(localId: 'local-2', peer: 'ref-carol', conversationId: _c2);
      final second = await starter.pendingInit(conversationId: _c2);
      expect(second!.localId, 'local-2');
      expect(second.status, OutgoingStatus5a.sending);
      gate!.complete();
      await done(_c2);
      expect(await starter.pendingInit(conversationId: _c2), isNull);
      // The failed row is the sender's now.
      expect((await rig.sender.outgoing(_c2)).single.localId, 'local-2');
    });

    test('pendingInit finds a recipient-addressed init row by the '
        'conversation that holds its group, also when the ref is stored for '
        'two ids', () async {
      gate = Completer<void>();
      await start();
      // The same peer ref under a second id that has a stored group (an
      // honest server cannot produce this): the recipient now resolves to
      // that id, not to the one whose provisional group the row belongs to.
      final carol = await RigPeer.create('carol');
      await joined(_c2, carol);
      await rig.known.add(_c2, peerUserId: _bob);
      expect(rig.known.peerOf(_c2), _bob);
      expect(await rig.known.conversationForPeer(rig.device.vault, _bob), _c2);

      final shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.localId, 'local-1');
      expect(shown.conversationId, _c1);
      // The other id holds no provisional group: the row is not its.
      expect(await starter.pendingInit(conversationId: _c2), isNull);
      final byRef = (await starter.pendingInit(recipientUserId: _bob))!;
      expect(byRef.localId, 'local-1');
      expect(byRef.conversationId, _c1);

      gate!.complete();
      await done();
      expect(await starter.pendingInit(conversationId: _c1), isNull);
      expect(await starter.pendingInit(recipientUserId: _bob), isNull);
    });

    test('pendingInit says waiting while the init is held', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();

      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      var shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.status, OutgoingStatus5a.waiting);
      expect(shown.waitingOn, SendBlock.unavailable);
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);

      rig.removedElsewhere = true;
      shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.waitingOn, SendBlock.unavailable);
      rig.removedElsewhere = false;

      await rig.device.vault.transaction(
        (tx) => tx.putMember(
          MemberRecord(
            conversationId: _c1,
            deviceId: bob.id,
            signatureKey: bob.key,
            side: MemberSide.unattributed,
            since: const MlsPair(1, 1),
          ),
        ),
      );
      shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.status, OutgoingStatus5a.waiting);
      expect(shown.waitingOn, SendBlock.notSynced);
    });
  });

  group('the 24 h rebuild (review I3)', () {
    test('a failed claim leaves the provisional group untouched, and a later '
        'resume rebuilds it in one step', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      final old = (await groupOf())!;
      final oldRow = (await rows()).single;
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 0),
        rigBytes('the init of another device'),
        fromUser: 'user-b',
      );
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      rig.keys.claimCalls.clear();

      Future<void> expectUntouched(String why) async {
        final g = (await groupOf())!;
        expect(g.provisional, isTrue, reason: why);
        expect(
          g.provisionalCreatedAtMicros,
          old.provisionalCreatedAtMicros,
          reason: why,
        );
        final row = (await rows()).single;
        expect(row.idempotencyKey, oldRow.idempotencyKey, reason: why);
        expect(row.init, isNotNull, reason: why);
        expect(row.lastError, isNull, reason: why);
        expect(await rig.device.vault.members(_c1), hasLength(2), reason: why);
      }

      // (a) The claim fails for a passing reason.
      rig.keys.claimErrors[_bob] = const NetworkException('no network');
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(1));
      await expectUntouched('a failed claim');
      rig.keys.claimErrors.clear();

      // (b) The own list cannot be read.
      rig.keys.ownFails = true;
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(1));
      await expectUntouched('an unreadable own list');
      rig.keys.ownFails = false;

      // (c) The app restarts in between; the next resume starts again.
      await rig.restart();
      build();
      rig.clock.advance(const Duration(minutes: 2));
      rig.server.sendScript.addAll([unknown, unknown]);
      await starter.resumeProvisional();
      await done();

      final rebuilt = (await groupOf())!;
      expect(rebuilt.provisional, isTrue);
      expect(
        rebuilt.provisionalCreatedAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      final row = (await rows()).single;
      expect(row.localId, oldRow.localId);
      expect(row.idempotencyKey, isNot(oldRow.idempotencyKey));
      expect(row.init, isNotNull);
      expect(row.recipientUserId, _bob);
      expect(await rig.device.vault.members(_c1), hasLength(2));
      expect(rig.server.sends.last.key, row.idempotencyKey);
    });
  });

  group('an expired provisional group that cannot be rebuilt (review N5)', () {
    test('a rebuild that finds no device discards the group and fails the '
        'row; the user\'s retry starts again', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      // The peer removed its devices: no rebuild can be made.
      rig.keys.peers[_bob] = [];
      rig.keys.claimCalls.clear();

      await starter.resumeProvisional();
      await done();

      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      expect(await rig.device.vault.members(_c1), isEmpty);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.init, isNull);
      expect(row.conversationId, _c1);
      expect(row.lastError, kStartErrorPeerHasNoDevice);
      expect(await starter.pendingInit(conversationId: _c1), isNull);
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(rig.known.contains(_c1), isTrue);

      // Nothing repeats in the background: the row waits for the user.
      final calls = rig.server.calls.length;
      await starter.resumeProvisional();
      await done();
      expect(rig.server.calls, hasLength(calls));

      // The retry while the peer still has no device keeps the failure.
      await starter.retryStart('local-1');
      await done();
      expect((await rows()).single.lastError, kStartErrorPeerHasNoDevice);

      // The peer has a device again: the user's retry starts (F1 c).
      person(_bob, _c1, [bob]);
      await starter.retryStart('local-1');
      await done();
      expect(rig.keys.claimCalls.single.userId, _bob);
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
    });

    test(
      'pendingInit never says sending for a group older than 24 h',
      () async {
        rig.server.sendScript.addAll([unknown, unknown]);
        await start();
        await done();
        var shown = (await starter.pendingInit(conversationId: _c1))!;
        expect(shown.status, OutgoingStatus5a.sending);

        rig.clock.advance(kProvisionalExpiry);
        // The rebuild cannot be made for a passing reason: the group stays.
        rig.keys.peerFails = true;
        await starter.resumeProvisional();
        await done();
        expect((await groupOf())!.provisional, isTrue);
        for (final shown in [
          await starter.pendingInit(conversationId: _c1),
          await starter.pendingInit(recipientUserId: _bob),
        ]) {
          expect(shown!.localId, 'local-1');
          expect(shown.status, OutgoingStatus5a.waiting);
          expect(shown.waitingOn, SendBlock.provisional);
          expect(shown.retryable, isFalse);
        }
      },
    );
  });

  group('resumeProvisional', () {
    test('a provisional group older than 24 h whose init is the first stored '
        'commit is cleared, not rebuilt', () async {
      rig.server.sendScript.addAll([
        (error: const NetworkException('timed out'), stored: true),
        unknown,
      ]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      rig.keys.claimCalls.clear();
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));

      await starter.resumeProvisional();
      await done();

      final g = (await groupOf())!;
      expect(g.provisional, isFalse);
      expect(g.pending, isNull);
      expect(
        (await rig.device.vault.conversation(_c1))!.afterPair,
        const MlsPair(1, 0),
      );
      expect(rig.keys.claimCalls, isEmpty);
      // The message itself came back as an echo of the live pull.
      expect(rig.server.sends, hasLength(2));
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
    });

    test('a provisional group older than 24 h with another first commit is '
        'discarded and rebuilt from fresh claims', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      final old = (await groupOf())!;
      final oldRow = (await rows()).single;
      expect(old.provisional, isTrue);
      // Another device's init is the first stored commit.
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 0),
        rigBytes('the init of another device'),
        fromUser: 'user-b',
      );
      rig.keys.claimCalls.clear();
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      // The rebuilt init's send stays unanswered.
      rig.server.sendScript.addAll([unknown, unknown]);

      await starter.resumeProvisional();
      await done();

      expect(rig.keys.claimCalls.single.userId, _bob);
      final rebuilt = (await groupOf())!;
      expect(rebuilt.provisional, isTrue);
      expect(
        rebuilt.provisionalCreatedAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      final row = (await rows()).single;
      expect(row.localId, oldRow.localId);
      expect(row.stage, OutboxStage.encrypted);
      expect(row.init, isNotNull);
      expect(row.idempotencyKey, isNot(oldRow.idempotencyKey));
      expect(row.expectedMessageId, isNot(oldRow.expectedMessageId));
      expect(rigEq(row.content, oldRow.content), isTrue);
      expect(row.createdAtMicros, oldRow.createdAtMicros);
      expect(rig.server.sends.last.key, row.idempotencyKey);
    });

    test(
      'at the claim cap a rebuilt row fails with tryAgainTomorrow',
      () async {
        rig.server.sendScript.addAll([unknown, unknown]);
        await start();
        await done();
        rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
        rig.keys.claimErrors[_bob] = const RateLimitedException(
          'cap',
          limitName: 'keys_claims_per_target_daily',
        );

        await starter.resumeProvisional();
        await done();

        expect(await groupOf(), isNull);
        final row = (await rows()).single;
        expect(row.stage, OutboxStage.plain);
        expect(row.conversationId, _c1);
        expect(row.lastError, 'RateLimitedException');
        final shown = (await rig.sender.outgoing(_c1)).single;
        expect(shown.status, OutgoingStatus5a.failed);
        expect(shown.tryTomorrow, isTrue);
      },
    );

    test(
      'settling ownStored leaves the key history readable and unchanged',
      () async {
        await rig.seedProvisional(_c1, [bob]);
        final pending = (await groupOf())!.pending!;
        final key = 'a' * 32;
        await rig.device.vault.transaction(
          (tx) => tx.putOutbox(
            OutboxItem(
              idempotencyKey: key,
              localId: 'local-1',
              expectedMessageId: expectedMessageId(_me, key),
              recipientUserId: _bob,
              generation: 1,
              epoch: 1,
              ciphertext: Uint8List.fromList([1, 2, 3]),
              reportCommitment: Uint8List(32),
              content: rigBytes('hello'),
              createdAtMicros: rig.clock.now().microsecondsSinceEpoch,
              init: Uint8List.fromList([9, 9]),
            ),
          ),
        );
        await rig.known.add(_c1, peerUserId: _bob);
        final history = await rig.sealedSetting('messages.e2ee.keys.$_c1');
        // The server stored this device's own init; a welcome of that
        // generation is listed (the join code's own-init-already-stored path).
        rig.server.addCommit(
          _c1,
          const MlsPair(1, 0),
          pending.commit,
          fromUser: _me,
        );
        final w = rig.server.addWelcome(
          rig.device.deviceIdString,
          _c1,
          const MlsPair(1, 0),
          Uint8List(4),
        );

        expect(await rig.crypto.processWelcomes(), isEmpty);

        expect(rig.server.acks.expand((a) => a.ids), [w]);
        final g = (await groupOf())!;
        expect(g.provisional, isFalse);
        expect(g.pending, isNull);
        expect(
          rigEq(
            (await rig.sealedSetting('messages.e2ee.keys.$_c1'))!,
            history!,
          ),
          isTrue,
        );
        expect(rig.keyHistoryErrors, isEmpty);
        expect((await rig.keyHistoryIds(_c1)).keys, [vaultDeviceIdHex(bob.id)]);
        // The shared success steps ran here too: the row is the sender's now
        // (the same key and bytes, under the conversation id, without init).
        final row = (await rows()).single;
        expect(row.idempotencyKey, key);
        expect(row.conversationId, _c1);
        expect(row.recipientUserId, isNull);
        expect(row.init, isNull);
        expect(row.stage, OutboxStage.encrypted);
        expect(row.ciphertext, [1, 2, 3]);
        // No answer said ACCEPTED: nothing is inferred.
        expect(
          (await rig.device.vault.conversation(_c1))!.sync.requestAccepted,
          isFalse,
        );
      },
    );

    test('an own-init settle deletes a lower generation that was walked and '
        'kept', () async {
      final v = rig.device.vault;
      Future<void> seed(String id, {required bool walked}) => v.transaction((
        tx,
      ) async {
        await tx.putGroup(
          GroupRecord(
            conversationId: id,
            generation: 1,
            epoch: 3,
            state: rigBytes('the old generation'),
          ),
        );
        await tx.setAfterPair(id, const MlsPair(1, 2));
        await tx.putConversationSync(
          id,
          ConversationSync(
            completedEpochs: walked ? const [MlsPair(1, 3)] : const [],
          ),
        );
        await tx.putGroup(
          GroupRecord(
            conversationId: id,
            generation: 2,
            epoch: 1,
            state: rigBytes('a provisional state'),
            provisional: true,
            provisionalCreatedAtMicros: rig.clock.now().microsecondsSinceEpoch,
            pending: PendingCommit(
              kind: PendingKind.reset,
              builtOn: const MlsPair(2, 0),
              commit: rigBytes('this device reset'),
            ),
          ),
        );
      });
      await seed(_c1, walked: true);

      final settled = await rig.locks.run(
        _c1,
        () => rig.crypto.settleOwnInitLocked(_c1, 2),
      );

      expect(settled, InitSettle.settled);
      expect(await v.group(_c1, 1), isNull);
      expect((await v.group(_c1, 2))!.provisional, isFalse);
      final record = (await v.conversation(_c1))!;
      expect(record.afterPair, const MlsPair(2, 0));
      expect(record.sync.completedEpochs, isEmpty);
    });

    test(
      'an own-init settle walks an unwalked lower generation first',
      () async {
        // Generation 1, joined and not walked to its end.
        await joined(_c1, bob);
        final v = rig.device.vault;
        final reset = rigBytes('this device reset');
        await v.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 2,
              epoch: 1,
              state: rigBytes('a provisional state'),
              provisional: true,
              provisionalCreatedAtMicros: rig.clock
                  .now()
                  .microsecondsSinceEpoch,
              pending: PendingCommit(
                kind: PendingKind.reset,
                builtOn: const MlsPair(2, 0),
                commit: reset,
              ),
            ),
          ),
        );
        rig.server.addCommit(_c1, const MlsPair(2, 0), reset, fromUser: _me);
        rig.server.epochRequests.clear();

        final settled = await rig.locks.run(
          _c1,
          () => rig.crypto.settleOwnInitLocked(_c1, 2),
        );

        expect(settled, InitSettle.settled);
        // The old generation's last epoch was walked before it went.
        expect(rig.server.epochRequests.map((r) => r.pair), [
          const MlsPair(1, 1),
        ]);
        expect(await v.group(_c1, 1), isNull);
        expect((await v.group(_c1, 2))!.provisional, isFalse);
        expect((await v.conversation(_c1))!.afterPair, const MlsPair(2, 0));
      },
    );

    test(
      'discarding a provisional group leaves the key history untouched',
      () async {
        await rig.seedProvisional(_c1, [bob]);
        final history = await rig.sealedSetting('messages.e2ee.keys.$_c1');

        final discarded = await rig.locks.run(
          _c1,
          () => rig.crypto.discardProvisionalLocked(_c1, 1),
        );

        expect(discarded, isTrue);
        expect(await groupOf(), isNull);
        expect(await rig.device.vault.members(_c1), isEmpty);
        expect(
          rigEq(
            (await rig.sealedSetting('messages.e2ee.keys.$_c1'))!,
            history!,
          ),
          isTrue,
        );
        expect(await rig.device.vault.conversation(_c1), isNull);
      },
    );
  });
}
