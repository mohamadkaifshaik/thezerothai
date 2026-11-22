import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/mls_derivations.dart';
import 'package:dzeroth/core/crypto/mls_pair.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/secure_vault.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/commit_runner.dart';
import 'package:dzeroth/features/messages/domain/e2ee/conversation_crypto.dart';
import 'package:dzeroth/features/messages/domain/e2ee/daily_ledger.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_types.dart';
import 'package:dzeroth/features/messages/domain/e2ee/known_conversations.dart';
import 'package:dzeroth/features/messages/domain/e2ee/membership_rules.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_receiver.dart'
    show kWalkBackoff;
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protobuf/well_known_types/google/protobuf/timestamp.pb.dart'
    as ts;

import '../../../../support/e2ee_pipeline_rig.dart';

const _c1 = '11111111111111111111111111111111';

final RegExp _keyShape = RegExp(r'^[0-9a-f]{32}$');

void main() {
  late RigCrypto rig;
  late RigPeer bob;
  late RigOffer offer;

  /// Pipeline errors the running test expects (checked by the tearDown).
  var expectedErrors = <String>[];

  tearDown(() async {
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

  /// This device joins [_c1] from bob's welcome (generation 1), with
  /// [others] (more devices of bob's) in the group; each is pinned `theirs`
  /// by attribution. [accepted]: the stored sync record says so.
  Future<void> setUpJoined({
    bool accepted = true,
    List<RigPeer> others = const [],
  }) async {
    rig = await RigCrypto.create();
    bob = await RigPeer.create('bob');
    rig.keys.peers['ref-bob'] = [
      rigKeyDevice(bob.idString, bob.key),
      for (final o in others) rigKeyDevice(o.idString, o.key),
    ];
    if (accepted) await rig.accept(_c1);
    rig.header(_c1, 'ref-bob');
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

  /// Bob commits a self-update on the server's current pair.
  Future<void> bobSelfUpdate() async {
    final g = offer.add.group;
    final at = rig.server.current(_c1);
    final c = await bob.engine.selfUpdate(bob.state, g.state);
    g.state = await bob.engine.confirmCommit(bob.state, c.groupState);
    rig.server.addCommit(_c1, at, c.commit, fromUser: 'user-b');
  }

  /// Bob's own group takes the commit this device stored at [pair].
  Future<void> bobApplies(MlsPair pair) async {
    final g = offer.add.group;
    final commit = rig.server.commitAt(_c1, pair)!;
    g.state = (await bob.engine.process(bob.state, g.state, commit)).groupState;
  }

  Future<ConversationCryptoState> state() => rig.crypto.describeState(_c1);

  Future<GroupRecord> groupRecord() async =>
      (await rig.device.vault.group(_c1, 1))!;

  Future<ConversationSync> sync() async =>
      (await rig.device.vault.conversation(_c1))?.sync ??
      const ConversationSync();

  Future<MemberRecord?> pin(RigPeer p) async {
    for (final m in await rig.device.vault.members(_c1)) {
      if (rigEq(m.deviceId, p.id)) return m;
    }
    return null;
  }

  /// A claimed and checked key package of [p] for [side] (what Task 9's
  /// reconcile hands the runner).
  Future<UsableClaim> claim(RigPeer p, ClaimSide side) async => UsableClaim(
    deviceId: p.id,
    signatureKey: p.key,
    keyPackage: await p.keyPackage(),
    side: side,
  );

  /// The stored sync record says [n] commit calls were made today.
  Future<void> setCalls(int n) async {
    final next = (await sync()).copyWith(
      commitCallsDay: istDay(rig.clock.now()),
      commitCallsToday: n,
    );
    await rig.device.vault.transaction(
      (tx) => tx.putConversationSync(_c1, next),
    );
  }

  int engineCalls(String name) =>
      rig.device.engine.calls.where((c) => c == name).length;

  List<RigCommitCall> requests() => rig.server.commitRequests;

  const offline = NetworkException('rig: no answer');

  /// Runs the one resume the runner scheduled, as its timer would, and
  /// waits until that resume has left the conversation lock.
  Future<void> runScheduled() async {
    final entry = rig.commitScheduled.single;
    rig.commitScheduled.clear();
    entry.run();
    await rig.locks.run(_c1, () async {});
  }

  group('M5 in commit apply', () {
    test('a commit by another device that removes a device this device added '
        'today raises the undo count', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      // As this device's own add of today (the runner records it so).
      await rig.ledger.noteOwnChange(_c1, added: [carol.id]);
      expect(await rig.ledger.undone(_c1), 0);

      await bobCommits(remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 1);
      expect((await state()).committingPausedToday, isFalse);
      // The reversed change is used up: nothing is left to undo again.
      expect(
        await rig.ledger.isUndoOfOwnChange(_c1, carol.id, removing: true),
        isFalse,
      );
    });

    test('a commit that adds back a device this device removed today is an '
        'undo', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await rig.ledger.noteOwnChange(_c1, removed: [carol.id]);

      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 1);
    });

    test(
      'a commit that reverses no own change of today is not counted',
      () async {
        await setUpJoined();
        final carol = await RigPeer.create('carol');
        final dave = await RigPeer.create('dave');
        await rig.ledger.noteOwnChange(_c1, added: [dave.id]);

        // One commit per catch-up (each closes an epoch's walk).
        await bobSelfUpdate();
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        await bobCommits(add: [await carol.keyPackage()]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        await bobCommits(remove: [carol.id]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

        expect(await rig.ledger.undone(_c1), 0);
        expect((await state()).committingPausedToday, isFalse);
      },
    );

    test('two undos in one day: describeState reports committingPausedToday '
        'until the next IST day', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        await bobCommits(add: [await carol.keyPackage()]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
        await rig.ledger.noteOwnChange(_c1, added: [carol.id]);
        expect((await state()).committingPausedToday, isFalse);
        await bobCommits(remove: [carol.id]);
        expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      }

      expect(await rig.ledger.undone(_c1), kAntiFlapUndosPerDay);
      expect((await state()).committingPausedToday, isTrue);

      rig.clock.advance(const Duration(days: 1));
      expect((await state()).committingPausedToday, isFalse);
    });

    test('an own change of an earlier IST day is not undone today', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      await rig.ledger.noteOwnChange(_c1, added: [carol.id]);
      rig.clock.advance(const Duration(days: 1));

      await bobCommits(remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 0);
    });

    test('an unreadable ledger reads as paused, and a change by another '
        'device still applies', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(kVaultSettingE2eeDaily, rigBytes('not json')),
      );
      expectedErrors = ['daily.read'];

      expect((await state()).committingPausedToday, isTrue);
      await bobCommits(add: [await carol.keyPackage()]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await rig.device.vault.group(_c1, 1))!.epoch, 2);
      expect((await rig.ledger.read()).exhausted, isTrue);
      expect((await state()).committingPausedToday, isTrue);
    });
  });

  group('one commit', () {
    test(
      'the pending record and the call count are stored before the call',
      () async {
        await setUpJoined();
        await synced();
        final carol = await RigPeer.create('carol');
        var seen = 0;
        rig.server.onCall = (call) async {
          if (call != 'commitConversation') return;
          seen++;
          final g = await groupRecord();
          final pending = g.pending!;
          final request = requests().single;
          // The state holding the pending commit, the epoch unchanged.
          expect(g.epoch, 1);
          expect(
            (await rig.device.engine.inner.describe(g.state)).hasPendingCommit,
            isTrue,
          );
          expect(pending.kind, PendingKind.change);
          expect(pending.builtOn, const MlsPair(1, 1));
          expect(rigEq(pending.commit, request.commit), isTrue);
          expect(rigEq(pending.welcome!, request.welcome!), isTrue);
          expect(pending.welcomeDeviceIds, [carol.idString]);
          expect(request.welcomeDeviceIds, [carol.idString]);
          expect(request.builtOn, const MlsPair(1, 1));
          expect(request.key, matches(_keyShape));
          // Counted before the call.
          final s = await sync();
          expect(s.commitCallsDay, istDay(rig.clock.now()));
          expect(s.commitCallsToday, 1);
        };

        expect(
          await rig.commits.change(
            _c1,
            adds: [await claim(carol, ClaimSide.theirs)],
          ),
          CommitOutcome.applied,
        );
        expect(seen, 1);
      },
    );

    test('success completes the epoch\'s messages, confirms and pins the adds '
        'with their checked side', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      final sibling = await RigPeer.create('sibling');
      // The join renewed the leaf; an add-only commit must not move that.
      final joinedAt = (await sync()).lastSelfUpdateAtMicros;
      rig.clock.advance(const Duration(minutes: 1));
      rig.server.epochRequests.clear();
      var walkedBeforeConfirm = false;
      rig.server.onCall = (call) async {
        if (call == 'listEpochMessages' && requests().isNotEmpty) {
          walkedBeforeConfirm = engineCalls('confirmCommit') == 0;
        }
      };

      final outcome = await rig.commits.change(
        _c1,
        adds: [
          await claim(carol, ClaimSide.theirs),
          await claim(sibling, ClaimSide.mine),
        ],
      );

      expect(outcome, CommitOutcome.applied);
      // The closed epoch was walked, and before the confirm.
      expect(
        rig.server.epochRequests.map((r) => r.pair),
        contains(const MlsPair(1, 1)),
      );
      expect(walkedBeforeConfirm, isTrue);
      expect(engineCalls('confirmCommit'), 1);
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      final described = await rig.device.engine.inner.describe(g.state);
      expect(described.hasPendingCommit, isFalse);
      expect(described.members, hasLength(4));
      // Pinned with the side each was checked for, from the new pair on.
      final carolPin = (await pin(carol))!;
      expect(carolPin.side, MemberSide.theirs);
      expect(carolPin.since, const MlsPair(1, 2));
      expect(rigEq(carolPin.signatureKey, carol.key), isTrue);
      expect((await pin(sibling))!.side, MemberSide.mine);
      // A "device added" row each (the own-side one is the own-device alert).
      final lines = await rig.lines(_c1);
      expect([
        for (final l in lines)
          if (l.line == SystemLine.deviceAdded) l.side,
      ], unorderedEquals([MemberSide.theirs, MemberSide.mine]));
      // The marks and the sync record.
      final record = (await rig.device.vault.conversation(_c1))!;
      expect(record.afterPair, const MlsPair(1, 1));
      expect(record.sync.epochMustAdvance, isFalse);
      // An add-only commit does not renew the leaf.
      expect(joinedAt, isNotNull);
      expect(record.sync.lastSelfUpdateAtMicros, joinedAt);
      expect(record.sync.commitCallsToday, 1);
      // The own change of today, and the key history admitted both.
      expect(
        await rig.ledger.isUndoOfOwnChange(_c1, carol.id, removing: true),
        isTrue,
      );
      expect(
        (await rig.keyHistoryIds(_c1)).keys,
        containsAll([vaultDeviceIdHex(carol.id), vaultDeviceIdHex(sibling.id)]),
      );
      // The welcome is stored for both, labelled with the built-on pair.
      expect(rig.server.welcomesFor(carol.idString), hasLength(1));
      expect(rig.server.welcomesFor(sibling.idString), hasLength(1));
      // The pair moved: a live pull of the new pair is owed before a send.
      expect(rig.contexts.of(_c1).syncedSinceStart, isFalse);
    });

    test('a removal deletes the pin, writes the row and renews the '
        'self-update date', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      expect((await pin(bob2))!.side, MemberSide.theirs);
      final joinedAt = (await sync()).lastSelfUpdateAtMicros;
      rig.clock.advance(const Duration(minutes: 1));

      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.applied,
      );

      expect(await pin(bob2), isNull);
      final removed = [
        for (final l in await rig.lines(_c1))
          if (l.line == SystemLine.deviceRemoved) l,
      ];
      expect(removed, hasLength(1));
      expect(rigEq(removed.single.deviceId!, bob2.id), isTrue);
      expect(removed.single.side, MemberSide.theirs);
      expect((await sync()).lastSelfUpdateAtMicros, isNot(joinedAt));
      expect(
        (await sync()).lastSelfUpdateAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
      expect(requests().single.welcome, isNull);
      expect(
        await rig.ledger.isUndoOfOwnChange(_c1, bob2.id, removing: false),
        isTrue,
      );
    });

    test('a self-update is applied and renews the self-update date', () async {
      await setUpJoined();
      await synced();
      var kind = '';
      rig.server.onCall = (call) async {
        if (call == 'commitConversation') {
          kind = (await groupRecord()).pending!.kind.name;
        }
      };
      final joinedAt = (await sync()).lastSelfUpdateAtMicros;
      rig.clock.advance(const Duration(minutes: 1));

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);

      expect(kind, 'selfUpdate');
      expect((await groupRecord()).epoch, 2);
      expect((await sync()).lastSelfUpdateAtMicros, isNot(joinedAt));
      expect(
        (await sync()).lastSelfUpdateAtMicros,
        rig.clock.now().microsecondsSinceEpoch,
      );
    });

    test('an add by this device that another device removes the same day is '
        'an undo', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.applied,
      );
      await bobApplies(const MlsPair(1, 1));

      await bobCommits(remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect(await rig.ledger.undone(_c1), 1);
    });

    test(
      'an own commit found by catch-up is confirmed, not sent again',
      () async {
        await setUpJoined();
        await synced();
        final carol = await RigPeer.create('carol');
        // The server stored the commit and its answer was lost; the resend
        // got no answer either.
        rig.server.commitScript
          ..add((error: offline, stored: true))
          ..add((error: offline, stored: false));
        expect(
          await rig.commits.change(
            _c1,
            adds: [await claim(carol, ClaimSide.theirs)],
          ),
          CommitOutcome.pending,
        );
        expect((await groupRecord()).pending, isNotNull);
        expect(requests(), hasLength(2));

        expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);

        expect(requests(), hasLength(2));
        final g = await groupRecord();
        expect(g.epoch, 2);
        expect(g.pending, isNull);
        expect(engineCalls('confirmCommit'), 1);
        expect(engineCalls('discardCommit'), 0);
        // The same run still knows the side the add was checked for.
        expect((await pin(carol))!.side, MemberSide.theirs);
      },
    );

    test('an own commit confirmed by any catch-up of the same run pins the '
        'adds with their checked side', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      final sibling = await RigPeer.create('sibling');
      rig.server.commitScript
        ..add((error: offline, stored: true))
        ..add((error: offline, stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [
            await claim(carol, ClaimSide.theirs),
            await claim(sibling, ClaimSide.mine),
          ],
        ),
        CommitOutcome.pending,
      );

      // Not the runner's resume: a catch-up of another caller (the sender,
      // the receiver) meets the commit first.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);

      expect((await groupRecord()).pending, isNull);
      expect((await pin(carol))!.side, MemberSide.theirs);
      expect((await pin(sibling))!.side, MemberSide.mine);
      expect([
        for (final l in await rig.lines(_c1))
          if (l.line == SystemLine.deviceAdded) l.side,
      ], unorderedEquals([MemberSide.theirs, MemberSide.mine]));
      // Nothing is left for the runner to settle.
      expect(await rig.commits.resumePending(_c1), CommitOutcome.notAllowed);
    });

    test('STALE_EPOCH: the winner is applied, the pending record is gone and '
        'the outcome is superseded', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      // Bob's commit takes the pair first.
      await bobSelfUpdate();
      final winner = rig.server.commitAt(_c1, const MlsPair(1, 1))!;

      final outcome = await rig.commits.change(
        _c1,
        adds: [await claim(carol, ClaimSide.theirs)],
      );

      expect(outcome, CommitOutcome.superseded);
      expect(requests(), hasLength(1));
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      expect(
        (await rig.device.engine.inner.describe(g.state)).hasPendingCommit,
        isFalse,
      );
      expect(
        rigEq(rig.server.commitAt(_c1, const MlsPair(1, 1))!, winner),
        isTrue,
      );
      // Nothing of the lost commit is kept: no pin, no own change.
      expect(await pin(carol), isNull);
      expect(
        await rig.ledger.isUndoOfOwnChange(_c1, carol.id, removing: true),
        isFalse,
      );
      expect(engineCalls('discardCommit'), 0);
    });

    test('a later success pair is handled like STALE_EPOCH', () async {
      await setUpJoined();
      await synced();
      // The first call is stored and its answer lost; before the resend bob
      // commits on top of it, so the resend's answer is two pairs on.
      rig.server.commitScript.add((error: offline, stored: true));
      var calls = 0;
      rig.server.onCall = (call) async {
        if (call != 'commitConversation' || ++calls != 2) return;
        await bobApplies(const MlsPair(1, 1));
        await bobSelfUpdate();
      };

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);

      expect(requests(), hasLength(2));
      expect(rig.server.current(_c1), const MlsPair(1, 3));
      expect(engineCalls('confirmCommit'), 1);
      expect(engineCalls('discardCommit'), 0);
      // The own commit was found by its bytes; bob's follows.
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      final g = await groupRecord();
      expect(g.epoch, 3);
      expect(g.pending, isNull);
    });

    test('a timeout resends identical bytes once, counts two calls and leaves '
        'the record pending', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));

      final outcome = await rig.commits.change(
        _c1,
        adds: [await claim(carol, ClaimSide.theirs)],
      );

      expect(outcome, CommitOutcome.pending);
      expect(requests(), hasLength(2));
      expect(requests()[0].sameBytes(requests()[1]), isTrue);
      expect(requests()[1].key, matches(_keyShape));
      expect((await sync()).commitCallsToday, 2);
      final g = await groupRecord();
      expect(g.epoch, 1);
      expect(rigEq(g.pending!.commit, requests()[0].commit), isTrue);
      expect(engineCalls('discardCommit'), 0);
      // Nothing more is built while that record stands.
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isFalse);
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.notAllowed);
      expect(requests(), hasLength(2));
    });

    test('a restart with a pending record resends the same bytes when the '
        'server pair has not moved', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );

      await rig.restart();
      rig.device.engine.calls.clear();
      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);

      expect(requests(), hasLength(3));
      expect(requests()[0].sameBytes(requests()[2]), isTrue);
      expect(requests()[2].key, isNot(requests()[0].key));
      // One more counted call; nothing was built again.
      expect((await sync()).commitCallsToday, 3);
      expect(engineCalls('commitChange'), 0);
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      // The checked side is not known after a restart: the list decides.
      expect((await pin(carol))!.side, MemberSide.unattributed);
    });

    // A negative (a runner that did nothing at all would pass it): it only
    // pins down that a resume with no record stays silent.
    test(
      'negative: resumePending with nothing pending makes no call',
      () async {
        await setUpJoined();
        await synced();
        rig.server.calls.clear();

        expect(await rig.commits.resumePending(_c1), CommitOutcome.notAllowed);

        expect(rig.server.calls, isEmpty);
      },
    );

    test(
      'CANNOT_MESSAGE discards the commit and marks the thread read-only',
      () async {
        await setUpJoined();
        await synced();
        final carol = await RigPeer.create('carol');
        rig.server.commitScript.add((
          error: const CannotMessageException(),
          stored: false,
        ));

        final outcome = await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        );

        expect(outcome, CommitOutcome.refused);
        expect(requests(), hasLength(1));
        expect(engineCalls('discardCommit'), 1);
        final g = await groupRecord();
        expect(g.epoch, 1);
        expect(g.pending, isNull);
        expect(
          (await rig.device.engine.inner.describe(g.state)).hasPendingCommit,
          isFalse,
        );
        expect(rig.contexts.of(_c1).canReply, isFalse);
        expect(await rig.commits.mayCommit(_c1, PendingKind.change), isFalse);
        expect(await pin(carol), isNull);
        // A refusal is a counted call.
        expect((await sync()).commitCallsToday, 1);
      },
    );

    test('a refusal on a resend whose first attempt was stored confirms the '
        'commit instead of discarding it', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: true))
        ..add((error: const FeatureDisabledException('off'), stored: false));

      final outcome = await rig.commits.change(
        _c1,
        adds: [await claim(carol, ClaimSide.theirs)],
      );

      expect(outcome, CommitOutcome.applied);
      expect(requests(), hasLength(2));
      expect(engineCalls('discardCommit'), 0);
      expect(engineCalls('confirmCommit'), 1);
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      expect((await pin(carol))!.side, MemberSide.theirs);
    });

    test('a refusal on a resend whose first attempt was not stored discards '
        'only after catch-up found no such commit', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: const FeatureDisabledException('off'), stored: false));
      rig.server.calls.clear();
      var discardedBeforeListing = false;
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits' && requests().length == 2) {
          discardedBeforeListing = engineCalls('discardCommit') > 0;
        }
      };

      // Inside the margin the record stays (the first call may still be
      // stored); after it, with one more listing, it is dropped.
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );
      rig.clock.advance(kRequestInFlightMargin);
      final outcome = await rig.commits.resumePending(_c1);

      expect(outcome, CommitOutcome.refused);
      expect(
        rig.server.calls.skipWhile((c) => c != 'commitConversation').toList(),
        containsAllInOrder([
          'commitConversation',
          'commitConversation',
          'listConversationCommits',
        ]),
      );
      expect(discardedBeforeListing, isFalse);
      expect(engineCalls('discardCommit'), 1);
      // The refused bytes were not sent a third time.
      expect(requests(), hasLength(2));
      final g = await groupRecord();
      expect(g.epoch, 1);
      expect(g.pending, isNull);
    });

    test('the epoch\'s messages are processed before the own commit is '
        'confirmed, so a lost own send in that epoch is still '
        'recognised', () async {
      await setUpJoined();
      await synced();
      // An own message of the current epoch whose local records are gone,
      // stored by the server after the last live pull.
      final v = rig.device.vault;
      final content = encodeMessageContent(
        text: 'lost',
        reportKey: Uint8List.fromList(List.filled(32, 7)),
      );
      final sent = await rig.device.engine.inner.encrypt(
        (await v.deviceState())!,
        (await groupRecord()).state,
        content,
      );
      const lostId = '000000000000000000000000000000aa';
      rig.server.addMessage(
        pb.Message(
          id: lostId,
          conversationId: _c1,
          fromSelf: true,
          state: MessageState.MESSAGE_STATE_VISIBLE,
          createdAt: ts.Timestamp.fromDateTime(rig.clock.now()),
          ciphertext: sent.ciphertext,
          mlsGeneration: Int64(1),
          mlsEpoch: Int64(1),
          reportCommitment: reportCommitment(content),
        ),
      );
      rig.device.engine.calls.clear();

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);

      // Processed at its own epoch, before the confirm.
      final calls = rig.device.engine.calls;
      expect(calls, contains('process'));
      expect(
        calls.indexOf('process'),
        lessThan(calls.indexOf('confirmCommit')),
      );
      // Recognised as a lost send (an own-leaf answer), not as a message of
      // another epoch.
      final row = (await v.message(_c1, lostId))!;
      expect(row.state, StoredMessageState.undecryptable);
      expect(row.mine, isTrue);
      // The commit moved the epoch on.
      expect((await sync()).epochMustAdvance, isFalse);
      expect((await groupRecord()).epoch, 2);
    });

    test('RATE_LIMITED discards and exposes the retry time', () async {
      await setUpJoined();
      await synced();
      expect(rig.commits.lastRateLimit, isNull);
      rig.server.commitScript.add((
        error: const RateLimitedException(
          'slow down',
          retryAfter: Duration(seconds: 90),
        ),
        stored: false,
      ));

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.refused);

      expect(
        rig.commits.lastRateLimit?.retryAfter,
        const Duration(seconds: 90),
      );
      expect(engineCalls('discardCommit'), 1);
      expect((await groupRecord()).pending, isNull);
      expect(rig.contexts.of(_c1).canReply, isTrue);
    });

    test('a busy answer with a retry time is not resent at once: one resume '
        'is scheduled for that time', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript.add((
        error: const ScreeningUnavailableException(
          'busy',
          retryAfter: Duration(seconds: 5),
        ),
        stored: false,
      ));

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);

      expect(requests(), hasLength(1));
      expect(rig.commitScheduled.map((s) => s.delay), [
        const Duration(seconds: 5),
      ]);
      // Scheduled outside the conversation lock's zone: the timer's
      // callback does not read as holding the lock it was scheduled under.
      final entry = rig.commitScheduled.single;
      expect(identical(entry.zone, Zone.root), isTrue);
      expect(entry.zone.run(() => rig.locks.isHeld(_c1)), isFalse);
      // Before that time nothing is sent, and no second resume is
      // scheduled for the conversation.
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(1));
      expect(rig.commitScheduled, hasLength(1));
      // At that time the timer's callback itself resumes: it takes the
      // lock, sends the same bytes once more and confirms.
      rig.clock.advance(const Duration(seconds: 5));
      await runScheduled();
      expect(requests(), hasLength(2));
      expect(requests()[0].sameBytes(requests()[1]), isTrue);
      expect((await sync()).commitCallsToday, 2);
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      expect(rig.commitScheduled, isEmpty);
      // The callback left the run's memory clean: nothing to cancel.
      rig.commits.reset();
      expect(entry.cancelled, isFalse);
    });

    test('an add whose leaf key is not the key it was checked with is '
        'pinned unattributed, with the key the group holds', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      final other = await RigPeer.create('other');
      // The claim was checked for another signature key than the one the
      // key package (and so the group's leaf) carries.
      final outcome = await rig.commits.change(
        _c1,
        adds: [
          UsableClaim(
            deviceId: carol.id,
            signatureKey: other.key,
            keyPackage: await carol.keyPackage(),
            side: ClaimSide.theirs,
          ),
        ],
      );

      expect(outcome, CommitOutcome.applied);
      final carolPin = (await pin(carol))!;
      expect(carolPin.side, MemberSide.unattributed);
      expect(rigEq(carolPin.signatureKey, carol.key), isTrue);
      expect([
        for (final l in await rig.lines(_c1))
          if (l.line == SystemLine.deviceAdded) l,
      ], isEmpty);
    });

    test('a theirs pin written by an own confirm stores the peer ref in the '
        'known set, as attribution does', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      // The known set holds the conversation but no peer ref for it.
      await rig.device.vault.transaction(
        (tx) => tx.putSetting(
          kVaultSettingKnownConversations,
          rigBytes('{"v":1,"ids":["$_c1"],"peers":{}}'),
        ),
      );
      await rig.known.load(rig.device.vault);
      expect(rig.known.contains(_c1), isTrue);
      expect(rig.known.peerOf(_c1), isNull);

      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.applied,
      );

      expect((await pin(carol))!.side, MemberSide.theirs);
      expect(rig.known.peerOf(_c1), 'ref-bob');
      // Stored, not only in memory.
      await rig.known.load(rig.device.vault);
      expect(rig.known.peerOf(_c1), 'ref-bob');
    });

    test('an own commit records as its own adds only the devices its '
        'welcome was addressed to', () async {
      await setUpJoined();
      final carol = await RigPeer.create('carol');
      rig.keys.peers['ref-bob'] = [
        rigKeyDevice(bob.idString, bob.key),
        rigKeyDevice(carol.idString, carol.key),
      ];
      await bobCommits(add: [await carol.keyPackage()]);
      await synced();
      // A member this device holds no pin for (bob added her).
      await rig.device.vault.transaction(
        (tx) => tx.deleteMember(_c1, carol.id),
      );
      expect(await pin(carol), isNull);

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);

      // The self-update's transaction pinned her, but she is no change of
      // this device: her removal by another device is not an undo.
      expect((await pin(carol))!.side, MemberSide.unattributed);
      expect(
        await rig.ledger.isUndoOfOwnChange(_c1, carol.id, removing: true),
        isFalse,
      );
      await bobApplies(const MlsPair(1, 2));
      await bobCommits(remove: [carol.id]);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect(await rig.ledger.undone(_c1), 0);
    });

    test('what this run remembers of a confirmed own commit is read once '
        'and forgotten at reset', () async {
      await setUpJoined();
      await synced();
      // Confirmed by the runner: the runner read it, so it is gone.
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);
      expect(rig.crypto.takeOwnCommitConfirmedAt(_c1), isNull);

      // Confirmed by another caller's catch-up: nobody reads it, and a
      // sign-out must not leave it for the next account's same pair.
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: true))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      expect((await groupRecord()).epoch, 3);
      rig.commits.reset();
      expect(rig.crypto.takeOwnCommitConfirmedAt(_c1), isNull);
    });

    test('a confirmed pair an earlier step left unread is dropped before the '
        'runner\'s catch-up, so a superseded record never reads as '
        'applied', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      final held = await groupRecord();
      final heldSync = await sync();
      expect(held.pending!.builtOn, const MlsPair(1, 1));

      // Another caller's catch-up confirms the record at (1, 1) by its
      // bytes (the listing shows them as this user's) and nobody reads
      // that: the entry for (1, 1) stays.
      rig.server.rewriteCommits = (real) => pb.ListConversationCommitsResponse(
        commits: [
          pb.ConversationCommit(
            mlsGeneration: Int64(1),
            mlsEpoch: Int64(1),
            commit: held.pending!.commit,
            fromSelf: true,
            createdAt: ts.Timestamp.fromDateTime(rig.clock.now()),
          ),
        ],
        mlsGeneration: Int64(1),
        mlsEpoch: Int64(2),
      );
      expect(await rig.crypto.catchUp(_c1), CatchUpResult.current);
      rig.server.rewriteCommits = null;
      expect((await groupRecord()).epoch, 2);

      // The group and its sync record are back at (1, 1) holding the same
      // record, and the server's commit at (1, 1) is bob's.
      await rig.device.vault.transaction((tx) async {
        await tx.putGroup(held);
        await tx.putConversationSync(_c1, heldSync);
      });
      await bobSelfUpdate();
      rig.clock.advance(kRequestInFlightMargin);

      expect(await rig.commits.resumePending(_c1), CommitOutcome.superseded);

      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      expect(requests(), hasLength(2));
    });

    test(
      'a server retry time holds a commit for five minutes at most',
      () async {
        await setUpJoined();
        await synced();
        expect(kCommitRetryWaitMax, const Duration(minutes: 5));
        rig.server.commitScript.add((
          error: const ScreeningUnavailableException(
            'busy',
            retryAfter: Duration(hours: 23),
          ),
          stored: false,
        ));

        expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);

        expect(rig.commitScheduled.map((s) => s.delay), [kCommitRetryWaitMax]);
        rig.clock.advance(kCommitRetryWaitMax - const Duration(seconds: 1));
        expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
        expect(requests(), hasLength(1));
        rig.clock.advance(const Duration(seconds: 1));
        expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);
        expect(requests(), hasLength(2));
      },
    );
  });

  group('the discard margin', () {
    const second = Duration(seconds: 1);

    test('the margin is the server\'s request deadline plus the client\'s '
        'own wait, the one the starter uses', () {
      expect(kRequestInFlightMargin, const Duration(seconds: 60));
    });

    test('a refusal on a resend inside the margin leaves the record and '
        'schedules one resume; after the margin it discards', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      // The first call got no answer (it may still be stored); the resend
      // is refused.
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: const FeatureDisabledException('off'), stored: false));

      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );

      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(rig.commitScheduled.map((s) => s.delay), [kRequestInFlightMargin]);
      // A resume before the margin's end: no discard, no call, no second
      // scheduled resume.
      rig.clock.advance(kRequestInFlightMargin - second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(requests(), hasLength(2));
      expect(rig.commitScheduled, hasLength(1));

      // At its end the scheduled resume drops the commit, with no call.
      rig.clock.advance(second);
      final ran = rig.commitScheduled.single;
      await runScheduled();

      expect(engineCalls('discardCommit'), 1);
      final g = await groupRecord();
      expect(g.epoch, 1);
      expect(g.pending, isNull);
      expect(requests(), hasLength(2));
      expect(rig.commitScheduled, isEmpty);
      // A resume that ran is no longer held: a reset has nothing to cancel.
      rig.commits.reset();
      expect(ran.cancelled, isFalse);
    });

    test('reset and cancelScheduled cancel a scheduled resume, and a later '
        'one can be scheduled again', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: const FeatureDisabledException('off'), stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );
      final first = rig.commitScheduled.single;
      expect(first.cancelled, isFalse);

      // The app is paused: the timer goes, the memory stays.
      rig.commits.cancelScheduled();
      expect(first.cancelled, isTrue);
      rig.commitScheduled.clear();
      // The next trigger inside the margin schedules the resume again.
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      final again = rig.commitScheduled.single;
      expect(again.cancelled, isFalse);

      // Sign-out.
      rig.commits.reset();
      expect(again.cancelled, isTrue);
    });

    test('after a restart a refusal on a resend waits the margin too, then '
        'discards', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );

      await rig.restart();
      rig.device.engine.calls.clear();
      rig.commitScheduled.clear();
      rig.server.commitScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);

      expect(requests(), hasLength(3));
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(rig.commitScheduled.map((s) => s.delay), [kRequestInFlightMargin]);

      rig.clock.advance(kRequestInFlightMargin - second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(engineCalls('discardCommit'), 0);
      rig.clock.advance(second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.refused);

      expect(engineCalls('discardCommit'), 1);
      expect((await groupRecord()).pending, isNull);
      expect(requests(), hasLength(3));
    });

    test('after a restart a record that can no longer be sent is kept for '
        'the margin from its first sight in this run', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );

      // A long time later, in a new run: when the earlier run last called
      // is not stored, so this run's first sight of the record counts.
      rig.clock.advance(const Duration(hours: 1));
      await rig.restart();
      rig.device.engine.calls.clear();
      rig.commitScheduled.clear();
      // The flag went off: the add may not be sent again.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: rig.device.uid);

      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);

      expect(requests(), hasLength(2));
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(rig.commitScheduled.map((s) => s.delay), [kRequestInFlightMargin]);

      rig.clock.advance(kRequestInFlightMargin - second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(engineCalls('discardCommit'), 0);
      rig.clock.advance(second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.notAllowed);

      expect(engineCalls('discardCommit'), 1);
      expect((await groupRecord()).pending, isNull);
      expect(requests(), hasLength(2));
    });

    test('an unknown outcome with no server time holds the next resend for '
        'the margin: two resumes inside it make one call in total', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(2));
      // In the same run: no call before the margin's end.
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(2));

      // A new run resends at once (it knows no earlier time), and then
      // holds the same way.
      await rig.restart();
      rig.server.commitScript.add((error: offline, stored: false));
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(3));
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(3));
      rig.clock.advance(kRequestInFlightMargin - second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(3));
      expect((await sync()).commitCallsToday, 3);

      rig.clock.advance(second);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);
      expect(requests(), hasLength(4));
      expect(requests()[0].sameBytes(requests()[3]), isTrue);
    });

    test('a pending commit on a group that is no longer the highest '
        'generation is superseded: never sent again, never held', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      rig.clock.advance(kRequestInFlightMargin);
      rig.device.engine.calls.clear();
      // While the resume's catch-up runs, a group of the next generation is
      // stored (a generation switch): the old group still carries the
      // record, but it is not the conversation's group any more.
      var stored = false;
      rig.server.onCall = (call) async {
        if (call != 'listConversationCommits' || stored) return;
        stored = true;
        final old = await groupRecord();
        await rig.device.vault.transaction(
          (tx) => tx.putGroup(
            GroupRecord(
              conversationId: _c1,
              generation: 2,
              epoch: 0,
              state: old.state,
            ),
          ),
        );
      };

      final outcome = await rig.commits.resumePending(_c1);

      rig.server.onCall = null;
      expect(stored, isTrue);
      expect(outcome, CommitOutcome.superseded);
      expect(requests(), hasLength(2));
      expect(engineCalls('discardCommit'), 0);
      expect((await rig.device.vault.groups(_c1)).last.generation, 2);
    });

    test('a call count that could not be written is not the cap: the record '
        'stays and is sent by the next resume', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      // Past the margin, so nothing but the count stands before a discard.
      rig.clock.advance(kRequestInFlightMargin);
      rig.device.engine.calls.clear();
      // The write asked for after the resume's commit listing is the count
      // of the call it is about to make: that write fails.
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') {
          rig.device.failNextWriteAsked = true;
        }
      };

      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);

      rig.server.onCall = null;
      expect(rig.device.writesRefused, 1);
      expect(rig.device.failNextWriteAsked, isFalse);
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(requests(), hasLength(2));
      expect((await sync()).commitCallsToday, 2);

      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);
      expect(requests(), hasLength(3));
    });

    test('the margin is measured at the listing that proves the discard, not '
        'when catch-up returned (review N1)', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );
      // The flag went off: the add may not be sent again.
      await rig.device.session.onFlagChanged(E2eeFlag.off, uid: rig.device.uid);
      rig.device.engine.calls.clear();
      rig.commitScheduled.clear();
      // The resume's listing is taken one second before the margin's end;
      // its answer arrives one second after it.
      rig.clock.advance(kRequestInFlightMargin - second);
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits') rig.clock.advance(second * 2);
      };

      final outcome = await rig.commits.resumePending(_c1);

      rig.server.onCall = null;
      expect(outcome, CommitOutcome.pending);
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(requests(), hasLength(2));
      // The margin's end has passed by now: the one resume runs at once and
      // lists again.
      expect(rig.commitScheduled.map((s) => s.delay), [Duration.zero]);
      await runScheduled();
      expect(engineCalls('discardCommit'), 1);
      expect((await groupRecord()).pending, isNull);
      expect(requests(), hasLength(2));
    });
  });

  group('the paths that discard or keep a commit', () {
    for (final cause in ['flag', 'cap', 'm5', 'readOnly', 'unaccepted']) {
      test('a resume discards a record that can no longer be sent '
          '($cause), with no call', () async {
        final bob2 = await RigPeer.create('bob2');
        await setUpJoined(others: [bob2]);
        await synced();
        final carol = await RigPeer.create('carol');
        rig.server.commitScript
          ..add((error: offline, stored: false))
          ..add((error: offline, stored: false));
        // The flag only matters for an add; the others are shown on a
        // removal.
        expect(
          cause == 'flag'
              ? await rig.commits.change(
                  _c1,
                  adds: [await claim(carol, ClaimSide.theirs)],
                )
              : await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
          CommitOutcome.pending,
        );
        rig.clock.advance(kRequestInFlightMargin);
        rig.device.engine.calls.clear();
        // Control: as it stands the record would be sent again.
        expect((await groupRecord()).pending, isNotNull);
        switch (cause) {
          case 'flag':
            await rig.device.session.onFlagChanged(
              E2eeFlag.off,
              uid: rig.device.uid,
            );
          case 'cap':
            await setCalls(kCommitCallsPerConversationPerDay);
          case 'm5':
            for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
              await rig.ledger.addUndone(_c1);
            }
          case 'readOnly':
            rig.contexts.of(_c1).canReply = false;
          case 'unaccepted':
            // R10 for a record built while accepted (or left by an earlier
            // run): the stored record no longer says accepted.
            final next = (await sync()).copyWith(requestAccepted: false);
            await rig.device.vault.transaction(
              (tx) => tx.putConversationSync(_c1, next),
            );
        }

        expect(await rig.commits.resumePending(_c1), CommitOutcome.notAllowed);

        expect(requests(), hasLength(2));
        expect(engineCalls('discardCommit'), 1);
        final g = await groupRecord();
        expect(g.epoch, 1);
        expect(g.pending, isNull);
        expect(
          (await rig.device.engine.inner.describe(g.state)).hasPendingCommit,
          isFalse,
        );
        // Nothing of the dropped change is kept.
        expect(await pin(carol), isNull);
        expect(await pin(bob2), isNotNull);
        // The conversation is free again: no record holds its sends.
        expect(await rig.commits.resumePending(_c1), CommitOutcome.notAllowed);
        expect(engineCalls('discardCommit'), 1);
      });
    }

    test('a record that can still be sent is not discarded by a resume '
        '(the control of the four cases above)', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.pending,
      );
      rig.clock.advance(kRequestInFlightMargin);

      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);

      expect(requests(), hasLength(3));
      expect(engineCalls('discardCommit'), 0);
      expect(await pin(bob2), isNull);
    });

    test('a refusal on a resend keeps the record while catch-up does not '
        'reach the server\'s pair, however long that takes', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: const FeatureDisabledException('off'), stored: false));
      // From the refused resend on, the commit listing fails: nothing
      // shows that the server does not hold the first call's commit.
      var listingFails = true;
      rig.server.onCall = (call) async {
        if (call == 'listConversationCommits' &&
            requests().length == 2 &&
            listingFails) {
          throw offline;
        }
      };

      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );
      expect(engineCalls('discardCommit'), 0);
      // No proof, so not even a resume is scheduled for a discard.
      expect(rig.commitScheduled, isEmpty);

      // Long after the margin, still without a listing: the record stays.
      rig.clock.advance(kRequestInFlightMargin * 10);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);
      expect(requests(), hasLength(2));

      // The listing answers again and shows no commit at the pair: now the
      // refused commit is dropped, and not sent a third time.
      listingFails = false;
      expect(await rig.commits.resumePending(_c1), CommitOutcome.refused);
      expect(engineCalls('discardCommit'), 1);
      expect((await groupRecord()).pending, isNull);
      expect(requests(), hasLength(2));
    });

    test('a refusal on a resend whose first call the server stored in the '
        'meantime is confirmed by the resume after the margin', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: const FeatureDisabledException('off'), stored: false));
      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );
      expect(engineCalls('discardCommit'), 0);
      // The race the margin exists for: the first call, which the client
      // gave up on, is stored by the server after the listing above.
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 1),
        requests().first.commit,
        fromUser: 'user-a',
      );

      rig.clock.advance(kRequestInFlightMargin);
      await runScheduled();

      expect(engineCalls('discardCommit'), 0);
      expect(engineCalls('confirmCommit'), 1);
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      expect((await pin(carol))!.side, MemberSide.theirs);
    });

    test('CANNOT_MESSAGE on a resend still marks the thread read-only, and '
        'RATE_LIMITED on a resend still exposes the retry time', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: const CannotMessageException(), stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      expect(rig.contexts.of(_c1).canReply, isFalse);
      // Not discarded at once (it was not the first call).
      expect(engineCalls('discardCommit'), 0);
      rig.clock.advance(kRequestInFlightMargin);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.refused);
      expect((await groupRecord()).pending, isNull);

      rig.contexts.of(_c1).canReply = true;
      await synced();
      expect(rig.commits.lastRateLimit, isNull);
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((
          error: const RateLimitedException(
            'slow down',
            retryAfter: Duration(seconds: 90),
          ),
          stored: false,
        ));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      expect(
        rig.commits.lastRateLimit?.retryAfter,
        const Duration(seconds: 90),
      );
      expect(rig.contexts.of(_c1).canReply, isTrue);
      expect((await groupRecord()).pending, isNotNull);
    });

    test('a confirm interrupted after the server accepted leaves the record '
        'pending, and the next resume confirms it without a call', () async {
      await setUpJoined();
      await synced();
      final carol = await RigPeer.create('carol');
      // The walk of the closed epoch fails once, after the commit call.
      var failed = false;
      rig.server.onCall = (call) async {
        if (call == 'listEpochMessages' && requests().isNotEmpty && !failed) {
          failed = true;
          throw offline;
        }
      };

      expect(
        await rig.commits.change(
          _c1,
          adds: [await claim(carol, ClaimSide.theirs)],
        ),
        CommitOutcome.pending,
      );

      expect(failed, isTrue);
      expect(requests(), hasLength(1));
      expect(rig.server.current(_c1), const MlsPair(1, 2));
      expect(engineCalls('confirmCommit'), 0);
      final held = await groupRecord();
      expect(held.epoch, 1);
      expect(held.pending, isNotNull);

      // While the receiver's walk backoff from that failed listing lasts,
      // the walk cannot end: a resume keeps the record and sends nothing.
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);
      expect(requests(), hasLength(1));
      expect(engineCalls('confirmCommit'), 0);
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);

      // After it, the next resume's catch-up meets the commit by its bytes
      // and confirms it: no commit call.
      rig.clock.advance(kWalkBackoff);
      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);

      expect(requests(), hasLength(1));
      expect(engineCalls('confirmCommit'), 1);
      expect(engineCalls('discardCommit'), 0);
      final g = await groupRecord();
      expect(g.epoch, 2);
      expect(g.pending, isNull);
      // The same run still knows the checked side.
      expect((await pin(carol))!.side, MemberSide.theirs);
    });

    test('a reused idempotency key on the first call is never a first '
        'refusal: catch-up decides', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript.add((
        error: const IdempotencyKeyReusedException('reused'),
        stored: false,
      ));
      rig.server.calls.clear();

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);

      // Not discarded like a first refusal: the listing was asked, and the
      // record waits for the margin.
      expect(
        rig.server.calls.skipWhile((c) => c != 'commitConversation'),
        containsAllInOrder(['commitConversation', 'listConversationCommits']),
      );
      expect(requests(), hasLength(1));
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).pending, isNotNull);

      // When the server does hold the commit under that key, it is
      // confirmed.
      rig.server.addCommit(
        _c1,
        const MlsPair(1, 1),
        requests().single.commit,
        fromUser: 'user-a',
      );
      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);
      expect(engineCalls('discardCommit'), 0);
      expect((await groupRecord()).epoch, 2);
    });

    test('resumePending on a device removed elsewhere answers pending: no '
        'call of any kind, nothing discarded', () async {
      await setUpJoined();
      await synced();
      rig.server.commitScript
        ..add((error: offline, stored: false))
        ..add((error: offline, stored: false));
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);
      rig.clock.advance(kRequestInFlightMargin);
      rig.server.calls.clear();
      rig.device.engine.calls.clear();

      rig.removedElsewhere = true;
      expect(await rig.commits.resumePending(_c1), CommitOutcome.pending);

      expect(rig.server.calls, isEmpty);
      expect(rig.device.engine.calls, isEmpty);
      expect((await groupRecord()).pending, isNotNull);
      expect(rig.commitScheduled, isEmpty);

      // The same record, once the fact is gone, is settled as usual.
      rig.removedElsewhere = false;
      expect(await rig.commits.resumePending(_c1), CommitOutcome.applied);
    });
  });

  group('when a commit may be made', () {
    test('no commit of any kind in an unaccepted conversation, received or '
        'sent', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(accepted: false, others: [bob2]);
      await rig.crypto.catchUp(_c1);
      await rig.receiver.pullLive(_c1);
      final carol = await RigPeer.create('carol');
      // The runner reads only the stored acceptance, never the request's
      // direction; both directions are run so that a runner which took
      // "sent by me" (or "received") as leave to commit fails here.
      for (final incoming in [true, false]) {
        // Every other condition holds: only the acceptance is missing.
        rig.contexts.of(_c1)
          ..incomingRequest = incoming
          ..syncedSinceStart = true
          ..canReply = true;

        expect(await rig.commits.mayCommit(_c1, PendingKind.change), isFalse);
        expect(
          await rig.commits.mayCommit(_c1, PendingKind.selfUpdate),
          isFalse,
        );
        expect(
          await rig.commits.change(
            _c1,
            adds: [await claim(carol, ClaimSide.theirs)],
          ),
          CommitOutcome.notAllowed,
        );
        expect(
          await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
          CommitOutcome.notAllowed,
        );
        expect(await rig.commits.selfUpdate(_c1), CommitOutcome.notAllowed);
        // A resume of a pending record in an unaccepted conversation is the
        // `unaccepted` case of "a resume discards a record that can no
        // longer be sent": here nothing was built, so nothing is pending.
      }
      expect(requests(), isEmpty);
      expect(engineCalls('commitChange'), 0);
      expect(engineCalls('selfUpdate'), 0);
      expect((await groupRecord()).pending, isNull);
      expect((await sync()).commitCallsToday, 0);

      // The same device, once the conversation is accepted, may.
      await rig.device.vault.transaction(
        (tx) async => tx.putConversationSync(
          _c1,
          (await sync()).copyWith(requestAccepted: true),
        ),
      );
      await synced();
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isTrue);
    });

    test('no add with the flag off or unknown, a removal and a self-update '
        'still go', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      final carol = await RigPeer.create('carol');
      for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
        await rig.device.session.onFlagChanged(flag, uid: rig.device.uid);
        expect(rig.device.session.mayStart, isFalse);

        expect(
          await rig.commits.change(
            _c1,
            adds: [await claim(carol, ClaimSide.theirs)],
          ),
          CommitOutcome.notAllowed,
        );
        // Not even together with a removal: the caller sends the removal
        // alone.
        expect(
          await rig.commits.change(
            _c1,
            adds: [await claim(carol, ClaimSide.theirs)],
            removeDeviceIds: [bob2.id],
          ),
          CommitOutcome.notAllowed,
        );
      }
      expect(requests(), isEmpty);
      expect(engineCalls('commitChange'), 0);

      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.applied,
      );
      await synced();
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);
      expect(requests(), hasLength(2));
      expect((await groupRecord()).epoch, 3);
    });

    test('no commit at 20 calls today, no self-update at 10', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      await setCalls(kSelfUpdateMaxCommitCallsToday - 1);
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isTrue);

      await setCalls(kSelfUpdateMaxCommitCallsToday);
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isFalse);
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.notAllowed);
      expect(await rig.commits.mayCommit(_c1, PendingKind.change), isTrue);

      await setCalls(kCommitCallsPerConversationPerDay);
      expect(await rig.commits.mayCommit(_c1, PendingKind.change), isFalse);
      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.notAllowed,
      );
      expect(requests(), isEmpty);
      expect(engineCalls('commitChange'), 0);
      expect(engineCalls('selfUpdate'), 0);

      // One below the cap a change still goes, and takes the last call.
      await setCalls(kCommitCallsPerConversationPerDay - 1);
      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.applied,
      );
      expect(
        (await sync()).commitCallsToday,
        kCommitCallsPerConversationPerDay,
      );
    });

    test('the resend of an unknown outcome is a counted call: none at the '
        'cap', () async {
      await setUpJoined();
      await synced();
      await setCalls(kSelfUpdateMaxCommitCallsToday - 1);
      rig.server.commitScript.add((error: offline, stored: false));

      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.pending);

      expect(requests(), hasLength(1));
      expect((await sync()).commitCallsToday, kSelfUpdateMaxCommitCallsToday);
      expect((await groupRecord()).pending, isNotNull);
    });

    test('the count starts again on the next IST day', () async {
      await setUpJoined();
      await synced();
      await setCalls(kCommitCallsPerConversationPerDay);
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.notAllowed);

      rig.clock.advance(const Duration(days: 1));
      await synced();
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isTrue);
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.applied);

      final s = await sync();
      expect(s.commitCallsDay, istDay(rig.clock.now()));
      expect(s.commitCallsToday, 1);
    });

    test('two undos today: no change until the next IST day, a self-update '
        'still goes', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      await synced();
      for (var i = 0; i < kAntiFlapUndosPerDay; i++) {
        expect(await rig.commits.mayCommit(_c1, PendingKind.change), isTrue);
        await rig.ledger.addUndone(_c1);
      }

      expect(await rig.commits.mayCommit(_c1, PendingKind.change), isFalse);
      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.notAllowed,
      );
      expect(requests(), isEmpty);
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isTrue);

      rig.clock.advance(const Duration(days: 1));
      expect(await rig.commits.mayCommit(_c1, PendingKind.change), isTrue);
    });

    test('not synced since the start, removed elsewhere, a read-only thread '
        'or nothing to change: no commit', () async {
      final bob2 = await RigPeer.create('bob2');
      await setUpJoined(others: [bob2]);
      // Not synced yet in this run.
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isFalse);
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.notAllowed);
      await synced();
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isTrue);

      rig.removedElsewhere = true;
      expect(await rig.commits.mayCommit(_c1, PendingKind.selfUpdate), isFalse);
      expect(await rig.commits.selfUpdate(_c1), CommitOutcome.notAllowed);
      rig.removedElsewhere = false;

      rig.contexts.of(_c1).canReply = false;
      expect(await rig.commits.mayCommit(_c1, PendingKind.change), isFalse);
      expect(
        await rig.commits.change(_c1, removeDeviceIds: [bob2.id]),
        CommitOutcome.notAllowed,
      );
      rig.contexts.of(_c1).canReply = true;

      // An empty change, this device's own removal, and the kinds that are
      // not this runner's.
      expect(await rig.commits.change(_c1), CommitOutcome.notAllowed);
      expect(
        await rig.commits.change(_c1, removeDeviceIds: [rig.device.deviceId]),
        CommitOutcome.notAllowed,
      );
      expect(await rig.commits.mayCommit(_c1, PendingKind.init), isFalse);
      expect(await rig.commits.mayCommit(_c1, PendingKind.reset), isFalse);
      expect(requests(), isEmpty);
      expect(engineCalls('commitChange'), 0);
      expect(engineCalls('selfUpdate'), 0);
    });
  });
}
