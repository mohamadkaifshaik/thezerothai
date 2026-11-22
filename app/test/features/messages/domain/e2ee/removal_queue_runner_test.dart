import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/removal_queue_runner.dart';
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
const _c4 = '44444444444444444444444444444444';

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RemovalQueueRunner runner;
  late _SpyBudget budget;
  final runnerScheduled = <RigScheduled>[];
  final offers = <String, RigOffer>{};

  /// Pipeline errors the running test expects (checked by the tearDown).
  var expectedErrors = <String>[];

  RemovalQueueRunner build() => RemovalQueueRunner(
    keys: rig.keys,
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
  /// this device and [ownListed] for the own user.
  Future<void> setUpRig({
    List<RigPeer> ownListed = const [],
    List<RigPeer> peerListed = const [],
  }) async {
    runnerScheduled.clear();
    offers.clear();
    rig = await RigCrypto.create(
      syncBudget: (clock) => budget = _SpyBudget(clock),
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

  tearDown(() async {
    await runner.idle();
    await rig.upkeep.idle();
    final unexpected = [
      for (final e in rig.unexpected) e is E2eePipelineError ? e.step : '$e',
    ];
    final expected = expectedErrors;
    expectedErrors = [];
    await rig.dispose();
    expect(unexpected, expected, reason: 'unexpected pipeline errors');
  });

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
      (await rig.device.vault.conversation(c))?.sync ??
      const ConversationSync();

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

  // -------------------------------------------------------------------------

  group('removeDevice (R17)', () {
    test('RemoveKeyDevice runs first and a failure queues nothing', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      rig.keys.removeError = const NetworkException('rig: offline');

      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<NetworkException>()),
      );
      await runner.idle();

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(runner.queuedFor(_c1), isEmpty);
      expect(runner.pending.value, 0);
      expect(await stored(), isNull);
      expect(requests(), isEmpty);
      expect((await pin(sibling))!.side, MemberSide.mine);

      // Success: the call comes before any commit.
      rig.keys.removeError = null;
      int? removeCallsAtCommit;
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') {
          removeCallsAtCommit ??= rig.keys.removeCalls.length;
        }
      };
      await removeAndSettle(sibling);

      expect(removeCallsAtCommit, 2);
      expect(rig.keys.removeCalls.last.key, hasLength(32));
      expect(requests(_c1).single.welcome, isNull);
      expect(await pin(sibling), isNull);
    });

    test('the queue holds every conversation with group state, most recent '
        'first, and no other', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling], newestAtMicros: 5);
      await stateOnly(_c2, accepted: false, mine: [sibling]);
      await stateOnly(_c3, accepted: false, mine: [sibling], newestAtMicros: 9);
      // A sync record and no group state: never queued.
      await rig.device.vault.transaction(
        (tx) => tx.putConversationSync(
          _c4,
          const ConversationSync(requestAccepted: true),
        ),
      );

      await removeAndSettle(sibling);

      final q = (await stored())!;
      expect([for (final e in q.entries) e.conversationId], [_c3, _c1, _c2]);
      expect(q.entries.every((e) => rigEq(e.deviceId, sibling.id)), isTrue);
      // Unaccepted: parked, not dropped.
      expect(q.entries.every((e) => e.parked), isTrue);
      expect(runner.queuedFor(_c4), isEmpty);
      expect(runner.pending.value, 3);
      expect(requests(), isEmpty);
    });

    test('the queue survives a restart', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);
      await stateOnly(_c2, accepted: false, mine: [sibling]);
      await removeAndSettle(sibling);
      expect(runner.pending.value, 2);

      await rig.restart();
      runner = build();
      expect(runner.queuedFor(_c1), isEmpty, reason: 'not loaded yet');
      await runner.onVaultReady();
      await runner.idle();

      expect(queued(_c1, sibling), isTrue);
      expect(queued(_c2, sibling), isTrue);
      expect(runner.pending.value, 2);
      expect(runner.wasRemovedByUser(sibling.id), isTrue);
    });

    test('removing this device\'s own id is refused', () async {
      await setUpRig();
      await join(_c1);

      await expectLater(
        runner.removeDevice(rig.device.deviceIdString),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(runner.removeDevice(''), throwsA(isA<ArgumentError>()));

      expect(rig.keys.removeCalls, isEmpty);
      expect(await stored(), isNull);
      expect(runner.pending.value, 0);
    });

    test('removal works with the flag off', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: rig.device.uid);
      expect(rig.device.session.mayStart, isFalse);

      await removeAndSettle(sibling);

      expect(rig.keys.removeCalls.single.deviceId, sibling.idString);
      expect(requests(_c1).single.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
    });
  });

  group('a pass (R17)', () {
    test('one pass makes one attempt per conversation', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await join(_c2, others: [sibling]);
      // Every call refused: each conversation is tried once, then the pass
      // stops.
      for (var i = 0; i < 4; i++) {
        rig.server.commitScript.add((
          error: const ValidationException('rig'),
          stored: false,
        ));
      }

      await removeAndSettle(sibling);

      expect(requests(_c1), hasLength(1));
      expect(requests(_c2), hasLength(1));
      expect(runner.pending.value, 2);

      await runner.runPass();
      expect(requests(_c1), hasLength(2));
      expect(requests(_c2), hasLength(2));
      expect(queued(_c1, sibling), isTrue);
    });

    test(
      'two queued devices of one conversation go in its one commit',
      () async {
        final sibling = await RigPeer.create('sibling');
        final sib2 = await RigPeer.create('sib2');
        await setUpRig(ownListed: [sibling, sib2]);
        await join(_c1, others: [sibling, sib2], accepted: false);
        await synced();
        // Parked while unaccepted, so both are queued before any attempt.
        await removeAndSettle(sibling);
        await removeAndSettle(sib2);
        expect(runner.queuedFor(_c1), hasLength(2));
        await rig.accept(_c1);
        rig.contexts.note(headerRow(_c1));
        await runner.onAccepted(_c1);
        await runner.idle();

        expect(requests(_c1), hasLength(1));
        expect(await pin(sibling), isNull);
        expect(await pin(sib2), isNull);
        expect(runner.pending.value, 0);
      },
    );

    test('CANNOT_MESSAGE parks the entry and a usable conversation un-parks '
        'it', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.server.commitScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));

      await removeAndSettle(sibling);

      expect(requests(_c1), hasLength(1));
      expect((await stored())!.entries.single.parked, isTrue);
      expect(runner.pending.value, 1, reason: 'parked ones count');
      // Parked: a pass makes no attempt.
      await runner.runPass();
      expect(requests(_c1), hasLength(1));
      // A header that says the thread can be answered, but not usable yet
      // for the runner until it is told.
      rig.contexts.note(headerRow(_c1, canReply: false));
      await runner.noteConversation(_c1);
      await runner.idle();
      expect(requests(_c1), hasLength(1));

      rig.contexts.note(headerRow(_c1));
      await runner.noteConversation(_c1);
      await runner.idle();

      expect(requests(_c1), hasLength(2));
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
      expect((await stored())!.entries, isEmpty);
    });

    test('an unaccepted request is parked and runs at acceptance before the '
        'first reply', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling], accepted: false);
      await synced();
      expect(rig.contexts.of(_c1).requestSeenInHeader, isTrue);

      await removeAndSettle(sibling);
      expect(requests(), isEmpty);
      expect((await stored())!.entries.single.parked, isTrue);

      rig.realAcceptance = true;
      final events = <String>[];
      rig.server.onCall = (call) async {
        if (call == 'acceptMessageRequest' ||
            call == 'commitConversation' ||
            call == 'sendEncrypted') {
          events.add(call);
        }
      };
      await rig.sender.enqueue(localId: 'l1', conversationId: _c1, text: 'hi');
      await rig.sender.settled(_c1);

      expect(events, [
        'acceptMessageRequest',
        'commitConversation',
        'sendEncrypted',
      ]);
      expect(await pin(sibling), isNull);
      // The acceptance's commit carried it: the runner only lets it go.
      await runner.onAccepted(_c1);
      await runner.idle();
      expect(requests(), hasLength(1));
      expect(runner.pending.value, 0);
    });

    test('an entry leaves when another device\'s commit already removed the '
        'member', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      await bobRemoves(_c1, [sibling.id]);

      await removeAndSettle(sibling);

      expect(requests(), isEmpty);
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
      expect((await stored())!.entries, isEmpty);
    });

    test('pending counts queued conversations, parked ones included, and '
        'reaches 0', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await join(_c2, others: [sibling], accepted: false);
      final seen = <int>[];
      runner.pending.addListener(() => seen.add(runner.pending.value));

      await removeAndSettle(sibling);

      expect(seen.first, 2);
      expect(runner.pending.value, 1, reason: 'c2 is parked');
      expect(await pin(sibling), isNull);
      expect((await pin(sibling, _c2))!.side, MemberSide.mine);

      await rig.upkeep.onAccepted(_c2);
      await runner.onAccepted(_c2);
      await runner.idle();

      expect(await pin(sibling, _c2), isNull);
      expect(runner.pending.value, 0);
      expect(seen.last, 0);
    });
  });

  group('rate limits (R17, security read L1, amendment 2)', () {
    test(
      'RATE_LIMITED stops the pass until the server\'s retry time',
      () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        await join(_c1, others: [sibling]);
        await join(_c2, others: [sibling]);
        rig.server.commitScript.add((
          error: const RateLimitedException(
            'rig',
            retryAfter: Duration(minutes: 10),
          ),
          stored: false,
        ));

        await removeAndSettle(sibling);

        // c1 (the first) was limited; the pass stopped before c2.
        expect(requests(_c1), hasLength(1));
        expect(requests(_c2), isEmpty);
        expect(
          (await stored())!.notBeforeMicros,
          rig.clock
              .now()
              .add(const Duration(minutes: 10))
              .microsecondsSinceEpoch,
        );
        expect(runnerScheduled.last.delay, const Duration(minutes: 10));
        expect(queued(_c1, sibling), isTrue);

        // Never sooner: no pass starts before it, whoever asks.
        rig.clock.advance(const Duration(minutes: 9));
        await runner.runPass();
        await runner.onAppResumed();
        await runner.idle();
        expect(rig.server.commitRequests, hasLength(1));

        rig.clock.advance(const Duration(minutes: 1));
        await runTimer();

        expect(requests(_c1), hasLength(2));
        expect(requests(_c2), hasLength(1));
        expect(await pin(sibling), isNull);
        expect(await pin(sibling, _c2), isNull);
        expect(runner.pending.value, 0);
        expect((await stored())!.notBeforeMicros, isNull);
      },
    );

    test('a retry time more than 24 h away is capped at 24 h', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'rig',
          retryAfter: Duration(hours: 48),
        ),
        stored: false,
      ));

      await removeAndSettle(sibling);

      expect(
        (await stored())!.notBeforeMicros,
        rig.clock.now().add(kMaxServerRetryWait).microsecondsSinceEpoch,
      );
      expect(runnerScheduled.last.delay, kMaxServerRetryWait);
      rig.clock.advance(kMaxServerRetryWait);
      await runTimer();
      expect(await pin(sibling), isNull);
    });

    test('a RATE_LIMITED answer with no retry time waits the fallback '
        'minute', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.server.commitScript.add((
        error: const RateLimitedException('rig'),
        stored: false,
      ));

      await removeAndSettle(sibling);

      expect(runnerScheduled.last.delay, const Duration(minutes: 1));
    });

    test(
      'a rate limit of another conversation does not hold the queue',
      () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        await join(_c1, others: [sibling]);
        // The runner-wide record names another conversation's limit.
        rig.commits.lastRateLimit = const RateLimitedException(
          'rig',
          retryAfter: Duration(hours: 1),
        );

        await removeAndSettle(sibling);

        expect(await pin(sibling), isNull);
        expect((await stored())!.notBeforeMicros, isNull);
        expect(runnerScheduled, isEmpty);
      },
    );
  });

  group('the last peer-side device (Task 9 audit L5, amendment 1)', () {
    test('a queued removal never removes the peer\'s last peer-side member; '
        'the entry stays and is reported', () async {
      await setUpRig();
      await join(_c1);
      await synced();

      await removeAndSettle(bob);

      expect(requests(), isEmpty);
      expect((await pin(bob))!.side, MemberSide.theirs);
      expect(queued(_c1, bob), isTrue);
      expect(runner.lastPeerDeviceKept(_c1), isTrue);
      expect(runner.pending.value, 1);
    });

    test('the upkeep\'s reconcile, fed from the queue, keeps the peer\'s last '
        'peer-side member too', () async {
      await setUpRig();
      await join(_c1);
      await synced();
      await removeAndSettle(bob);
      expect(queued(_c1, bob), isTrue);

      await rig.upkeep.reconcile(_c1);

      expect(requests(), isEmpty);
      expect((await pin(bob))!.side, MemberSide.theirs);
    });

    test('the upkeep\'s reconcile removes a queued peer-side member that is '
        'not the last', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpRig(peerListed: [bob2]);
      await join(_c1, others: [bob2]);
      await synced();
      // Parked, so only the upkeep commits.
      rig.contexts.of(_c1).canReply = false;
      await removeAndSettle(bob2);
      rig.contexts.note(headerRow(_c1));

      await rig.upkeep.reconcile(_c1);

      expect(requests(_c1), hasLength(1));
      expect(await pin(bob2), isNull);
      expect((await pin(bob))!.side, MemberSide.theirs);
    });

    test(
      'of two queued peer-side members one goes and the last stays',
      () async {
        final bob2 = await RigPeer.create('bob2');
        await setUpRig(peerListed: [bob2]);
        await join(_c1, others: [bob2]);
        await synced();
        expect((await pin(bob2))!.side, MemberSide.theirs);
        // Both queued before any attempt: the conversation is parked first.
        rig.contexts.of(_c1).canReply = false;
        await removeAndSettle(bob);
        await removeAndSettle(bob2);
        rig.contexts.note(headerRow(_c1));
        await runner.noteConversation(_c1);
        await runner.idle();

        expect(requests(_c1), hasLength(1));
        final left = [
          for (final p in [bob, bob2])
            if (await pin(p) != null) p,
        ];
        expect(left, hasLength(1));
        expect(queued(_c1, left.single), isTrue);
        expect(runner.lastPeerDeviceKept(_c1), isTrue);
      },
    );
  });

  group('the pause exemption (Task 9 ruling H, amendment 3)', () {
    test('two undos today, and the queued removal still commits', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await rig.ledger.addUndone(_c1);
      }
      expect(
        await rig.commits.mayCommit(_c1, PendingKind.change),
        isFalse,
        reason: 'paused for every other change',
      );

      await removeAndSettle(sibling);

      expect(requests(_c1).single.welcome, isNull);
      expect(await pin(sibling), isNull);
      expect(runner.pending.value, 0);
    });

    test(
      'an unreadable ledger, and the queued removal still commits',
      () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        await join(_c1, others: [sibling]);
        await synced();
        await rig.device.vault.transaction(
          (tx) => tx.putSetting(kVaultSettingE2eeDaily, rigBytes('not json')),
        );
        expectedErrors = ['daily.read'];

        await removeAndSettle(sibling);

        expect(await pin(sibling), isNull);
      },
    );

    test('the daily call cap still holds', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      await updateSync(
        (s) => s.copyWith(
          commitCallsDay: istDay(rig.clock.now()),
          commitCallsToday: kCommitCallsPerConversationPerDay,
        ),
      );

      await removeAndSettle(sibling);

      expect(requests(), isEmpty);
      expect(queued(_c1, sibling), isTrue);
    });
  });

  group('the upkeep seam (amendment 4)', () {
    test('a queued removal goes before an add and a due self-update in the '
        'same conversation', () async {
      final sibling = await RigPeer.create('sibling');
      final bob2 = await RigPeer.create('bob2');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      // Parked by CANNOT_MESSAGE, so the runner makes no attempt; the
      // queue still feeds the upkeep.
      rig.server.commitScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));
      await removeAndSettle(sibling);
      expect(requests(), hasLength(1));
      rig.contexts.note(headerRow(_c1));
      rig.keys.peers['ref-bob'] = [
        for (final p in [bob, bob2]) rigKeyDevice(p.idString, p.key),
      ];
      rig.keys.claims['ref-bob'] = () async => kpb.ClaimKeyPackagesResponse(
        conversationId: _c1,
        keyPackages: [
          for (final d in [bob, bob2])
            kpb.ClaimedKeyPackage(
              deviceId: d.idString,
              signaturePublicKey: d.key,
              keyPackage: await d.keyPackage(),
              hasKeyPackage_4: true,
            ),
        ],
      );
      // A self-update is due too.
      rig.clock.advance(kSelfUpdateEvery + const Duration(days: 1));
      await synced();

      await rig.upkeep.reconcile(_c1);

      final made = requests().skip(1).toList();
      expect(made, isNotEmpty);
      // The first commit carries the removal and the add together.
      expect(made.first.welcomeDeviceIds, [bob2.idString]);
      expect(await pin(sibling), isNull);
      expect((await pin(bob2))!.side, MemberSide.theirs);
      // Any self-update came after it.
      for (final r in made.skip(1)) {
        expect(r.welcome, isNull);
      }

      // The runner does not commit it again: it only lets it go.
      final before = requests().length;
      await runner.noteConversation(_c1);
      await runner.runPass();
      expect(requests(), hasLength(before));
      expect(runner.pending.value, 0);
    });
  });

  group('never re-add (amendment 6)', () {
    test('wasRemovedByUser answers for a device the user removed', () async {
      final sibling = await RigPeer.create('sibling');
      final other = await RigPeer.create('other');
      await setUpRig(ownListed: [sibling]);
      await stateOnly(_c1, accepted: false, mine: [sibling]);

      await removeAndSettle(sibling);

      expect(runner.wasRemovedByUser(sibling.id), isTrue);
      expect(runner.wasRemovedByUser(other.id), isFalse);
    });
  });

  group('persistence (amendment 7)', () {
    test('a sealed read that fails is unknown and changes nothing', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      await synced();
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingRemovalQueue, rigBytes('not json')),
      );
      final sealed = await rig.sealedSetting(kVaultSettingRemovalQueue);
      expectedErrors = ['removalQueue.read'];

      await runner.onVaultReady();
      await runner.idle();
      await expectLater(
        runner.removeDevice(sibling.idString),
        throwsA(isA<StateError>()),
      );
      await runner.runPass();

      expect(rig.keys.removeCalls, isEmpty);
      expect(requests(), isEmpty);
      expect(runner.queuedFor(_c1), isEmpty);
      expect(runner.unreadable, isTrue);
      expect(await rig.sealedSetting(kVaultSettingRemovalQueue), sealed);
      expect((await pin(sibling))!.side, MemberSide.mine);
    });

    test('every change is stored', () async {
      final sibling = await RigPeer.create('sibling');
      await setUpRig(ownListed: [sibling]);
      await join(_c1, others: [sibling]);
      rig.server.commitScript.add((
        error: const CannotMessageException(),
        stored: false,
      ));

      await removeAndSettle(sibling);
      expect((await stored())!.entries.single.parked, isTrue);

      rig.contexts.note(headerRow(_c1));
      await runner.noteConversation(_c1);
      await runner.idle();
      expect((await stored())!.entries, isEmpty);
    });
  });

  group('triggers (R17, amendment 5)', () {
    test(
      'a timer-driven pass runs at background priority, never user',
      () async {
        final sibling = await RigPeer.create('sibling');
        await setUpRig(ownListed: [sibling]);
        await join(_c1, others: [sibling]);
        rig.server.commitScript.add((
          error: const RateLimitedException(
            'rig',
            retryAfter: Duration(minutes: 10),
          ),
          stored: false,
        ));
        await removeAndSettle(sibling);
        // The pass after removeDevice: live, never user.
        expect(budget.taken, isNotEmpty);
        expect(budget.taken, isNot(contains(BudgetPriority.user)));
        // Not synced again by anyone: the timer's pass pulls and commits.
        rig.contexts.of(_c1).syncedSinceStart = false;
        budget.taken.clear();

        rig.clock.advance(const Duration(minutes: 10));
        await runTimer();

        expect(await pin(sibling), isNull);
        expect(budget.taken, isNotEmpty);
        expect(budget.taken.toSet(), {BudgetPriority.background});
      },
    );
  });
}

/// A sync budget that records the priority of every unit taken.
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
