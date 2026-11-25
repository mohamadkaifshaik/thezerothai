import 'dart:async';

import 'package:dzeroth/app/e2ee_wiring.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_pipeline.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:dzeroth/features/messages/domain/e2ee/message_content_codec.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/share_post_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as kpb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/e2ee_pipeline_rig.dart';
import '../../../../support/fake_send_repository.dart';
import '../../../../support/fake_vault_world.dart';

// Plan 5a Task 13b, step 13b-i: EncryptedMessagingImpl's send path, its
// unsent rows, and the thin maps (reset, device keys, hasLocal), over the
// real pipeline and the rig (task-13-gates.md "Task 13b", items 1-25, 33-35).
// The thread, preview, search, code, report and device-list members are step
// 13b-ii's.

const _c1 = '11111111111111111111111111111111';
const _c2 = '22222222222222222222222222222222';

/// A public id (`u`, then 26 lower-case Crockford characters, the first
/// 0-7): the other id kind than the rig's `ref-*` references.
const _publicBob = 'u0123456789abcdefghjkmnpqrs';

ThreadRef _to(String ref) =>
    ThreadRef.recipientOf(common.AuthorSnapshot(userId: ref));

Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 500; i++) {
    if (await done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('the condition never held');
}

void main() {
  late PipelineHarness h;
  late RigPeer bob;
  late EncryptedMessagingImpl port;

  setUp(() async {
    h = await PipelineHarness.create();
    bob = await RigPeer.create('bob');
    h.rig.keys.peers['ref-bob'] = [rigKeyDevice(bob.idString, bob.key)];
    port = EncryptedMessagingImpl(h.pipeline);
  });

  tearDown(() => h.dispose());

  Future<int> outboxCount() async =>
      (await h.rig.device.vault.outbox()).items.length;

  /// [ref] can be started with: a listed device whose claim answers [id].
  Future<RigPeer> startable(String ref, String id) async {
    final p = await RigPeer.create(ref);
    h.rig.keys.peers[ref] = [rigKeyDevice(p.idString, p.key)];
    h.rig.keys.claims[ref] = () async => kpb.ClaimKeyPackagesResponse(
      conversationId: id,
      keyPackages: [
        kpb.ClaimedKeyPackage(
          deviceId: p.idString,
          signaturePublicKey: p.key,
          keyPackage: await p.keyPackage(),
          hasKeyPackage_4: true,
        ),
      ],
    );
    h.rig.server.recipients[ref] = id;
    h.rig.server.rows[id] = pb.Conversation(
      id: id,
      peer: common.AuthorSnapshot(userId: ref),
      folder: Folder.FOLDER_INBOX,
      canReply: true,
      state: ConversationState.CONVERSATION_STATE_ACCEPTED,
    );
    return p;
  }

  /// A second pipeline and port over [session] with the harness's other
  /// collaborators (a device with no open vault).
  Future<({E2eePipeline pipeline, EncryptedMessagingImpl port})> over(
    VaultSession session,
  ) async {
    final pipeline = E2eePipeline(
      session: session,
      deviceKeys: h.deviceKeys,
      engine: () {
        h.engineAsked++;
        return h.guarded;
      },
      messaging: h.messaging,
      keys: h.rig.keys,
      ownUserId: () => 'user-a',
      currentUid: () => 'user-a',
      encryptionRequired: () => h.encryptionRequired,
      now: h.rig.clock.now,
      onUnexpectedError: (e, _) => h.reported.add(e),
    );
    addTearDown(pipeline.dispose);
    return (pipeline: pipeline, port: EncryptedMessagingImpl(pipeline));
  }

  Future<VaultSession> noVault(E2eeFlag flag, {bool unreadable = false}) async {
    final world = FakeVaultWorld();
    if (unreadable) world.markers.failKnownReads = true;
    final s = world.launch();
    await s.start(restoredUid: 'user-a', restoreDefinitive: true);
    await s.onSignedIn('user-a', flag: flag);
    return s;
  }

  group('send (gate items 1-11)', () {
    test('send into an encrypted conversation is queued and its entry id is '
        'the caller\'s localId until delivery; the idempotency key on the '
        'wire is not the localId', () async {
      await h.offer(_c1, bob);
      await h.ready();
      final hold = Completer<void>();
      h.rig.server.beforeSend = (_) => hold.future;

      final out = await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'hi',
      );
      expect(out.kind, SendOutcomeKind.queued);
      expect(out.conversationId, _c1);
      await _until(() async => h.rig.server.sends.isNotEmpty);

      final entries = await port.unsentEntries(
        const ThreadRef.conversation(_c1),
      );
      expect(entries!.single.id, 'local-1');
      expect(entries.single.mine, isTrue);
      expect(entries.single.text, 'hi');
      expect(entries.single.progress, SendProgress.sending);

      hold.complete();
      await h.pipeline.sender.settled(_c1);
      await h.settle();
      expect(
        await port.unsentEntries(const ThreadRef.conversation(_c1)),
        isEmpty,
      );
      expect(h.rig.server.sends.single.key, isNot('local-1'));
      expect(h.rig.server.sends.single.key, hasLength(32));
    });

    test('send to a peer with no listed device (a readable, empty list) is '
        'notEncrypted and stores nothing', () async {
      h.rig.keys.peers['ref-carol'] = [];
      await h.ready();
      final out = await port.send(
        to: _to('ref-carol'),
        localId: 'local-1',
        text: 'hi',
      );
      expect(out.kind, SendOutcomeKind.notEncrypted);
      expect(out.conversationId, isNull);
      expect(await outboxCount(), 0);
      expect(h.rig.server.sends, isEmpty);
      expect(h.rig.keys.claimCalls, isEmpty);
    });

    test('a share addressed by recipient to a peer with a stored group is '
        'queued as encrypted, even when the device list answers empty '
        '(C1 3a)', () async {
      await h.offer(_c1, bob);
      await h.ready();
      h.rig.keys.peers['ref-bob'] = [];
      final out = await port.send(
        to: _to('ref-bob'),
        localId: 'local-1',
        text: '',
        sharedPostId: 'post-1',
      );
      expect(out.kind, SendOutcomeKind.queued);
      expect(out.conversationId, _c1);
      final row = (await h.rig.device.vault.outbox()).items.single;
      expect(row.localId, 'local-1');
      expect(decodeMessageContentLenient(row.content).sharedPostId, 'post-1');
      await h.pipeline.sender.settled(_c1);
    });

    test('with a vault known on this device and not ready every send is '
        'refused blocked and nothing is saved (C1 step 5)', () async {
      await h.ready();
      h.rig.keys.peers['ref-carol'] = [];
      final gets = h.rig.keys.getCalls.length;
      h.rig.device.owner!.steal();
      await pumpEventQueue();
      final session = h.rig.device.session;
      expect(session.vault, isNull);
      expect(session.vaultKnown, isTrue);

      for (final flag in [E2eeFlag.on, E2eeFlag.off, E2eeFlag.unknown]) {
        await session.onFlagChanged(flag, uid: 'user-a');
        for (final to in [
          const ThreadRef.conversation(_c2),
          _to('ref-carol'),
        ]) {
          final out = await port.send(to: to, localId: 'local-1', text: 'hi');
          expect(out.kind, SendOutcomeKind.refused, reason: '$flag');
          expect(out.problem, SendProblem.blocked, reason: '$flag');
        }
      }
      expect(h.rig.keys.getCalls, hasLength(gets));
      expect(h.rig.keys.claimCalls, isEmpty);
      expect(h.rig.server.sends, isEmpty);
    });

    test(
      'with no vault on this device a conversation whose cached row was '
      'ever encrypted is refused blocked, never notEncrypted (C1, R1)',
      () async {
        h.rig.server.everEncrypted.add(_c1);
        h.rig.server.rows[_c1] = pb.Conversation(
          id: _c1,
          peer: common.AuthorSnapshot(userId: 'ref-bob'),
          folder: Folder.FOLDER_INBOX,
          canReply: true,
        );
        for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
          final s = await noVault(flag);
          expect(s.status.value, VaultStatus.off);
          expect(s.vaultKnown, isFalse);
          final p = (await over(s)).port;

          for (final to in [
            const ThreadRef.conversation(_c1),
            _to('ref-bob'),
          ]) {
            final out = await p.send(to: to, localId: 'local-1', text: 'hi');
            expect(
              (out.kind, out.problem),
              (SendOutcomeKind.refused, SendProblem.blocked),
              reason: '$flag',
            );
          }
          for (final to in [
            const ThreadRef.conversation(_c2),
            _to('ref-dave'),
          ]) {
            final out = await p.send(to: to, localId: 'local-1', text: 'hi');
            expect(out.kind, SendOutcomeKind.notEncrypted, reason: '$flag');
          }
        }
        expect(h.rig.keys.getCalls, isEmpty);
        expect(h.rig.keys.listCalls, 0);
        expect(h.rig.keys.claimCalls, isEmpty);
        expect(h.rig.server.sends, isEmpty);
        expect(h.engineAsked, 0);
      },
    );

    // Plan 5b Task 14 last round, item 1: this pinned test used the flag KNOWN
    // OFF (old expectation: refused retryable). With the flag known off the
    // port now goes on to the cache check (notEncrypted for an unmarked
    // conversation; covered by encrypted_messaging_flag_off_send_test.dart).
    // The F5 rule itself still holds where the flag is not known off, so this
    // test now runs with the flag UNKNOWN.
    test(
      'a device whose vault marker cannot be read answers try again '
      '(retryable), never notEncrypted or blocked (F5), flag unknown',
      () async {
        final s = await noVault(E2eeFlag.unknown, unreadable: true);
        expect(s.status.value, VaultStatus.unavailable);
        expect(s.vaultKnown, isFalse);
        final p = (await over(s)).port;
        for (final to in [const ThreadRef.conversation(_c2), _to('ref-dave')]) {
          final out = await p.send(to: to, localId: 'local-1', text: 'hi');
          expect(
            (out.kind, out.problem),
            (SendOutcomeKind.refused, SendProblem.retryable),
          );
        }
        expect(h.rig.keys.getCalls, isEmpty);
      },
    );

    test('a recipient ref of the other id kind with an empty device list is '
        'never notEncrypted when a cached row for that peer is encrypted '
        '(second re-read R1)', () async {
      await h.ready();
      // The known set stores the peer in kind A for _c1; _c1's cached row is
      // marked encrypted and names the same person in kind B.
      await h.pipeline.known.add(_c1, peerUserId: 'ref-bob');
      h.rig.server.everEncrypted.add(_c1);
      h.rig.server.rows[_c1] = pb.Conversation(
        id: _c1,
        peer: common.AuthorSnapshot(userId: _publicBob),
        folder: Folder.FOLDER_INBOX,
        canReply: true,
      );
      h.rig.keys.peers[_publicBob] = [];

      for (final flag in [E2eeFlag.on, E2eeFlag.off]) {
        await h.rig.device.session.onFlagChanged(flag, uid: 'user-a');
        final out = await port.send(
          to: _to(_publicBob),
          localId: 'local-1',
          text: 'hi',
        );
        expect(
          (out.kind, out.problem),
          (SendOutcomeKind.refused, SendProblem.blocked),
          reason: '$flag',
        );
      }
      expect(h.rig.keys.claimCalls, isEmpty);
      expect(h.rig.server.sends, isEmpty);
      expect(await outboxCount(), 0);
    });

    test('an unreadable lookup is refused retryable and nothing is sent; a '
        'CANNOT_MESSAGE lookup is refused with that error (H1)', () async {
      await h.ready();
      h.rig.keys.peerFails = true;
      var out = await port.send(
        to: _to('ref-carol'),
        localId: 'local-1',
        text: 'hi',
      );
      expect(
        (out.kind, out.problem, out.error),
        (SendOutcomeKind.refused, SendProblem.retryable, null),
      );

      h.rig.keys
        ..peerFails = false
        ..peerError = const CannotMessageException();
      out = await port.send(
        to: _to('ref-dave'),
        localId: 'local-2',
        text: 'hi',
      );
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.refused),
      );
      expect(out.error, isA<CannotMessageException>());

      expect(h.rig.keys.claimCalls, isEmpty);
      expect(h.rig.server.sends, isEmpty);
      expect(await outboxCount(), 0);
    });

    test('send answers refused peerHasNoDevice and tryTomorrow from the start '
        'path and stores nothing', () async {
      await h.ready();
      // Carol lists one device, and it is inactive: no claimable device.
      final carol = await RigPeer.create('carol');
      h.rig.keys.peers['ref-carol'] = [
        rigKeyDevice(carol.idString, carol.key)..inactive = true,
      ];
      var out = await port.send(
        to: _to('ref-carol'),
        localId: 'local-1',
        text: 'hi',
      );
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.peerHasNoDevice),
      );

      h.rig.keys.claimErrors['ref-bob'] = const RateLimitedException(
        'cap',
        limitName: 'keys_claims_per_target_daily',
      );
      out = await port.send(to: _to('ref-bob'), localId: 'local-2', text: 'hi');
      expect(
        (out.kind, out.problem),
        (SendOutcomeKind.refused, SendProblem.tryTomorrow),
      );
      expect(await outboxCount(), 0);
      expect(h.rig.server.sends, isEmpty);
    });

    test('a text over the content limit and a localId that is already an '
        'unsent row are ArgumentErrors', () async {
      await h.offer(_c1, bob);
      await h.ready();
      h.rig.server.beforeSend = (_) => Completer<void>().future;
      await expectLater(
        port.send(
          to: const ThreadRef.conversation(_c1),
          localId: 'local-1',
          text: 'x' * (kMaxMessageContentBytes + 1),
        ),
        throwsArgumentError,
      );
      await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'hi',
      );
      await expectLater(
        port.send(
          to: const ThreadRef.conversation(_c1),
          localId: 'local-1',
          text: 'again',
        ),
        throwsArgumentError,
      );
      expect(await outboxCount(), 1);
      // The held send never answers: the harness settles nothing of it.
      h.rig.server.beforeSend = null;
    });
  });

  group('unsent rows (gate items 12-17)', () {
    test('a later server refusal shows as notSent with the typed error, and '
        'retrySend sends it again through the starter', () async {
      await h.offer(_c1, bob);
      await h.ready();
      h.rig.server.sendScript.add((
        error: const FeatureDisabledException('off'),
        stored: false,
      ));
      final out = await port.send(
        to: const ThreadRef.conversation(_c1),
        localId: 'local-1',
        text: 'hi',
      );
      expect(out.kind, SendOutcomeKind.queued);
      await h.pipeline.sender.settled(_c1);

      final failed = (await port.unsentEntries(
        const ThreadRef.conversation(_c1),
      ))!.single;
      expect(failed.id, 'local-1');
      expect(
        (failed.progress, failed.problem),
        (SendProgress.notSent, SendProblem.refused),
      );
      expect(failed.error, isA<FeatureDisabledException>());
      expect(h.rig.server.sends, hasLength(1));

      await port.retrySend('unknown-id');
      await port.retrySend('local-1');
      await h.pipeline.sender.settled(_c1);
      await h.settle();
      expect(h.rig.server.sends, hasLength(2));
      expect(
        await port.unsentEntries(const ThreadRef.conversation(_c1)),
        isEmpty,
      );
    });

    test('unsent entries merge the pending init ahead of the outgoing rows; a '
        'recipient-addressed init is shown (I4)', () async {
      await startable('ref-carol', _c2);
      await h.ready();
      const unknown = (error: NetworkException('timed out'), stored: false);
      h.rig.server.sendScript.addAll([unknown, unknown]);

      final first = await port.send(
        to: _to('ref-carol'),
        localId: 'local-1',
        text: 'one',
      );
      expect(first.kind, SendOutcomeKind.queued);
      expect(first.conversationId, _c2);
      await h.pipeline.starter.settled(_c2);

      final byRecipient = (await port.unsentEntries(_to('ref-carol')))!;
      expect(byRecipient.map((e) => e.id), ['local-1']);
      expect(byRecipient.single.text, 'one');

      final second = await port.send(
        to: const ThreadRef.conversation(_c2),
        localId: 'local-2',
        text: 'two',
      );
      expect(second.kind, SendOutcomeKind.queued);
      final byId = (await port.unsentEntries(
        const ThreadRef.conversation(_c2),
      ))!;
      expect(byId.map((e) => e.id), ['local-1', 'local-2']);
      expect(byId.first.progress, isNot(SendProgress.notSent));
      await h.pipeline.sender.settled(_c2);
    });

    test('unsent entries answer null, never an empty list, when the vault '
        'cannot be read (item 17)', () async {
      await h.offer(_c1, bob);
      await h.ready();
      expect(
        await port.unsentEntries(const ThreadRef.conversation(_c1)),
        isEmpty,
      );
      h.rig.device.owner!.steal();
      await pumpEventQueue();
      expect(
        await port.unsentEntries(const ThreadRef.conversation(_c1)),
        isNull,
      );
    });
  });

  // Plan 6 Task 1.B: `e2ee_required` in the enabled features. The routing
  // never answers notEncrypted, and no composer or share makes a plaintext
  // SendMessage. The server's effective flag is `e2ee_required && messaging`,
  // NOT gated by `e2ee_dm` (ruling of 2026-11-25), so the last group runs
  // with `e2ee_dm` off.
  group('under e2ee_required (Plan 6 Task 1.B)', () {
    void cachePlainRow(String id, String peer) {
      h.rig.server.rows[id] = pb.Conversation(
        id: id,
        peer: common.AuthorSnapshot(userId: peer),
        folder: Folder.FOLDER_INBOX,
        canReply: true,
        state: ConversationState.CONVERSATION_STATE_ACCEPTED,
      );
    }

    test('under required an empty peer list is refused, never '
        'notEncrypted', () async {
      h.encryptionRequired = true;
      h.rig.keys.peers['ref-carol'] = [];
      cachePlainRow(_c2, 'ref-carol');
      await h.ready();
      for (final to in [_to('ref-carol'), const ThreadRef.conversation(_c2)]) {
        final out = await port.send(to: to, localId: 'local-1', text: 'hi');
        expect(
          (out.kind, out.problem, out.error),
          (SendOutcomeKind.refused, SendProblem.peerHasNoDevice, null),
        );
      }
      expect(await outboxCount(), 0);
      expect(h.rig.server.sends, isEmpty);
      expect(h.rig.keys.claimCalls, isEmpty);

      // The same person with required off: today's answer.
      h.encryptionRequired = false;
      final out = await port.send(
        to: _to('ref-carol'),
        localId: 'local-2',
        text: 'hi',
      );
      expect(out.kind, SendOutcomeKind.notEncrypted);
    });

    test(
      'under required no plaintext SendMessage is made from a share',
      () async {
        h.encryptionRequired = true;
        h.rig.keys.peers['ref-carol'] = [];
        await h.ready();
        final repo = FakeSendRepository()
          ..checkAnswer = 'post-1'
          ..cachedByPeer['ref-dave'] = pb.Conversation(
            id: _c2,
            peer: common.AuthorSnapshot(userId: 'ref-dave'),
            encryption: ConversationEncryption.CONVERSATION_ENCRYPTION_NONE,
          );
        final carol = common.AuthorSnapshot(userId: 'ref-carol');
        final dave = common.AuthorSnapshot(userId: 'ref-dave');

        // Checked share through the port: carol has no device.
        final checked = SharePostCubit(
          repository: repo,
          postId: 'post-1',
          url: 'https://dzeroth.test/p/1',
          encrypted: port,
          check: repo.checkPostShare,
          checkEnabled: () => true,
          encryptionRequired: () => h.encryptionRequired,
        );
        addTearDown(checked.close);
        checked.toggle(carol);
        await checked.send();
        expect(checked.state.recipients.single.status, ShareRowStatus.failed);
        expect(
          checked.state.recipients.single.problem,
          SendProblem.peerHasNoDevice,
        );

        // Unchecked share (dm_share_check off): dave's cached row is plain,
        // which today goes out as a plain share.
        final unchecked = SharePostCubit(
          repository: repo,
          postId: 'post-1',
          url: 'https://dzeroth.test/p/1',
          encrypted: port,
          check: repo.checkPostShare,
          checkEnabled: () => false,
          mayStartEncryption: () => true,
          encryptionRequired: () => h.encryptionRequired,
        );
        addTearDown(unchecked.close);
        unchecked.toggle(dave);
        await unchecked.send();
        expect(unchecked.state.recipients.single.status, ShareRowStatus.failed);
        expect(
          unchecked.state.recipients.single.problem,
          SendProblem.requiredUnavailable,
        );

        // No port at all (a platform with no vault): its own copy (L5).
        final portless = SharePostCubit(
          repository: repo,
          postId: 'post-1',
          url: 'https://dzeroth.test/p/1',
          encryptionRequired: () => h.encryptionRequired,
        );
        addTearDown(portless.close);
        portless.toggle(carol);
        await portless.send();
        expect(portless.state.recipients.single.status, ShareRowStatus.failed);
        expect(
          portless.state.recipients.single.problem,
          SendProblem.requiredNotOnThisDevice,
        );

        expect(repo.sendKeys, isEmpty, reason: 'no plaintext SendMessage');
        expect(h.rig.server.sends, isEmpty);
        expect(await outboxCount(), 0);
      },
    );

    test('under required the composer makes no plaintext SendMessage, with '
        'or without a port, and keeps the text', () async {
      h.encryptionRequired = true;
      h.rig.keys.peers['ref-carol'] = [];
      cachePlainRow(_c2, 'ref-carol');
      await h.ready();
      final repo = FakeSendRepository();
      for (final encrypted in <EncryptedMessaging?>[port, null]) {
        final cubit = MessageComposerCubit(
          repository: repo,
          conversationId: _c2,
          outbox: repo.outbox,
          encrypted: encrypted,
          encryptionRequired: () => h.encryptionRequired,
        );
        addTearDown(cubit.close);
        cubit.textChanged('hello');
        await cubit.send();
        expect(
          cubit.state.refusedProblem,
          encrypted == null
              ? SendProblem.requiredNotOnThisDevice
              : SendProblem.peerHasNoDevice,
        );
        expect(cubit.state.draft.text, 'hello');
        expect(cubit.state.outgoing, isEmpty);
      }
      expect(repo.sendKeys, isEmpty);
      expect(h.rig.server.sends, isEmpty);
    });

    group(
      'required without e2ee_dm (the server does not gate it by e2ee_dm)',
      () {
        test('a conversation that is not encrypted yet gets no send at all: '
            'neither plaintext nor encrypted', () async {
          h.encryptionRequired = true;
          await startable('ref-carol', _c2);
          h.rig.keys.peers['ref-dave'] = [];
          await h.ready();
          await h.rig.device.session.onFlagChanged(E2eeFlag.off, uid: 'user-a');
          for (final to in [
            _to('ref-carol'),
            _to('ref-dave'),
            const ThreadRef.conversation(_c2),
          ]) {
            final out = await port.send(to: to, localId: 'local-1', text: 'hi');
            expect(
              (out.kind, out.problem),
              (SendOutcomeKind.refused, SendProblem.requiredUnavailable),
            );
          }
          expect(h.rig.keys.claimCalls, isEmpty);
          expect(h.rig.server.sends, isEmpty);
          expect(await outboxCount(), 0);

          // With no vault on this device either.
          for (final flag in [E2eeFlag.off, E2eeFlag.unknown]) {
            final p = (await over(await noVault(flag))).port;
            for (final to in [
              const ThreadRef.conversation(_c2),
              _to('ref-dave'),
            ]) {
              final out = await p.send(to: to, localId: 'local-1', text: 'hi');
              expect(
                (out.kind, out.problem),
                (SendOutcomeKind.refused, SendProblem.requiredUnavailable),
                reason: '$flag',
              );
            }
          }
          expect(h.rig.server.sends, isEmpty);

          // Security L5: a vault this platform cannot hold (`unsupported`)
          // says so, with the flag on or off, never "being upgraded" or the
          // generic blocked line.
          for (final flag in [E2eeFlag.on, E2eeFlag.off]) {
            final world = FakeVaultWorld();
            final s = world.launch(supported: false);
            await s.start(restoredUid: 'user-a', restoreDefinitive: true);
            await s.onSignedIn('user-a', flag: flag);
            expect(s.status.value, VaultStatus.unsupported);
            final p = (await over(s)).port;
            final out = await p.send(
              to: _to('ref-dave'),
              localId: 'local-1',
              text: 'hi',
            );
            expect(
              (out.kind, out.problem),
              (SendOutcomeKind.refused, SendProblem.requiredNotOnThisDevice),
              reason: '$flag',
            );
          }
          expect(h.rig.server.sends, isEmpty);

          // The composer over that port: the refusal, the text kept, no RPC.
          final repo = FakeSendRepository();
          final cubit = MessageComposerCubit(
            repository: repo,
            recipientUserId: 'ref-dave',
            recipient: common.AuthorSnapshot(userId: 'ref-dave'),
            outbox: repo.outbox,
            encrypted: port,
            encryptionRequired: () => h.encryptionRequired,
          );
          addTearDown(cubit.close);
          cubit.textChanged('hello');
          await cubit.send();
          expect(cubit.state.refusedProblem, SendProblem.requiredUnavailable);
          expect(cubit.state.draft.text, 'hello');
          expect(repo.sendKeys, isEmpty);
        });

        test('a conversation already encrypted still sends', () async {
          h.encryptionRequired = true;
          await h.offer(_c1, bob);
          await h.ready();
          await h.rig.device.session.onFlagChanged(E2eeFlag.off, uid: 'user-a');
          final out = await port.send(
            to: const ThreadRef.conversation(_c1),
            localId: 'local-1',
            text: 'hi',
          );
          expect(out.kind, SendOutcomeKind.queued);
          await h.pipeline.sender.settled(_c1);
          await h.settle();
          expect(h.rig.server.sends, hasLength(1));
        });
      },
    );
  });

  test('the wiring builds the port over a pipeline (Task 13b ruling 1)', () {
    expect(encryptedMessagingOver(h.pipeline), isA<EncryptedMessagingImpl>());
  });

  group('the thin maps (gate items 33-35)', () {
    test('resetConversation throws ResetRefusedException(notAccepted) for a '
        'request and FeatureDisabledException with the flag off', () async {
      await h.offer(_c1, bob, accepted: false);
      await h.ready();
      await expectLater(
        port.resetConversation(_c1),
        throwsA(
          isA<ResetRefusedException>().having(
            (e) => e.reason,
            'reason',
            ResetRefusal.notAccepted,
          ),
        ),
      );
      await h.rig.device.session.onFlagChanged(E2eeFlag.off, uid: 'user-a');
      await expectLater(
        port.resetConversation(_c1),
        throwsA(isA<FeatureDisabledException>()),
      );
    });

    test(
      'checkRemovedAgain calls checkAgainNow only while removed elsewhere',
      () async {
        await h.ready();
        await port.checkRemovedAgain();
        expect(h.deviceKeys.checkAgainCalls, 0);
        h.deviceKeys.markRemoved();
        expect(port.removedElsewhere.value, isTrue);
        await port.checkRemovedAgain();
        expect(h.deviceKeys.checkAgainCalls, 1);
      },
    );

    test('setUpDeviceAgain throws FeatureDisabledException with the flag off '
        'and StateError when not removed elsewhere', () async {
      await h.ready();
      await expectLater(port.setUpDeviceAgain(), throwsStateError);
      await h.rig.device.session.onFlagChanged(E2eeFlag.off, uid: 'user-a');
      h.deviceKeys.markRemoved();
      await expectLater(
        port.setUpDeviceAgain(),
        throwsA(isA<FeatureDisabledException>()),
      );
    });

    test('retryDeviceSetup asks the device keys to run again', () async {
      await h.ready();
      await port.retryDeviceSetup();
      expect(h.deviceKeys.retryNowCalls, 1);
    });

    test(
      'hasLocal answers from the known set once the vault is ready',
      () async {
        await h.offer(_c1, bob);
        expect(port.hasLocal(_c1), isFalse);
        await h.ready();
        expect(port.hasLocal(_c1), isTrue);
        expect(port.hasLocal(_c2), isFalse);
      },
    );
  });
}
