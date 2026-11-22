import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart'
    show kMlsRpcTimeout;
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/former_pins.dart';
import 'package:dzeroth/features/messages/domain/e2ee/group_starter.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
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

/// Records the priority of every unit taken from the starter's budget.
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
  var publicIdsOff = false;
  String? ownId = _me;

  /// When set, a send that carries an init waits for it (the send is in
  /// flight, under the conversation lock).
  Completer<void>? gate;

  GroupStarter build({
    VaultSession? session,
    void Function(Duration delay, void Function() run)? schedule,
  }) => starter = GroupStarter(
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
    ownUserId: () => ownId,
    publicIdsOff: () => publicIdsOff,
    schedule:
        schedule ?? (delay, run) => rig.scheduled.add((delay: delay, run: run)),
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

  Future<void> newRig({
    RigEngine? engine,
    SyncBudget Function(RigClock clock)? syncBudget,
  }) async {
    rig = await RigCrypto.create(engine: engine, syncBudget: syncBudget);
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
    ownId = _me;
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
  const lostAnswer = (error: NetworkException('timed out'), stored: true);
  const keyReused = IdempotencyKeyReusedException('idempotency_key');

  /// Every `ListMessages` call fails from here on: neither the first page
  /// nor a live pull can answer for a message.
  void failListMessages() => rig.server.onCall = (call) async {
    if (call == 'listMlsMessages') throw const NetworkException('no network');
  };

  Future<bool> acceptedIn([String id = _c1]) async =>
      (await rig.device.vault.conversation(id))?.sync.requestAccepted ?? false;

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
      // Audit M2 (ii): the cache's conversation with bob is the real id.
      rig.server.rows.remove(_c1);
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

    test('a deferred list dated in the future is not used', () async {
      await rig.directory.own();
      await rig.directory.peer(_bob);
      // The device clock moved back by a day: the kept lists are dated in
      // the future, so their age cannot be told.
      rig.clock.advance(const Duration(days: -1));
      rig.keys.peerError = const RateLimitedException(
        'slow down',
        retryAfter: Duration(minutes: 1),
      );

      final r = await start();

      expect(r.result, StartResult.lookupFailed);
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rows(), isEmpty);
      expect(await groupOf(), isNull);
      expect(rig.server.sends, isEmpty);
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

  group('the claim\'s conversation is bound to its peer (Task 8 audit M2)', () {
    test('(i) a claim naming a conversation whose cached header names '
        'another peer is refused before the lock', () async {
      // The server answers bob's claim with _c2, the cached conversation
      // with carol (not in the known set: public ids on, so nothing else
      // could tell).
      rig.server.rows
        ..remove(_c1)
        ..[_c2] = header(_c2, 'ref-carol');
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c2,
        keyPackages: [await packageOf(bob)],
      );

      final r = await start();

      expect(r.result, StartResult.unavailable);
      expect(r.conversationId, isNull);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await rows(), isEmpty);
      expect(await groupOf(_c2), isNull);
      expect(rig.known.contains(_c2), isFalse);
      expect(rig.server.sends, isEmpty);
    });

    test('(ii) a claim naming another id than the cached conversation with '
        'this peer is refused before the lock', () async {
      // The cache holds _c1 as the conversation with bob; the claim names
      // _c2, of which nothing is cached.
      expect(rig.server.rows[_c1]!.peer.userId, _bob);
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c2,
        keyPackages: [await packageOf(bob)],
      );

      final r = await start();

      expect(r.result, StartResult.unavailable);
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await rows(), isEmpty);
      expect(await groupOf(_c2), isNull);
      expect(await groupOf(), isNull);
      expect(rig.server.sends, isEmpty);

      // The claim naming the cached id starts.
      person(_bob, _c1, [bob]);
      expect((await start()).result, StartResult.started);
      await done();
    });

    test('(iii) a known id whose stored ref is of the same id kind and '
        'another peer is refused when routed to; a ref of the other kind is '
        'not compared', () async {
      await rig.known.add(_c2, peerUserId: 'ref-carol');

      var r = await start(conversationId: _c2);

      expect(r.result, StartResult.unavailable);
      expect(r.conversationId, isNull);
      expect(await rows(), isEmpty);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.sends, isEmpty);

      // A stored ref that is a public id cannot be compared with a raw uid
      // (audit L8, id-kind drift): the row goes to the known conversation
      // as before, never plaintext.
      const publicRef = 'u0123456789abcdefghjkmnpqrs';
      expect(publicRef, hasLength(27));
      await rig.known.add(_c3, peerUserId: publicRef);
      r = await start(conversationId: _c3);
      expect(r.result, StartResult.joinedExisting);
      expect(r.conversationId, _c3);
      expect(rig.keys.claimCalls, isEmpty);
    });

    test('a conversation another peer\'s routing commits while this routing '
        'claims is refused under the lock, even for a draft addressed by its '
        'id (pre-flag-on audit M-A)', () async {
      // _c1 is the thread with bob (Q). A hostile server answers carol's
      // (P's) claim with _c1 too; the cache holds no header for _c1, so the
      // checks before the lock cannot tell.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c1, [carol]);
      rig.server.rows.remove(_c1);
      await sibling('sib');
      // Bob's routing holds at its own-device claim.
      final own = rig.keys.claims[_me]!;
      final hold = Completer<void>();
      var ownClaims = 0;
      rig.keys.claims[_me] = () async {
        if (ownClaims++ == 0) await hold.future;
        return own();
      };

      final q = start(localId: 'local-q', conversationId: _c1, text: 'to bob');
      await pumpEventQueue();
      expect(rig.keys.claimCalls.map((c) => c.userId), [_bob, _me]);
      // Carol's routing commits _c1 meanwhile, stored as carol's.
      final p = await start(localId: 'local-p', peer: 'ref-carol');
      expect(p.result, StartResult.started);
      expect(p.conversationId, _c1);
      expect(rig.known.peerOf(_c1), 'ref-carol');
      hold.complete();
      final r = await q;
      await done();

      expect(r.result, StartResult.unavailable);
      expect(r.conversationId, isNull);
      // Bob's text was never saved into _c1, and only carol's init went
      // out.
      expect((await rows()).where((x) => x.localId == 'local-q'), isEmpty);
      expect(rig.server.sends, hasLength(1));
      expect(inits(), hasLength(1));
    });

    test('a cache that comes to disagree while this routing claims refuses '
        'under the lock (pre-flag-on audit M-A)', () async {
      rig.server.rows.remove(_c1);
      await sibling('sib');
      final own = rig.keys.claims[_me]!;
      rig.keys.claims[_me] = () async {
        // While the own-device claim is in flight the cache learns that _c1
        // is the conversation with carol.
        rig.server.rows[_c1] = header(_c1, 'ref-carol');
        return own();
      };

      final r = await start(conversationId: _c1);

      expect(r.result, StartResult.unavailable);
      expect(await rows(), isEmpty);
      expect(await groupOf(), isNull);
      expect(rig.known.contains(_c1), isFalse);
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

    test('with public ids off and the own uid not known, the start is '
        'refused before any claim (code review M5)', () async {
      publicIdsOff = true;
      person(_bob, dmConversationId(_me, _bob), [bob]);
      // Audit M2 (ii): the cache's conversation with bob is the real id.
      rig.server.rows.remove(_c1);
      for (final unknownId in [null, '']) {
        ownId = unknownId;
        final r = await start();
        expect(r.result, StartResult.unavailable, reason: '"$unknownId"');
        expect(rig.keys.claimCalls, isEmpty, reason: '"$unknownId"');
        expect(await rows(), isEmpty);
      }
      expect(rig.server.sends, isEmpty);

      // Known again: the same start is made.
      ownId = _me;
      final r = await start();
      expect(r.result, StartResult.started);
      await done(dmConversationId(_me, _bob));
    });

    test('two concurrent starts for the same peer share one run: one claim '
        'set and one init (audit L2)', () async {
      final sib = await sibling('sibling');
      final hold = Completer<void>();
      final answer = rig.keys.claims[_bob]!;
      rig.keys.claims[_bob] = () async {
        await hold.future;
        return answer();
      };

      final first = start();
      final second = start(localId: 'local-2', text: 'second');
      await pumpEventQueue();
      // The first is claiming; the second waits for it.
      expect(rig.keys.claimCalls, hasLength(1));
      hold.complete();
      final r1 = await first;
      final r2 = await second;
      await done();

      expect(r1.result, StartResult.started);
      expect(r2.result, StartResult.joinedExisting);
      expect(r2.conversationId, _c1);
      // One claim for bob, one for the own sibling: one claim set.
      expect(rig.keys.claimCalls.map((c) => c.userId), [_bob, _me]);
      expect(inits(), hasLength(1));
      expect((await groupOf())!.provisional, isFalse);
      final init = pb.MlsInit.fromBuffer(inits().single.mlsInit!);
      expect(init.welcomeDeviceIds, [bob.idString, sib.idString]);
      // Both messages went out, in the order typed.
      expect(await rows(), isEmpty);
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends.last.mlsInit, isNull);
    });

    test('a failed claim for the own devices still starts, with the peer\'s '
        'devices only (code review M7)', () async {
      final sib = await sibling('sibling');
      rig.keys.claimErrors[_me] = const NetworkException('no network');

      final r = await start();
      expect(r.result, StartResult.started);
      await done();

      // Both claims were made; the own one failed.
      expect(rig.keys.claimCalls.map((c) => c.userId), [_bob, _me]);
      expect(
        rig.keys.claimCalls.last.excludeDeviceId,
        rig.device.deviceIdString,
      );
      final init = pb.MlsInit.fromBuffer(inits().single.mlsInit!);
      expect(init.welcomeDeviceIds, [bob.idString]);
      final members = await rig.device.vault.members(_c1);
      expect(members, hasLength(2));
      expect(members.any((m) => rigEq(m.deviceId, sib.id)), isFalse);
      expect(
        members.singleWhere((m) => rigEq(m.deviceId, bob.id)).side,
        MemberSide.theirs,
      );
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
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

    test('the scheduled resend of a user\'s start runs at live, never at '
        'user: a timer is no user intent (Task 9 review m-4)', () async {
      await rig.dispose();
      late _SpyBudget budget;
      await newRig(syncBudget: (clock) => budget = _SpyBudget(clock));
      rig.server.sendScript.add((
        error: const ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(seconds: 5),
        ),
        stored: false,
      ));
      await start();
      await done();
      expect(rig.scheduled.single.delay, const Duration(seconds: 5));

      // The resend is refused: as a retry it asks the stored commits
      // first, with a unit of the resend's own priority.
      rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      budget.taken.clear();
      rig.clock.advance(const Duration(seconds: 5));
      rig.scheduled.single.run();
      await done();

      expect(rig.server.sends, hasLength(2));
      expect(budget.taken, isNotEmpty);
      expect(budget.taken.first, BudgetPriority.live);
      expect(budget.taken, isNot(contains(BudgetPriority.user)));
    });

    test('an unknown outcome with a server retry time schedules exactly one '
        'resend, and a trigger before that time sends nothing (code review '
        'M6)', () async {
      const busy = (
        error: ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(seconds: 5),
        ),
        stored: false,
      );
      rig.server.sendScript.add(busy);
      await start();
      await done();

      // Not resent at once: the server named a time.
      expect(rig.server.sends, hasLength(1));
      expect(rig.scheduled.single.delay, const Duration(seconds: 5));
      expect((await groupOf())!.provisional, isTrue);

      // Triggers before that time send nothing and schedule nothing.
      await starter.resumeProvisional();
      await done();
      await starter.retryStart('local-1');
      await done();
      rig.clock.advance(const Duration(seconds: 4));
      await starter.resumeProvisional();
      await done();
      expect(rig.server.sends, hasLength(1));
      expect(rig.scheduled, hasLength(1));

      // The one scheduled resend, at the server's time: the identical
      // request. Unanswered again, it schedules no second one.
      rig.clock.advance(const Duration(seconds: 1));
      rig.server.sendScript.add(busy);
      rig.scheduled.single.run();
      await done();
      expect(rig.server.sends, hasLength(2));
      expect(rig.server.sends[0].same(rig.server.sends[1]), isTrue);
      expect(rig.scheduled, hasLength(1));
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.init, isNotNull);

      // A later trigger, after the new time, makes one attempt.
      await starter.resumeProvisional();
      await done();
      expect(rig.server.sends, hasLength(2));
      rig.clock.advance(const Duration(seconds: 5));
      await starter.resumeProvisional();
      await done();
      expect(rig.server.sends, hasLength(3));
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
      // answered STALE_EPOCH all the same (scripted: the real server
      // replays a stored message for good, ahead of STALE_EPOCH; the
      // starter must not rely on that to keep the group).
      rig.server.sendScript.addAll([
        lostAnswer,
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
      // The first ListMessages page held the message: settled with it.
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );

      // A refusal on a retry, with the stored message not on the first
      // ListMessages page (50 newer messages): the commit check keeps the
      // group, and nothing is settled without the message's answer.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      rig.server.sendScript.addAll([
        lostAnswer,
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
      expect((await groupOf(_c2))!.provisional, isTrue);
      expect(await rig.device.vault.members(_c2), hasLength(2));
      final kept = (await rows()).single;
      expect(kept.init, isNotNull);
      expect(kept.lastError, isNull);

      // The next trigger sends the identical request and the server replays
      // the stored message.
      final sent = rig.server.sends.length;
      await starter.resumeProvisional();
      await done(_c2);
      expect(rig.server.sends, hasLength(sent + 1));
      expect(rig.server.sends.last.mlsInit, isNotNull);
      expect(rig.server.sends.last.key, kept.idempotencyKey);
      expect((await groupOf(_c2))!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c2, kept.expectedMessageId),
        isTrue,
      );
    });

    test('an init the commits show stored, with its answer lost and no '
        'readable page, keeps its init and is replayed: never sent without '
        'it, never failed (review W1)', () async {
      // The first attempt was stored and its answer lost; the retry is
      // refused before the server's replay lookup. ListMessages fails, so
      // neither the first page nor a live pull answers for the message.
      rig.server.sendScript.addAll([
        lostAnswer,
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      failListMessages();
      await start();
      await done();

      final row = (await rows()).single;
      expect((await groupOf())!.provisional, isTrue);
      expect(row.init, isNotNull);
      expect(row.stage, OutboxStage.encrypted);
      expect(row.recipientUserId, _bob);
      expect(row.lastError, isNull);
      // The sender sends nothing of it: its key never goes out without the
      // init (the server would answer VALIDATION idempotency_key).
      await rig.sender.drain(_c1);
      await done();
      expect(rig.server.sends, hasLength(2));
      expect(inits(), hasLength(2));

      // A later trigger sends the identical request; the server replays the
      // stored message and the group settles WITH its answer.
      await starter.resumeProvisional();
      await done();

      expect(rig.server.sends, hasLength(3));
      expect(inits(), hasLength(3));
      expect(rig.server.sends[0].same(rig.server.sends[2]), isTrue);
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
      expect(await acceptedIn(), isTrue);
    });

    test('VALIDATION idempotency_key for an init row means "stored": the row '
        'never fails and the group is never discarded (review W1)', () async {
      // (1) The first page holds the message with the row's bytes: the
      // group settles with that answer.
      rig.server.sendScript.add((error: keyReused, stored: true));
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();

      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
      expect(await acceptedIn(), isTrue);

      // (2) The page does not hold it: nothing is decided, a live pull
      // runs, and the row keeps its init for the next trigger.
      final carol = await RigPeer.create('carol');
      person('ref-carol', _c2, [carol]);
      rig.server.sendScript.add((error: keyReused, stored: false));
      rig.server.calls.clear();
      await start(localId: 'local-2', peer: 'ref-carol');
      await done(_c2);

      expect((await groupOf(_c2))!.provisional, isTrue);
      expect(await rig.device.vault.members(_c2), hasLength(2));
      final kept = (await rows()).single;
      expect(kept.init, isNotNull);
      expect(kept.stage, OutboxStage.encrypted);
      expect(kept.lastError, isNull);
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages').length,
        greaterThan(1),
        reason: 'the first page, then the live pull',
      );
      expect(await rig.sender.outgoing(_c2), isEmpty);
    });

    // Task 9 concern 1, changed on purpose: this test was Task 8's "a
    // refused retry is decided at once". The first attempt's outcome is
    // unknown, so its request may still reach the server until
    // [kInitResendMargin] after it started; the refusal of the retry right
    // after it decides nothing. After the margin the same refusal does.
    test(
      'FEATURE_DISABLED on a retry without it is a refusal once the '
      'margin after the unknown attempt has passed (Task 9 concern 1)',
      () async {
        rig.server.sendScript.addAll([
          unknown,
          (error: const FeatureDisabledException('off'), stored: false),
        ]);

        await start();
        await done();

        expect(rig.server.sends, hasLength(2));
        expect((await groupOf())!.provisional, isTrue);
        expect(await rig.device.vault.members(_c1), hasLength(2));
        var row = (await rows()).single;
        expect(row.stage, OutboxStage.encrypted);
        expect(row.init, isNotNull);
        expect(row.lastError, isNull);
        // One resume, at the margin's end after the unknown attempt started.
        expect(rig.scheduled.map((s) => s.delay), [kInitResendMargin]);

        rig.clock.advance(kInitResendMargin);
        rig.server.sendScript.add((
          error: const FeatureDisabledException('off'),
          stored: false,
        ));
        rig.scheduled.single.run();
        await done();

        expect(rig.server.sends, hasLength(3));
        expect(rig.server.sends[0].same(rig.server.sends[2]), isTrue);
        expect(await groupOf(), isNull);
        expect(await rig.device.vault.members(_c1), isEmpty);
        row = (await rows()).single;
        expect(row.stage, OutboxStage.plain);
        expect(row.lastError, 'FeatureDisabledException');
        expect(row.init, isNull);
      },
    );

    test('a refusal or a STALE_EPOCH right after an attempt with an unknown '
        'outcome deletes nothing inside the margin; after it the record '
        'decides (Task 9 concern 1)', () async {
      // The first call takes 10 s, so the automatic second try (also
      // unknown) starts 10 s after it; the refusal comes 40 s after that
      // second try started. The margin counts from the LAST start.
      var sent = 0;
      rig.server.beforeSend = (send) async {
        sent++;
        if (sent == 1) rig.clock.advance(const Duration(seconds: 10));
      };
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect(rig.server.sends, hasLength(2));
      rig.scheduled.clear();

      rig.clock.advance(const Duration(seconds: 40));
      const stale = (
        error: StaleEpochException(
          'stale',
          generation: 1,
          epoch: 1,
          conversationId: _c1,
        ),
        stored: false,
      );
      rig.server.sendScript.add(stale);
      await starter.resumeProvisional();
      await done();
      // Inside the margin after the second (unknown) try: kept, no join.
      expect(rig.server.sends, hasLength(3));
      expect(rig.server.calls, contains('listConversationCommits'));
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.init, isNotNull);
      expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
      expect(rig.scheduled.map((s) => s.delay), [
        kInitResendMargin - const Duration(seconds: 40),
      ]);

      // At the margin's end the record decides: nothing stored, refused.
      rig.clock.advance(kInitResendMargin - const Duration(seconds: 40));
      rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      rig.scheduled.single.run();
      await done();
      expect(rig.server.sends, hasLength(4));
      expect(await groupOf(), isNull);
      expect((await rows()).single.lastError, 'FeatureDisabledException');
    });

    test('a margin that ends while the commit listing runs arms a resume '
        'that fires while its resume still runs; it runs after that one and '
        'decides with no other trigger (pre-flag-on review m-1)', () async {
      // A timer with no wait fires at once here: while the resume that
      // armed it still holds its single-flight slot, as a real zero-wait
      // timer can.
      final armed = <Duration>[];
      build(
        schedule: (delay, run) {
          rig.scheduled.add((delay: delay, run: run));
          if (delay == Duration.zero) {
            armed.add(delay);
            run();
          }
        },
      );
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect(rig.server.sends, hasLength(2));
      rig.scheduled.clear();

      // The refusal comes 1 s before the margin's end; its listing takes
      // 2 s, so the margin ends while it runs: the "not stored" read
      // decides nothing and one resume is armed with no wait.
      rig.clock.advance(kInitResendMargin - const Duration(seconds: 1));
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') {
          rig.clock.advance(const Duration(seconds: 2));
        }
      };
      rig.server.sendScript.addAll([
        (error: const FeatureDisabledException('off'), stored: false),
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      await starter.resumeProvisional();
      await done();
      await pumpEventQueue();
      await done();

      expect(armed, [Duration.zero]);
      // The armed resume asked again after the first one ended: the same
      // request, refused, and the record now decides.
      expect(rig.server.sends, hasLength(4));
      expect(rig.server.sends[0].same(rig.server.sends[3]), isTrue);
      expect(await groupOf(), isNull);
      expect((await rows()).single.lastError, 'FeatureDisabledException');
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

    test('no new start while an after-pair shows this device was a '
        'member', () async {
      await refusedOnce();
      await rig.device.vault.transaction(
        (tx) => tx.setAfterPair(_c1, const MlsPair(1, 0)),
      );
      final record = (await rig.device.vault.conversation(_c1))!;
      expect(record.afterPair, const MlsPair(1, 0));
      expect(record.joinHighWater, isNull);
      await expectNoNewStart();
    });

    test('no new start while a group of any generation is stored', () async {
      await refusedOnce();
      await discardFailed();
      // A final group with the peer ref stored and no mark, no first-saw
      // generation and no former pins: only the group says "a member".
      final v = rig.device.vault;
      final state = await rig.device.engine.inner.createGroup(
        (await v.deviceState())!,
        mlsGroupId(_c1, 2),
      );
      await v.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 2,
            epoch: 0,
            state: state,
          ),
        ),
      );
      final record = await v.conversation(_c1);
      expect(record?.afterPair, isNull);
      expect(record?.joinHighWater, isNull);
      expect(record?.sync.firstSawGeneration, isNull);
      expect(await const FormerPins().of(v, _c1), isEmpty);

      final r = await start(localId: 'local-2', text: 'second');
      expect(r.result, StartResult.joinedExisting);
      await done();
      await starter.retryStart('local-2');
      await done();

      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      expect((await v.groups(_c1)).single.generation, 2);
      expect(inits(), hasLength(1));
    });

    test('a mark written while the claim is in flight stops the new start '
        '(read again in the creating body)', () async {
      await refusedOnce();
      final answer = rig.keys.claims[_bob]!;
      rig.keys.claims[_bob] = () async {
        // A welcome of another device's group is joined meanwhile: this
        // device is a member now.
        await rig.device.vault.transaction(
          (tx) => tx.setJoinHighWater(_c1, const MlsPair(1, 0)),
        );
        return answer();
      };

      await starter.retryStart('local-1');
      await done();

      // The pre-check passed (the claim was made); the body refused.
      expect(rig.keys.claimCalls, hasLength(1));
      expect(await groupOf(), isNull);
      expect(await rig.device.vault.members(_c1), isEmpty);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.init, isNull);
      expect(row.lastError, 'RateLimitedException');
      expect(rig.server.sends, hasLength(1));
    });

    test('a new send at the per-target claim cap fails its row with '
        'tryTomorrow', () async {
      await refusedOnce();
      await discardFailed();
      rig.keys.claimErrors[_bob] = cap;

      final r = await start(localId: 'local-2', text: 'second');
      expect(r.result, StartResult.joinedExisting);
      await done();

      expect(rig.keys.claimCalls, hasLength(1));
      expect(await groupOf(), isNull);
      final row = (await rows()).single;
      expect(row.localId, 'local-2');
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, 'RateLimitedException');
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.tryTomorrow, isTrue);
      expect(shown.error, isA<RateLimitedException>());
      expect(rig.server.sends, hasLength(1));
    });

    test('a new send whose start cannot be made fails its row, retryable, '
        'instead of leaving it waiting with no reason (review W2)', () async {
      await refusedOnce();
      await discardFailed();

      // (1) The peer's list cannot be read: lookupFailed.
      rig.keys.peerFails = true;
      var r = await start(localId: 'local-2', text: 'second');
      expect(r.result, StartResult.joinedExisting);
      await done();
      expect(await groupOf(), isNull);
      var row = (await rows()).single;
      expect(row.localId, 'local-2');
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, kStartErrorLookupFailed);
      var shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(shown.error, isNull);
      rig.keys.peerFails = false;
      await rig.sender.discard('local-2');

      // (2) A claim that fails with a typed error: its name, and the typed
      // error is remembered.
      rig.keys.claimErrors[_bob] = const FeatureDisabledException('off');
      r = await start(localId: 'local-3', text: 'third');
      expect(r.result, StartResult.joinedExisting);
      await done();
      row = (await rows()).single;
      expect(row.lastError, 'FeatureDisabledException');
      shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.error, isA<FeatureDisabledException>());
      rig.keys.claimErrors.clear();
      await rig.sender.discard('local-3');

      // (3) The claim names another conversation: unavailable.
      final answer = rig.keys.claims[_bob]!;
      rig.keys.claims[_bob] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c2,
        keyPackages: [await packageOf(bob)],
      );
      r = await start(localId: 'local-4', text: 'fourth');
      expect(r.result, StartResult.joinedExisting);
      await done();
      row = (await rows()).single;
      expect(row.lastError, kStartErrorUnavailable);
      shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(await groupOf(), isNull);
      expect(await groupOf(_c2), isNull);

      // The user's retry of that row starts once the start can be made.
      rig.keys.claims[_bob] = answer;
      await starter.retryStart('local-4');
      await done();
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
    });

    test('the retry of a waiting head row whose start cannot be made fails '
        'the row, retryable (review W2)', () async {
      await refusedOnce();
      await discardFailed();
      // A row saved while nothing may start (the flag is not on): the head
      // row, waiting, not failed.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me);
      await start(localId: 'local-2', text: 'second');
      await done();
      await rig.device.session.onFlagChanged(E2eeFlag.on, uid: _me);
      expect((await rows()).single.lastError, isNull);
      // The peer lists no device now.
      rig.keys.peers[_bob] = [];

      await starter.retryStart('local-2');
      await done();

      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, kStartErrorPeerHasNoDevice);
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(shown.error, isNull);

      // The peer has a device again: the retry starts.
      person(_bob, _c1, [bob]);
      await starter.retryStart('local-2');
      await done();
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
    });

    test('a retry whose read of the outbox fails leaves the row as it is: '
        'the sender\'s retry does not clear its failure (audit L3)', () async {
      await refusedOnce();
      // The starter's read fails once (the vault's cipher, a lost lock).
      var failed = false;
      rig.device.onOutbox = () async {
        if (!failed) {
          failed = true;
          throw StateError('the read failed');
        }
      };

      await starter.retryStart('local-1');
      await done();

      expect(failed, isTrue);
      expect(rig.keys.claimCalls, isEmpty);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain);
      expect(row.lastError, 'RateLimitedException');
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect(shown.retryable, isTrue);
      expect(shown.error, isA<RateLimitedException>());
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

    test('no new start for another peer than the stored peer ref, and '
        '(audit M2 iii) no row for that peer either', () async {
      await refusedOnce();
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-carol'] = [rigKeyDevice(carol.idString, carol.key)];
      await discardFailed();
      // Audit M2 (iii), a behaviour change: the stored ref of _c1 is bob's,
      // of the same id kind, so a send for carol into _c1 is refused; it
      // used to be enqueued there and wait (encrypted to bob's devices).
      final r = await start(
        localId: 'local-2',
        peer: 'ref-carol',
        conversationId: _c1,
        text: 'second',
      );
      expect(r.result, StartResult.unavailable);
      expect(r.conversationId, isNull);
      await done();
      expect(rig.keys.claimCalls, isEmpty);
      expect(await groupOf(), isNull);
      expect(await rows(), isEmpty);
      expect(rig.server.sends, hasLength(1));
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

    test(
      'the retry of an init row resumes its own conversation only, for a '
      'recipient-addressed and an id-addressed row (code review M3)',
      () async {
        final carol = await RigPeer.create('carol');
        person('ref-carol', _c2, [carol]);
        rig.server.sendScript.addAll([unknown, unknown, unknown, unknown]);
        await start();
        await done();
        await start(localId: 'local-2', peer: 'ref-carol', conversationId: _c2);
        await done(_c2);
        final first = (await rows()).firstWhere((r) => r.localId == 'local-1');
        final second = (await rows()).firstWhere((r) => r.localId == 'local-2');
        expect(first.recipientUserId, _bob);
        expect(second.conversationId, _c2);
        expect(rig.server.sends, hasLength(4));

        // The retry of bob's row: carol's init is not sent.
        await starter.retryStart('local-1');
        await done();
        await done(_c2);
        expect(rig.server.sends, hasLength(5));
        expect(rig.server.sends.last.key, first.idempotencyKey);
        expect((await groupOf())!.provisional, isFalse);
        expect((await groupOf(_c2))!.provisional, isTrue);

        // The retry of carol's row.
        await starter.retryStart('local-2');
        await done(_c2);
        expect(rig.server.sends, hasLength(6));
        expect(rig.server.sends.last.key, second.idempotencyKey);
        expect((await groupOf(_c2))!.provisional, isFalse);
        expect(await rows(), isEmpty);
      },
    );

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

      // (c) The app restarts in between; the next resume starts again,
      // once [kRebuildSpacing] has passed since the rebuild in (a) (audit
      // L1, a behaviour change: it used to start two minutes later).
      await rig.restart();
      build();
      rig.clock.advance(kRebuildSpacing);
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

    /// An expired provisional group whose server's first commit is another
    /// device's init: the next resume rebuilds it. The rig's clock is set to
    /// 06:00 UTC (11:30 IST) of its own day, so no test crosses an IST day
    /// (the real clock is never compared with it).
    Future<({GroupRecord group, OutboxItem row})> expiredLost() async {
      final day = rig.clock.now();
      rig.clock.value = DateTime.utc(day.year, day.month, day.day, 6);
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      final state = (group: (await groupOf())!, row: (await rows()).single);
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 0),
        rigBytes('the init of another device'),
        fromUser: 'user-b',
      );
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      rig.keys.claimCalls.clear();
      return state;
    }

    Future<void> expectOld(
      ({GroupRecord group, OutboxItem row}) old,
      String why,
    ) async {
      final g = (await groupOf())!;
      expect(g.provisional, isTrue, reason: why);
      expect(
        rigEq(g.pending!.commit, old.group.pending!.commit),
        isTrue,
        reason: why,
      );
      final row = (await rows()).single;
      expect(row.idempotencyKey, old.row.idempotencyKey, reason: why);
      expect(row.init, isNotNull, reason: why);
      expect(row.lastError, isNull, reason: why);
    }

    test('a rebuild the key history would refuse makes no claim and no '
        'lookup (audit L1)', () async {
      final old = await expiredLost();
      // The key history no longer opens: the creating body would refuse.
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          'messages.e2ee.keys.$_c1',
          Uint8List.fromList([1, 2, 3]),
        ),
      );
      final gets = rig.keys.getCalls.length;
      final lists = rig.keys.listCalls;

      await starter.resumeProvisional();
      await done();

      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.keys.getCalls, hasLength(gets));
      expect(rig.keys.listCalls, lists);
      await expectOld(old, 'an unreadable history');
      expect(rig.keyHistoryErrors, ['keyHistory.read']);
      rig.unexpected.clear();
    });

    test('one rebuild per group per hour, kept across a restart (audit '
        'L1)', () async {
      final old = await expiredLost();
      // The first rebuild claims; its replace is refused (the commits
      // cannot be listed again under the lock), so the group stays.
      var listings = 0;
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits' && ++listings == 2) {
          throw const NetworkException('no network');
        }
      };
      await starter.resumeProvisional();
      await done();
      rig.server.onCall = null;
      expect(listings, 2);
      expect(rig.keys.claimCalls, hasLength(1));
      await expectOld(old, 'the replace was refused');

      // Within the hour: the expiry asks the commits, and nothing is
      // claimed. A restart does not reopen it.
      rig.clock.advance(const Duration(minutes: 30));
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(1));
      await rig.restart();
      build();
      rig.clock.advance(const Duration(minutes: 29));
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(1));
      await expectOld(old, 'within the hour');

      // An hour after the first rebuild: the next one is made.
      rig.clock.advance(const Duration(minutes: 1));
      rig.server.sendScript.addAll([unknown, unknown]);
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(2));
      final rebuilt = (await groupOf())!;
      expect(rebuilt.provisional, isTrue);
      expect(
        rebuilt.provisionalCreatedAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      expect(
        (await rows()).single.idempotencyKey,
        isNot(old.row.idempotencyKey),
      );
    });
  });

  group('the replace guard of the 24 h rebuild (review N6)', () {
    test('a provisional group that changed while the rebuild claimed is not '
        'replaced, and its row stays', () async {
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
      final answer = rig.keys.claims[_bob]!;
      Future<void> Function() during = () async {};
      rig.keys.claims[_bob] = () async {
        await during();
        return answer();
      };

      Future<void> expectRowUntouched(String why) async {
        final row = (await rows()).single;
        expect(row.idempotencyKey, oldRow.idempotencyKey, reason: why);
        expect(row.init, isNotNull, reason: why);
        expect(row.stage, OutboxStage.encrypted, reason: why);
        expect(row.lastError, isNull, reason: why);
        expect(await rig.device.vault.members(_c1), hasLength(2), reason: why);
      }

      // (1) While the claim is in flight the group is replaced by another
      // provisional init (other commit bytes).
      final other = rigBytes('another init of this device');
      during = () => rig.device.vault.transaction(
        (tx) => tx.putGroup(
          GroupRecord(
            conversationId: _c1,
            generation: 1,
            epoch: 1,
            state: old.state,
            provisional: true,
            provisionalCreatedAtMicros: old.provisionalCreatedAtMicros,
            pending: PendingCommit(
              kind: PendingKind.init,
              builtOn: const MlsPair(1, 0),
              commit: other,
              welcome: old.pending!.welcome,
              welcomeDeviceIds: old.pending!.welcomeDeviceIds,
            ),
          ),
        ),
      );
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(1));
      var g = (await groupOf())!;
      expect(g.provisional, isTrue);
      expect(rigEq(g.pending!.commit, other), isTrue);
      expect(g.provisionalCreatedAtMicros, old.provisionalCreatedAtMicros);
      await expectRowUntouched('replaced meanwhile');

      // (2) While the next rebuild's claim is in flight the group is
      // settled (made final). That rebuild is made once [kRebuildSpacing]
      // has passed (audit L1).
      rig.clock.advance(kRebuildSpacing);
      during = () => rig.device.vault.transaction(
        (tx) => tx.clearProvisional(_c1, 1, afterPair: const MlsPair(1, 0)),
      );
      await starter.resumeProvisional();
      await done();
      expect(rig.keys.claimCalls, hasLength(2));
      g = (await groupOf())!;
      expect(g.provisional, isFalse);
      expect(rigEq(g.state, old.state), isTrue);
      await expectRowUntouched('settled meanwhile');
      expect(rig.server.sends, hasLength(2));
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

    test('a failed row that becomes an init row again loses the error this '
        'run remembered for it (review F3)', () async {
      // The first init is refused at a daily limit: the typed error is
      // remembered and shown.
      rig.server.sendScript.add((
        error: const RateLimitedException('daily', limitName: 'dm_sends_daily'),
        stored: false,
      ));
      await start();
      await done();
      var shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.error, isA<RateLimitedException>());
      expect(shown.tryTomorrow, isTrue);

      // The user's retry starts again: the row is an init row once more.
      rig.server.sendScript.addAll([unknown, unknown]);
      await starter.retryStart('local-1');
      await done();
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.init, isNotNull);

      // 24 h later the rebuild finds no device, in the same run.
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      rig.keys.peers[_bob] = [];
      await starter.resumeProvisional();
      await done();

      shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed);
      expect((await rows()).single.lastError, kStartErrorPeerHasNoDevice);
      // Not the daily limit of the day before.
      expect(shown.error, isNull);
      expect(shown.tryTomorrow, isFalse);
      expect(shown.retryable, isTrue);
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

  group('a delete asks the stored commits again (audit M3, review F2)', () {
    /// An unanswered init of a group now older than 24 h; nothing stored
    /// at the server.
    Future<({GroupRecord group, OutboxItem row})> expired() async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      final state = (group: (await groupOf())!, row: (await rows()).single);
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      rig.keys.claimCalls.clear();
      return state;
    }

    /// The server stores this device's init now (a request it took long
    /// over): from here on the first stored commit is this init.
    void storeOwnInit(GroupRecord group) => rig.server.addCommit(
      _c1,
      const MlsPair(1, 0),
      group.pending!.commit,
      fromUser: _me,
    );

    Future<void> expectKept(
      ({GroupRecord group, OutboxItem row}) old,
      String why,
    ) async {
      final g = (await groupOf())!;
      expect(g.provisional, isTrue, reason: why);
      expect(
        rigEq(g.pending!.commit, old.group.pending!.commit),
        isTrue,
        reason: why,
      );
      expect(
        g.provisionalCreatedAtMicros,
        old.group.provisionalCreatedAtMicros,
        reason: why,
      );
      expect(await rig.device.vault.members(_c1), hasLength(2), reason: why);
      final row = (await rows()).single;
      expect(row.idempotencyKey, old.row.idempotencyKey, reason: why);
      expect(row.init, isNotNull, reason: why);
      expect(row.stage, OutboxStage.encrypted, reason: why);
      expect(row.lastError, isNull, reason: why);
    }

    test('the discard for a peer with no device is not made when the init '
        'was stored while the lookups ran', () async {
      final old = await expired();
      rig.keys.peers[_bob] = [];
      var stored = false;
      rig.keys.onGet = () async {
        if (!stored) storeOwnInit(old.group);
        stored = true;
      };

      await starter.resumeProvisional();
      await done();

      expect(stored, isTrue);
      await expectKept(old, 'stored during the lookup');
    });

    test('the discard at the claim cap is not made when the init was stored '
        'while the lookups ran', () async {
      final old = await expired();
      rig.keys.claimErrors[_bob] = const RateLimitedException(
        'cap',
        limitName: 'keys_claims_per_target_daily',
      );
      var stored = false;
      rig.keys.onGet = () async {
        if (!stored) storeOwnInit(old.group);
        stored = true;
      };

      await starter.resumeProvisional();
      await done();

      expect(rig.keys.claimCalls, hasLength(1));
      await expectKept(old, 'stored before the cap answer');
    });

    test('neither discard is made while the commits cannot be asked', () async {
      final old = await expired();
      rig.keys.peers[_bob] = [];
      // The first listing (the expiry's) answers; the one before the
      // discard fails.
      var listings = 0;
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits' && ++listings > 1) {
          throw const NetworkException('no network');
        }
      };

      await starter.resumeProvisional();
      await done();

      expect(listings, 2);
      await expectKept(old, 'the commits did not answer');
    });

    test('expiry with the commit listing failing changes nothing and claims '
        'nothing (review W3)', () async {
      final old = await expired();
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') {
          throw const NetworkException('no network');
        }
      };

      await starter.resumeProvisional();
      await done();

      expect(rig.server.calls.last, 'listConversationCommits');
      await expectKept(old, 'the listing failed');
      expect((await rows()).single.attempts, old.row.attempts);
      expect(rig.keys.claimCalls, isEmpty);
      expect(rig.server.sends, hasLength(2));
    });

    test('expiry with the sync budget paused changes nothing, calls nothing '
        'and claims nothing (review W3)', () async {
      final old = await expired();
      rig.syncBudget.pauseUntil(
        rig.clock.now().add(const Duration(minutes: 1)),
      );
      expect(rig.syncBudget.paused, isTrue);
      rig.server.calls.clear();

      await starter.resumeProvisional();
      await done();

      expect(rig.server.calls, isEmpty);
      await expectKept(old, 'the budget is paused');
      expect((await rows()).single.attempts, old.row.attempts);
      expect(rig.keys.claimCalls, isEmpty);
    });

    test('a refusal of a retry with the commit listing failing deletes '
        'nothing, fails nothing and claims nothing (review W3)', () async {
      // The first attempt's outcome is unknown; the retry is refused, and
      // the commits that would say whether the init is stored cannot be
      // listed.
      rig.server.sendScript.addAll([
        unknown,
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') {
          throw const NetworkException('no network');
        }
      };
      gate = Completer<void>();
      await start();
      final old = (group: (await groupOf())!, row: (await rows()).single);
      rig.keys.claimCalls.clear();
      gate!.complete();
      await done();

      expect(rig.server.sends, hasLength(2));
      expect(rig.server.calls, contains('listConversationCommits'));
      await expectKept(old, 'the listing failed after a refusal');
      expect(rig.keys.claimCalls, isEmpty);
      expect(await rig.sender.outgoing(_c1), isEmpty);
      expect(await starter.pendingInit(conversationId: _c1), isNotNull);

      // The same after a STALE_EPOCH on a retry.
      rig.server.sendScript.add((
        error: const StaleEpochException(
          'stale',
          generation: 1,
          epoch: 1,
          conversationId: _c1,
        ),
        stored: false,
      ));
      await starter.resumeProvisional();
      await done();
      expect(rig.server.sends, hasLength(3));
      await expectKept(old, 'the listing failed after STALE_EPOCH');
      expect(rig.device.engine.calls, isNot(contains('joinFromWelcome')));
    });

    test('the 24 h replace is not made when the init was stored while the '
        'rebuild claimed', () async {
      final old = await expired();
      final answer = rig.keys.claims[_bob]!;
      rig.keys.claims[_bob] = () async {
        storeOwnInit(old.group);
        return answer();
      };

      await starter.resumeProvisional();
      await done();

      expect(rig.keys.claimCalls, hasLength(1));
      await expectKept(old, 'stored during the claim');
      // Nothing of a new group went out.
      expect(
        rig.server.sends.every((s) => s.key == old.row.idempotencyKey),
        isTrue,
      );
    });

    test('a provisional group with no init row waits until it is 24 h old, '
        'and is discarded only then', () async {
      await rig.seedProvisional(_c1, [bob]);
      await rig.known.add(_c1, peerUserId: _bob);
      rig.server.calls.clear();

      await starter.resumeProvisional();
      await done();

      // Young: its row may only be unreadable now, and a send may be in
      // flight. Nothing is asked and nothing is deleted.
      expect((await groupOf())!.provisional, isTrue);
      expect(await rig.device.vault.members(_c1), hasLength(2));
      expect(rig.server.calls, isEmpty);

      rig.clock.advance(kProvisionalExpiry);
      await starter.resumeProvisional();
      await done();
      expect(rig.server.calls, contains('listConversationCommits'));
      expect(await groupOf(), isNull);
    });

    test('an init is not resent within the margin before expiry, so nothing '
        'is in flight when the commits are asked', () async {
      expect(
        kInitResendMargin,
        kServerRequestDeadline + const Duration(seconds: 30),
      );
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect(rig.server.sends, hasLength(2));

      // Just before the margin: the init is still resent.
      rig.clock.advance(
        kProvisionalExpiry - kInitResendMargin - const Duration(seconds: 1),
      );
      rig.server.sendScript.add(unknown);
      await starter.resumeProvisional();
      await done();
      expect(rig.server.sends, hasLength(3));
      expect(
        (await starter.pendingInit(conversationId: _c1))!.status,
        OutgoingStatus5a.sending,
      );

      // Inside the margin: no send, no commit listing, nothing changed.
      rig.clock.advance(const Duration(seconds: 1));
      rig.server.calls.clear();
      await starter.resumeProvisional();
      await done();
      rig.clock.advance(kInitResendMargin - const Duration(seconds: 1));
      await starter.resumeProvisional();
      await done();
      expect(rig.server.calls, isEmpty);
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.init, isNotNull);
      final shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.status, OutgoingStatus5a.waiting);
      expect(shown.waitingOn, SendBlock.provisional);
    });

    test('an init send that outlives the client\'s wait holds the expiry '
        'until the margin has passed after it really ended (Task 9 audit '
        'M2)', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      // The last resend allowed, just before the margin. The client gives
      // up on it after its 30 s, while the call still runs (a token fetch
      // stalled before it left).
      rig.clock.advance(
        kProvisionalExpiry - kInitResendMargin - const Duration(seconds: 1),
      );
      final ended = Completer<void>();
      rig.server.beforeSend = (send) async {
        rig.clock.advance(kMlsRpcTimeout);
        rig.server.abandon(send.key, ended.future);
      };
      rig.server.sendScript.add(unknown);
      await starter.resumeProvisional();
      await done();
      rig.server.beforeSend = null;
      expect(rig.server.sends, hasLength(3));

      // Expired while that call still runs: nothing is asked or decided.
      rig.clock.advance(const Duration(seconds: 32));
      rig.server.calls.clear();
      await starter.resumeProvisional();
      await done();
      expect(rig.server.calls, isEmpty);
      expect((await groupOf())!.provisional, isTrue);

      // It ends 20 s after the client's timeout; one resume is scheduled
      // for the margin's end, and nothing is decided before it.
      rig.clock.advance(const Duration(seconds: 20));
      ended.complete();
      await pumpEventQueue();
      expect(rig.scheduled.map((s) => s.delay), [kInitResendMargin]);
      rig.clock.advance(kInitResendMargin - const Duration(seconds: 1));
      await starter.resumeProvisional();
      await done();
      expect(rig.server.calls, isEmpty);
      expect((await groupOf())!.provisional, isTrue);

      // After the margin, the stored commits decide (one listing).
      rig.clock.advance(const Duration(seconds: 1));
      rig.keys.peerFails = true;
      rig.scheduled.single.run();
      await done();
      expect(rig.server.calls, ['listConversationCommits']);
    });

    test('a refusal after an abandoned init call that is still running keeps '
        'the provisional group; after the margin past its end the refusal '
        'decides (Task 9 ruling N)', () async {
      // The first attempt outlives the client's wait (a token fetch stalled
      // before it left) and is still running; the automatic resend is
      // refused, and the commits list none (the abandoned request may still
      // be stored after that listing).
      final ended = Completer<void>();
      rig.server.beforeSend = (send) async {
        if (rig.server.sends.length != 1) return;
        rig.clock.advance(kMlsRpcTimeout);
        rig.server.abandon(send.key, ended.future);
      };
      rig.server.sendScript.addAll([
        unknown,
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      await start();
      await done();
      rig.server.beforeSend = null;

      expect(rig.server.sends, hasLength(2));
      expect((await groupOf())!.provisional, isTrue);
      final kept = (await rows()).single;
      expect(kept.init, isNotNull);
      expect(kept.lastError, isNull);
      expect(rig.server.calls, isNot(contains('listMlsMessages')));

      // The call ends 20 s later: one resume, at the margin past its end.
      rig.clock.advance(const Duration(seconds: 20));
      ended.complete();
      await pumpEventQueue();
      expect(rig.scheduled.map((s) => s.delay), [kInitResendMargin]);

      // After the margin the same refusal, with no commit stored, is
      // definitive: the group goes and the row fails.
      rig.clock.advance(kInitResendMargin);
      rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      rig.scheduled.single.run();
      await done();
      expect(rig.server.sends, hasLength(3));
      expect(await groupOf(), isNull);
      expect((await rows()).single.lastError, isNotNull);
    });

    test('a refusal whose commit listing started inside the margin after an '
        'abandoned init call ended keeps the provisional group (Task 9 '
        'ruling N, provedAt)', () async {
      // The abandoned first call ends while the commit listing of the
      // refused resend is in flight: the listing started before the call's
      // end, so its "not stored" proves nothing.
      final ended = Completer<void>();
      rig.server.beforeSend = (send) async {
        if (rig.server.sends.length != 1) return;
        rig.clock.advance(kMlsRpcTimeout);
        rig.server.abandon(send.key, ended.future);
      };
      rig.server.onCall = (call) async {
        if (call != 'listConversationCommits' || ended.isCompleted) return;
        rig.clock.advance(const Duration(seconds: 1));
        ended.complete();
        await pumpEventQueue();
      };
      rig.server.sendScript.addAll([
        unknown,
        (error: const FeatureDisabledException('off'), stored: false),
      ]);
      await start();
      await done();
      rig.server.beforeSend = null;
      rig.server.onCall = null;

      expect(ended.isCompleted, isTrue);
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.lastError, isNull);
    });

    test(
      'a refusal whose commit listing starts 1 s before the margin after '
      'an abandoned init call\'s end, and returns 2 s later, keeps the '
      'provisional group (Task 9 round P, the review\'s provedAt gap)',
      () async {
        // The abandoned first call ends at T. The refused retry's listing
        // starts at T + margin - 1 s (inside the margin) and returns at
        // T + margin + 1 s (past it): only the listing's start may decide.
        final ended = Completer<void>();
        rig.server.beforeSend = (send) async {
          if (rig.server.sends.length != 1) return;
          rig.clock.advance(kMlsRpcTimeout);
          rig.server.abandon(send.key, ended.future);
        };
        rig.server.sendScript.addAll([unknown, unknown]);
        await start();
        await done();
        rig.server.beforeSend = null;
        expect(rig.server.sends, hasLength(2));

        // T: the abandoned call ends.
        ended.complete();
        await pumpEventQueue();
        rig.scheduled.clear();

        rig.clock.advance(kInitResendMargin - const Duration(seconds: 1));
        var listings = 0;
        rig.server.onCall = (call) async {
          if (call != 'listConversationCommits') return;
          listings++;
          rig.clock.advance(const Duration(seconds: 2));
        };
        rig.server.sendScript.add((
          error: const FeatureDisabledException('off'),
          stored: false,
        ));
        await starter.resumeProvisional();
        await done();
        rig.server.onCall = null;

        expect(rig.server.sends, hasLength(3));
        expect(listings, 1);
        expect((await groupOf())!.provisional, isTrue);
        expect((await rows()).single.lastError, isNull);
      },
    );
  });

  group('discardInit (gate 6, audit L10)', () {
    /// A started init whose two attempts got no answer; nothing stored at
    /// the server unless [stored].
    Future<OutboxItem> unanswered({bool stored = false}) async {
      rig.server.sendScript.addAll([stored ? lostAnswer : unknown, unknown]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      return row;
    }

    Future<void> expectUnchanged(OutboxItem row, String why) async {
      expect((await groupOf())!.provisional, isTrue, reason: why);
      final kept = (await rows()).single;
      expect(kept.idempotencyKey, row.idempotencyKey, reason: why);
      expect(kept.init, isNotNull, reason: why);
      expect(kept.stage, OutboxStage.encrypted, reason: why);
      expect(kept.lastError, isNull, reason: why);
    }

    Future<void> expectDiscarded(String why) async {
      expect(await groupOf(), isNull, reason: why);
      expect(await rig.device.vault.members(_c1), isEmpty, reason: why);
      final row = (await rows()).single;
      expect(row.stage, OutboxStage.plain, reason: why);
      expect(row.init, isNull, reason: why);
      expect(row.lastError, kStartErrorInitDiscarded, reason: why);
      expect(await starter.pendingInit(conversationId: _c1), isNull);
      final shown = (await rig.sender.outgoing(_c1)).single;
      expect(shown.status, OutgoingStatus5a.failed, reason: why);
      expect(shown.retryable, isTrue, reason: why);
      expect(shown.error, isNull, reason: why);
      expect(rig.known.contains(_c1), isTrue, reason: why);
    }

    test('the server\'s record says not stored: the group goes and the row '
        'fails with a reason the UI can show', () async {
      await unanswered();
      rig.clock.advance(kInitResendMargin);
      final sends = rig.server.sends.length;

      expect(await starter.discardInit(_c1), InitDiscard.discarded);

      await expectDiscarded('not stored');
      expect(rig.server.sends, hasLength(sends));
      // The user's retry starts again from fresh claims (review F1 c).
      rig.keys.claimCalls.clear();
      await starter.retryStart('local-1');
      await done();
      expect(rig.keys.claimCalls.single.userId, _bob);
    });

    test('after a restart, a row whose attempts were all made by the earlier '
        'run is held until the margin after the restart; then the record '
        'decides (pre-flag-on fix round 2, ruling 3)', () async {
      final row = await unanswered();
      expect(row.attempts, 0);
      expect((await rows()).single.attempts, greaterThan(0));
      // A request of the earlier run may still be on its way: the new run
      // never saw it end.
      await rig.restart();
      build();
      final sends = rig.server.sends.length;
      rig.server.calls.clear();

      rig.clock.advance(kInitResendMargin - const Duration(seconds: 1));
      expect(await starter.discardInit(_c1), InitDiscard.held);
      await expectUnchanged(row, 'inside the margin after the restart');
      expect(rig.server.calls, isEmpty, reason: 'nothing is asked');

      rig.clock.advance(const Duration(seconds: 1));
      expect(await starter.discardInit(_c1), InitDiscard.discarded);
      await expectDiscarded('the margin after the restart has passed');
      expect(rig.server.sends, hasLength(sends));
    });

    test('the server holds the init as this device\'s and it is younger '
        'than 24 h: held, nothing changes', () async {
      final row = await unanswered(stored: true);
      failListMessages();
      rig.clock.advance(kInitResendMargin);

      expect(await starter.discardInit(_c1), InitDiscard.held);

      await expectUnchanged(row, 'held');
      expect(
        rig.server.calls.where((c) => c == 'listMlsMessages'),
        isEmpty,
        reason: 'a young group is held on the commits alone',
      );
    });

    test(
      'the server holds the init as this device\'s for 24 h and no replay '
      'of it was refused in this run: the first page decides between '
      'settled and not decided, else held (pre-flag-on review I-1)',
      () async {
        final row = await unanswered(stored: true);
        rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));

        // The page cannot be had: nothing is decided.
        failListMessages();
        expect(await starter.discardInit(_c1), InitDiscard.notDecided);
        await expectUnchanged(row, 'no page');

        // The page does not hold the message (50 newer ones), no call is out
        // and the margin has passed, but no replay was refused: the server
        // holds the group as ours and may hold a live conversation in it.
        rig.server.onCall = null;
        rig.server.rewriteLive = (real) =>
            pb.ListMessagesResponse(conversation: real.conversation);
        expect(await starter.discardInit(_c1), InitDiscard.held);
        await expectUnchanged(row, 'ours, no refused replay');
      },
    );

    // Pre-flag-on fix round 2, ruling 2: the lasting refusals, the only
    // evidence (a STALE_EPOCH counts only when it names this conversation).
    for (final error in const <AppException>[
      FeatureDisabledException('off'),
      CannotMessageException(),
      NotFoundException('gone'),
      StaleEpochException(
        'stale',
        generation: 1,
        epoch: 2,
        conversationId: _c1,
      ),
    ]) {
      test('a replay refused with ${error.runtimeType} after 24 h, and a page '
          'without the message: discarded (pre-flag-on review I-1)', () async {
        final row = await unanswered(stored: true);
        rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
        rig.server.rewriteLive = (real) =>
            pb.ListMessagesResponse(conversation: real.conversation);
        rig.server.sendScript.add((error: error, stored: false));
        final sends = rig.server.sends.length;

        await starter.resumeProvisional();
        await done();

        // The replay went out, byte for byte, and was refused: nothing is
        // deleted by the refusal itself.
        expect(rig.server.sends, hasLength(sends + 1));
        expect(rig.server.sends.last.same(rig.server.sends.first), isTrue);
        await expectUnchanged(row, 'a refused replay deletes nothing');

        expect(await starter.discardInit(_c1), InitDiscard.discarded);
        await expectDiscarded('ours, its replay refused');
      });
    }

    test('a refused replay, then reset() (sign-out or a new vault): held, '
        'the evidence was memory of the earlier run (pre-flag-on review '
        'm-B)', () async {
      final row = await unanswered(stored: true);
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      rig.server.rewriteLive = (real) =>
          pb.ListMessagesResponse(conversation: real.conversation);
      rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      await starter.resumeProvisional();
      await done();
      await expectUnchanged(row, 'a refused replay deletes nothing');

      starter.reset();

      expect(await starter.discardInit(_c1), InitDiscard.held);
      await expectUnchanged(row, 'right after the reset');
      // Past the margin after the reset too (ruling 3 holds no more): no
      // replay was refused in this run.
      rig.clock.advance(kInitResendMargin);
      expect(await starter.discardInit(_c1), InitDiscard.held);
      await expectUnchanged(row, 'no refused replay in this run');
    });

    test(
      'a refused replay followed by a replay whose outcome is unknown: '
      'held, only the last request counts (pre-flag-on review I-1)',
      () async {
        final row = await unanswered(stored: true);
        rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
        rig.server.rewriteLive = (real) =>
            pb.ListMessagesResponse(conversation: real.conversation);
        rig.server.sendScript.addAll([
          (error: const FeatureDisabledException('off'), stored: false),
          unknown,
        ]);
        final sends = rig.server.sends.length;

        await starter.resumeProvisional();
        await done();
        await starter.resumeProvisional();
        await done();

        expect(rig.server.sends, hasLength(sends + 2));
        expect(await starter.discardInit(_c1), InitDiscard.held);
        await expectUnchanged(row, 'the last replay got no answer');
      },
    );

    // Each gate that keeps [_sendLocked] from sending the replay. With it
    // closed for 24 h no replay is refused, so the group is held.
    final gates = <({String name, Future<void> Function() close, int replays})>[
      (
        name: 'the flag is off',
        close: () => rig.device.session.onFlagChanged(E2eeFlag.off, uid: _me),
        replays: 0,
      ),
      (
        name: 'this device was removed elsewhere',
        close: () async => rig.removedElsewhere = true,
        replays: 0,
      ),
      (
        name: 'the thread cannot be answered (canReply false)',
        close: () async => rig.contexts.of(_c1).canReply = false,
        replays: 0,
      ),
      (
        name: 'a member is unattributed',
        close: () => rig.device.vault.transaction(
          (tx) => tx.putMember(
            MemberRecord(
              conversationId: _c1,
              deviceId: bob.id,
              signatureKey: bob.key,
              side: MemberSide.unattributed,
              since: const MlsPair(1, 1),
            ),
          ),
        ),
        replays: 0,
      ),
      (
        name: 'the server\'s retry time has not come',
        close: () async {
          // One replay, answered with a retry time an hour away: the
          // later trigger sends nothing.
          rig.server.sendScript.add((
            error: const ScreeningUnavailableException(
              'busy',
              retryAfter: Duration(hours: 1),
            ),
            stored: false,
          ));
          await starter.resumeProvisional();
          await done();
        },
        replays: 1,
      ),
      // Pre-flag-on fix round 2, ruling 2 (code review I-A, audit M-B): a
      // refusal the server makes BEFORE its replay lookup says nothing of
      // the group. It is an unknown outcome, never the evidence; one with a
      // retry time holds the next replay until then (the test's later
      // trigger sends nothing).
      for (final (refusal, retry) in const <(AppException, bool)>[
        (RateLimitedException('slow', retryAfter: Duration(hours: 1)), true),
        (DegradedModeException('ro', retryAfter: Duration(hours: 1)), true),
        (QuotaExceededException('quota', retryAfter: Duration(hours: 1)), true),
        (LimitReachedException('limit', retryAfter: Duration(hours: 1)), true),
        (AccountRestrictedException('restricted'), false),
        (EmailNotVerifiedException('verify'), false),
        (ValidationException('bad'), false),
      ])
        (
          name: 'the replay was refused with ${refusal.runtimeType}',
          close: () async {
            rig.server.sendScript.add((error: refusal, stored: false));
            if (!retry) return;
            await starter.resumeProvisional();
            await done();
          },
          replays: 1,
        ),
    ];
    for (final closed in gates) {
      test('at 24 h with ours and a hidden page, while ${closed.name}: held, '
          'the group stays (pre-flag-on review I-1)', () async {
        final row = await unanswered(stored: true);
        rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
        rig.server.rewriteLive = (real) =>
            pb.ListMessagesResponse(conversation: real.conversation);
        final sends = rig.server.sends.length;

        await closed.close();
        await starter.resumeProvisional();
        await done();
        expect(rig.server.sends, hasLength(sends + closed.replays));

        expect(await starter.discardInit(_c1), InitDiscard.held);
        await expectUnchanged(row, closed.name);
      });
    }

    test('a page that holds the message settles the group instead of '
        'discarding it', () async {
      final row = await unanswered(stored: true);
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));

      expect(await starter.discardInit(_c1), InitDiscard.settled);
      await done();

      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
    });

    test(
      'the commits cannot be listed: not decided, nothing changes',
      () async {
        final row = await unanswered();
        rig.clock.advance(kInitResendMargin);
        rig.server.onCall = (call) async {
          if (call == 'listConversationCommits') {
            throw const NetworkException('no network');
          }
        };

        expect(await starter.discardInit(_c1), InitDiscard.notDecided);
        await expectUnchanged(row, 'no listing');
      },
    );

    test('an init call that may still land is held', () async {
      // The second attempt outlives the client's wait and still runs.
      final ended = Completer<void>();
      rig.server.beforeSend = (send) async {
        if (rig.server.sends.length != 2) return;
        rig.clock.advance(kMlsRpcTimeout);
        rig.server.abandon(send.key, ended.future);
      };
      rig.server.sendScript.addAll([lostAnswer, unknown]);
      await start();
      await done();
      rig.server.beforeSend = null;
      final row = (await rows()).single;
      rig.clock.advance(kProvisionalExpiry);

      expect(await starter.discardInit(_c1), InitDiscard.held);
      await expectUnchanged(row, 'a call is out');
      ended.complete();
      await pumpEventQueue();
    });

    test('a group the marks already passed (InitSettle.replay) is discarded '
        'without asking the server: the way out of replay', () async {
      // The marks are at the init's pair (written before the group: the
      // vault writes no mark for a provisional group), so no settle can
      // ever be written for it.
      await rig.device.vault.transaction(
        (tx) => tx.setAfterPair(_c1, const MlsPair(1, 0)),
      );
      await rig.seedProvisional(_c1, [bob]);
      await rig.known.add(_c1, peerUserId: _bob);
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
      expect(
        await rig.locks.run(
          _c1,
          () => rig.crypto.settleOwnInitLocked(
            _c1,
            1,
            delivered: const InitDelivered(accepted: true),
          ),
        ),
        InitSettle.replay,
      );
      rig.server.calls.clear();

      expect(await starter.discardInit(_c1), InitDiscard.discarded);

      expect(rig.server.calls, isEmpty);
      await expectDiscarded('replay');
    });

    test('nothing to discard: none; an invalid id throws', () async {
      expect(await starter.discardInit(_c1), InitDiscard.none);
      expect(() => starter.discardInit('x'), throwsArgumentError);
      // A settled group has no pending init.
      await start();
      await done();
      expect((await groupOf())!.provisional, isFalse);
      expect(await starter.discardInit(_c1), InitDiscard.none);
    });
  });

  group('resumeProvisional', () {
    test('a provisional group dated after now (the clock moved back) counts '
        'as expired: its init is not resent', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect(rig.server.sends, hasLength(2));
      rig.clock.value = rig.clock.value.subtract(const Duration(hours: 1));
      // The rebuild cannot be made now: the group stays as it is.
      rig.keys.peerFails = true;
      rig.server.calls.clear();

      await starter.resumeProvisional();
      await done();

      expect(rig.server.sends, hasLength(2));
      expect(rig.server.calls, ['listConversationCommits']);
      expect((await groupOf())!.provisional, isTrue);
      expect((await rows()).single.init, isNotNull);
      final shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.status, OutgoingStatus5a.waiting);
      expect(shown.waitingOn, SendBlock.provisional);
    });

    test('a provisional group older than 24 h whose init is the first stored '
        'commit is cleared, not rebuilt', () async {
      rig.server.sendScript.addAll([lostAnswer, unknown]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      rig.keys.claimCalls.clear();
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      // No page and no live pull can answer for the message (review W1).
      failListMessages();

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
      // The answer for the message is the server's replay of the identical
      // request, init included: sent once more, never without the init.
      expect(rig.server.sends, hasLength(3));
      expect(inits(), hasLength(3));
      expect(rig.server.sends[0].same(rig.server.sends[2]), isTrue);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
      // Settled with the answer: accepted, as after any answered init.
      expect(await acceptedIn(), isTrue);
    });

    test('an expired group whose init is stored and whose replay is not '
        'answered keeps its init: the sender never sends the row, and a '
        'later trigger replays again (review W1)', () async {
      rig.server.sendScript.addAll([lostAnswer, unknown]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();
      rig.keys.claimCalls.clear();
      rig.clock.advance(kProvisionalExpiry + const Duration(minutes: 1));
      failListMessages();
      // The replay's answer is lost too.
      rig.server.sendScript.add(unknown);

      await starter.resumeProvisional();
      await done();

      expect((await groupOf())!.provisional, isTrue);
      final kept = (await rows()).single;
      expect(kept.idempotencyKey, row.idempotencyKey);
      expect(kept.init, isNotNull);
      expect(kept.stage, OutboxStage.encrypted);
      expect(kept.recipientUserId, _bob);
      expect(kept.conversationId, isNull);
      expect(kept.lastError, isNull);
      // One replay, under the lock; no rebuild.
      expect(rig.server.sends, hasLength(3));
      expect(inits(), hasLength(3));
      expect(rig.keys.claimCalls, isEmpty);
      // The row is not the sender's.
      await rig.sender.drain(_c1);
      await done();
      expect(await rig.sender.outgoing(_c1), isEmpty);
      expect(rig.server.sends, hasLength(3));
      final shown = (await starter.pendingInit(conversationId: _c1))!;
      expect(shown.status, OutgoingStatus5a.waiting);
      expect(shown.waitingOn, SendBlock.provisional);

      // The next trigger asks the commits again and replays again.
      await starter.resumeProvisional();
      await done();

      expect(rig.server.sends, hasLength(4));
      expect(inits(), hasLength(4));
      expect(rig.server.sends[0].same(rig.server.sends[3]), isTrue);
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
      expect(await acceptedIn(), isTrue);
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
      'the join code never settles an own init whose row still carries the '
      'init, and leaves the key history readable and unchanged (review W1)',
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
        // The join code alone: what it hands to the starter is recorded
        // here instead (the row above is a placeholder, not a real init;
        // the starter's resume is shown by the concern 4 test).
        final handedOver = <String>[];
        rig.crypto.onOwnInitUnanswered = handedOver.add;
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

        // The welcome is a replay of this device's own generation: gone.
        expect(rig.server.acks.expand((a) => a.ids), [w]);
        // Task 8 concern 4: handed to the starter, once.
        expect(handedOver, [_c1]);
        // No answer for the message here: the group stays provisional for
        // the starter, which replays the init and settles with the answer.
        final g = (await groupOf())!;
        expect(g.provisional, isTrue);
        expect(rigEq(g.pending!.commit, pending.commit), isTrue);
        expect(await rig.device.vault.members(_c1), hasLength(2));
        expect(
          rigEq(
            (await rig.sealedSetting('messages.e2ee.keys.$_c1'))!,
            history!,
          ),
          isTrue,
        );
        expect(rig.keyHistoryErrors, isEmpty);
        expect((await rig.keyHistoryIds(_c1)).keys, [vaultDeviceIdHex(bob.id)]);
        // The row is as it was: the same key and bytes, addressed as stored,
        // WITH its init (its key never goes out without it), and not the
        // sender's.
        final row = (await rows()).single;
        expect(row.idempotencyKey, key);
        expect(row.conversationId, isNull);
        expect(row.recipientUserId, _bob);
        expect(row.init, [9, 9]);
        expect(row.stage, OutboxStage.encrypted);
        expect(row.ciphertext, [1, 2, 3]);
        expect(await rig.sender.outgoing(_c1), isEmpty);
        expect(await starter.pendingInit(conversationId: _c1), isNotNull);
        // No mark is written while the group is provisional.
        expect(await rig.device.vault.conversation(_c1), isNull);
        expect(rig.server.sends, isEmpty);

        // Once no row carries the init (answered elsewhere), the same
        // welcome settles the group here, without an answer: the key history
        // stays byte-identical and nothing infers ACCEPTED (ruling F4; the
        // final-fix re-review's Minor 1 restored these two assertions).
        await rig.device.vault.transaction((tx) => tx.deleteOutbox(key));
        rig.server.acks.clear();
        final w2 = rig.server.addWelcome(
          rig.device.deviceIdString,
          _c1,
          const MlsPair(1, 0),
          Uint8List(4),
        );
        expect(await rig.crypto.processWelcomes(), isEmpty);
        expect(rig.server.acks.expand((a) => a.ids), [w2]);
        final settled = (await groupOf())!;
        expect(settled.provisional, isFalse);
        expect(settled.pending, isNull);
        expect(
          rigEq((await rig.sealedSetting('messages.e2ee.keys.$_c1'))!, history),
          isTrue,
        );
        expect(rig.keyHistoryErrors, isEmpty);
        expect(
          (await rig.device.vault.conversation(_c1))!.sync.requestAccepted,
          isFalse,
        );
        expect(rig.server.sends, isEmpty);
        // A settle hands nothing over.
        expect(handedOver, [_c1]);
      },
    );

    test('after the join code leaves an own init unanswered, the starter '
        'resumes it by itself and the group settles with no other trigger '
        '(Task 8 concern 4)', () async {
      // The init was stored and both answers were lost (the second try's
      // too): the group is provisional and the row keeps its init.
      rig.server.sendScript.addAll([lostAnswer, unknown]);
      gate = Completer<void>();
      await start();
      final row = (await rows()).single;
      gate!.complete();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      rig.scheduled.clear();
      final sends = rig.server.sends.length;
      // A welcome of this device's own generation is listed.
      final w = rig.server.addWelcome(
        rig.device.deviceIdString,
        _c1,
        const MlsPair(1, 0),
        Uint8List(4),
      );

      expect(await rig.crypto.processWelcomes(), isEmpty);
      expect(rig.server.acks.expand((a) => a.ids), [w]);
      // Nothing but the poll: no resumeProvisional, no retry, no timer.
      await pumpEventQueue();
      await done();

      expect(rig.scheduled, isEmpty);
      expect(rig.server.sends, hasLength(sends + 1));
      expect(rig.server.sends.last.key, row.idempotencyKey);
      expect(rig.server.sends.last.mlsInit, isNotNull);
      expect((await groupOf())!.provisional, isFalse);
      expect(await rows(), isEmpty);
      expect(
        await rig.device.vault.hasMessage(_c1, row.expectedMessageId),
        isTrue,
      );
    });

    test('a hand-over from the join code while a resume of the conversation '
        'runs starts one more resume after it, never joins it (pre-flag-on '
        'review m-C)', () async {
      rig.server.sendScript.addAll([unknown, unknown]);
      await start();
      await done();
      expect((await groupOf())!.provisional, isTrue);
      expect(rig.server.sends, hasLength(2));
      rig.scheduled.clear();

      // A resume is running: its request is in flight.
      gate = Completer<void>();
      rig.server.sendScript.addAll([unknown, unknown]);
      final running = starter.resumeProvisional();
      await pumpEventQueue();
      expect(rig.server.sends, hasLength(3));

      // The join code hands the group over meanwhile (its settle found the
      // own init stored and unanswered).
      rig.crypto.onOwnInitUnanswered!(_c1);
      gate!.complete();
      await running;
      await pumpEventQueue();
      await done();

      // The handed-over resume asked again once the running one had ended.
      expect(rig.server.sends, hasLength(4));
      expect(rig.server.sends[3].same(rig.server.sends[0]), isTrue);
      expect((await groupOf())!.provisional, isTrue);
    });

    test(
      'the join code hands an own unanswered init to the starter once per '
      'group per run, not once per welcome poll (pre-flag-on review m-2)',
      () async {
        rig.server.sendScript.addAll([lostAnswer, unknown]);
        gate = Completer<void>();
        await start();
        gate!.complete();
        await done();
        expect((await groupOf())!.provisional, isTrue);
        rig.scheduled.clear();
        // Every replay is refused and the page never shows the message: the
        // group stays provisional through every poll.
        rig.server.rewriteLive = (real) =>
            pb.ListMessagesResponse(conversation: real.conversation);
        const refused = (error: FeatureDisabledException('off'), stored: false);
        rig.server.sendScript.addAll([refused, refused, refused]);
        final sends = rig.server.sends.length;

        Future<void> poll() async {
          rig.server.addWelcome(
            rig.device.deviceIdString,
            _c1,
            const MlsPair(1, 0),
            Uint8List(4),
          );
          expect(await rig.crypto.processWelcomes(), isEmpty);
          await pumpEventQueue();
          await done();
        }

        // The first poll hands the group over: one resume, one replay.
        await poll();
        expect(rig.server.sends, hasLength(sends + 1));
        expect((await groupOf())!.provisional, isTrue);

        // Later polls meet the same group: nothing more is started.
        await poll();
        await poll();
        expect(rig.server.sends, hasLength(sends + 1));
        expect((await groupOf())!.provisional, isTrue);
        expect((await rows()).single.init, isNotNull);

        // A new run (sign-out or a new vault forgets it) hands it over again.
        rig.crypto.forgetOwnCommits();
        await poll();
        expect(rig.server.sends, hasLength(sends + 2));
      },
    );

    test('an own-init settle deletes a lower generation that was walked and '
        'kept', () async {
      final v = rig.device.vault;
      // Task 10: a reset's settle reads the new group's members, so the
      // provisional state is a real one (this device alone).
      final provisionalState = await rig.device.engine.inner.createGroup(
        (await v.deviceState())!,
        mlsGroupId(_c1, 2),
      );
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
            state: provisionalState,
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
      // As the reset's creating transaction leaves it (Task 10): the key
      // history is written with the provisional group.
      await rig.putKeyHistory(_c1);

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
        // Task 10: a reset's settle reads the new group's members.
        final provisionalState = await rig.device.engine.inner.createGroup(
          (await v.deviceState())!,
          mlsGroupId(_c1, 2),
        );
        await v.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 2,
              epoch: 1,
              state: provisionalState,
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
