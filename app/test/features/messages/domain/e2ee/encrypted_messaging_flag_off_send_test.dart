import 'package:dzeroth/core/session/session_end.dart';
import 'package:dzeroth/core/vault/vault_session.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/messages/domain/e2ee/e2ee_pipeline.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging_impl.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/e2ee_pipeline_harness.dart';
import '../../../../support/fake_send_repository.dart';
import '../../../../support/fake_vault_world.dart';

// Plan 5b Task 14 last round, item 1: with the flag KNOWN OFF and no vault
// known here, the send port does not refuse for "cannot tell yet" states (the
// sign-in step not finished, a marker that could not be read): it goes on to
// the cache check, so the app behaves as it did before the port was handed to
// these users. Real EncryptedMessagingImpl, real VaultSession.

const _c2 = '22222222222222222222222222222222';

class _StubSession extends Mock implements VaultSession {}

void main() {
  late PipelineHarness h;
  late FakeVaultWorld world;

  setUp(() async {
    h = await PipelineHarness.create();
    world = FakeVaultWorld();
  });
  tearDown(() => h.dispose());

  EncryptedMessagingImpl portOver(VaultSession session) {
    final pipeline = E2eePipeline(
      session: session,
      deviceKeys: h.deviceKeys,
      engine: () => h.guarded,
      messaging: h.messaging,
      keys: h.rig.keys,
      ownUserId: () => 'user-a',
      currentUid: () => 'user-a',
      now: h.rig.clock.now,
      onUnexpectedError: (e, _) => h.reported.add(e),
    );
    addTearDown(pipeline.dispose);
    return EncryptedMessagingImpl(pipeline);
  }

  final dave = ThreadRef.recipientOf(common.AuthorSnapshot(userId: 'ref-dave'));

  /// Flag off, marker unreadable: status `unavailable` (soft), no vault known.
  Future<VaultSession> softUnavailable(E2eeFlag flag) async {
    world.markers.failReads = true;
    final session = world.launch();
    await session.start(restoredUid: 'user-a', restoreDefinitive: true);
    await session.onSignedIn('user-a', flag: flag);
    expect(session.status.value, VaultStatus.unavailable);
    expect(session.vaultKnown, isFalse);
    return session;
  }

  /// A session whose flag answer is [flag] while its sign-in step has not
  /// finished (the step is still reading the marker). The real session holds
  /// this state only for the length of that step, so it is stubbed.
  Future<VaultSession> beforeSignInStep(E2eeFlag flag) async {
    final session = _StubSession();
    when(() => session.status).thenReturn(ValueNotifier(VaultStatus.off));
    when(() => session.vault).thenReturn(null);
    when(() => session.flag).thenReturn(flag);
    when(() => session.mayStart).thenReturn(flag == E2eeFlag.on);
    when(() => session.vaultKnown).thenReturn(false);
    when(() => session.signInStepDone).thenReturn(false);
    return session;
  }

  Future<(SendOutcomeKind, SendProblem)> sendRecipient(
    EncryptedMessagingImpl p,
  ) async {
    final out = await p.send(to: dave, localId: 'l1', text: 'hi');
    return (out.kind, out.problem);
  }

  Future<(SendOutcomeKind, SendProblem)> sendConversation(
    EncryptedMessagingImpl p,
  ) async {
    final out = await p.send(
      to: ThreadRef.conversation(_c2),
      localId: 'l1',
      text: 'hi',
    );
    return (out.kind, out.problem);
  }

  group('flag known off, no vault here', () {
    test(
      'status unavailable (soft), a plain conversation: notEncrypted',
      () async {
        final p = portOver(await softUnavailable(E2eeFlag.off));
        expect((await sendRecipient(p)).$1, SendOutcomeKind.notEncrypted);
        expect((await sendConversation(p)).$1, SendOutcomeKind.notEncrypted);
      },
    );

    // Final patch S1: the flag-known-off skip covers ONLY the unreadable
    // marker. Before the sign-in step is done the flag may be the previous
    // session's, so the answer is "try again".
    test('before the sign-in step finished, a plain conversation: refused '
        'retryable', () async {
      final p = portOver(await beforeSignInStep(E2eeFlag.off));
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.retryable,
      ));
    });

    test('a stale flag: the previous session ended with the flag off and the '
        'next sign-in step has not run: refused retryable', () async {
      final session = world.launch();
      await session.start(restoredUid: 'user-a', restoreDefinitive: true);
      await session.onSignedIn('user-a', flag: E2eeFlag.off);
      await session.onSessionEnded('user-a', SessionEnd.sessionLost);
      expect(session.flag, E2eeFlag.off);
      expect(session.signInStepDone, isFalse);
      final p = portOver(session);
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.retryable,
      ));
    });

    test('the flag turns on during the cache read (marker unreadable): '
        'refused retryable', () async {
      final session = await beforeSignInStep(E2eeFlag.off);
      when(() => session.signInStepDone).thenReturn(true);
      when(() => session.status)
          .thenReturn(ValueNotifier(VaultStatus.unavailable));
      h.rig.server.onCacheRead = () async {
        when(() => session.flag).thenReturn(E2eeFlag.on);
      };
      final p = portOver(session);
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.retryable,
      ));
      h.rig.server.onCacheRead = null;
    });

    test('a conversation the cache marks as ever encrypted is still '
        'refused blocked (marker unreadable, and status off)', () async {
      h.rig.server.everEncrypted.add(_c2);
      final soft = portOver(await softUnavailable(E2eeFlag.off));
      expect(await sendConversation(soft), (
        SendOutcomeKind.refused,
        SendProblem.blocked,
      ));
      world = FakeVaultWorld();
      final session = world.launch();
      await session.start(restoredUid: 'user-a', restoreDefinitive: true);
      await session.onSignedIn('user-a', flag: E2eeFlag.off);
      expect(session.status.value, VaultStatus.off);
      expect(await sendConversation(portOver(session)), (
        SendOutcomeKind.refused,
        SendProblem.blocked,
      ));
    });

    test('the composer makes exactly today\'s one sendMessage', () async {
      final p = portOver(await softUnavailable(E2eeFlag.off));
      final repo = FakeSendRepository();
      final cubit = MessageComposerCubit(
        repository: repo,
        conversationId: _c2,
        outbox: repo.outbox,
        encrypted: p,
      );
      addTearDown(cubit.close);
      cubit.textChanged('hello');
      await cubit.send();
      expect(repo.sendKeys, hasLength(1));
      expect(repo.sendTexts, ['hello']);
    });
  });

  group('everything else is unchanged', () {
    test('flag unknown, marker unreadable: refused retryable', () async {
      final p = portOver(await softUnavailable(E2eeFlag.unknown));
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.retryable,
      ));
    });

    test('flag unknown before the sign-in step: refused retryable', () async {
      final p = portOver(await beforeSignInStep(E2eeFlag.unknown));
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.retryable,
      ));
    });

    test('flag on before the sign-in step: refused retryable', () async {
      final p = portOver(await beforeSignInStep(E2eeFlag.on));
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.retryable,
      ));
    });

    test('a vault known here (flag off): refused blocked', () async {
      final session = await beforeSignInStep(E2eeFlag.off);
      when(() => session.vaultKnown).thenReturn(true);
      when(() => session.signInStepDone).thenReturn(true);
      final p = portOver(session);
      expect(await sendRecipient(p), (
        SendOutcomeKind.refused,
        SendProblem.blocked,
      ));
    });
  });
}
