import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encrypted_messaging.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_encrypted_messaging.dart';
import '../../../support/fake_send_repository.dart';

// Plan 6 Task 1.B fix round (code review Majors, security L3): the composer's
// plaintext paths under `e2ee_required`, for each of no port and a port that
// answers notEncrypted. `sendKeys` records every plaintext call (also a
// failed one), so "no RPC" is "no new key".

const _conv = '0123456789abcdef0123456789abcdef';

void main() {
  for (final withPort in [false, true]) {
    final label = withPort ? 'a port answering notEncrypted' : 'no port';
    // No port: this platform has no vault, so the refusal says so; a port
    // that (wrongly) answered notEncrypted gets the generic required line.
    final expectedProblem = withPort
        ? SendProblem.requiredUnavailable
        : SendProblem.requiredNotOnThisDevice;

    group('with $label', () {
      late FakeSendRepository repo;
      late FakeEncryptedMessaging? port;
      late bool Function() requiredNow;

      MessageComposerCubit build() {
        final cubit = MessageComposerCubit(
          repository: repo,
          conversationId: _conv,
          outbox: repo.outbox,
          encrypted: port,
          encryptionRequired: () => requiredNow(),
        );
        addTearDown(cubit.close);
        return cubit;
      }

      setUp(() {
        repo = FakeSendRepository();
        final fake = port = withPort
            ? (FakeEncryptedMessaging()
                ..nextSendOutcome = const SendOutcome(
                  SendOutcomeKind.notEncrypted,
                ))
            : null;
        if (fake != null) addTearDown(fake.dispose);
        requiredNow = () => false;
      });

      Future<OutgoingMessage> failedRow(MessageComposerCubit cubit) async {
        repo.failures.add(const NetworkException('offline'));
        cubit.textChanged('hello');
        await cubit.send();
        expect(repo.sendKeys, hasLength(1));
        final row = cubit.state.outgoing.single;
        expect(row.status, OutgoingStatus.failed);
        return row;
      }

      test('required on: a retried failed row stays failed in place, with no '
          'RPC and the required refusal', () async {
        final cubit = build();
        final row = await failedRow(cubit);
        requiredNow = () => true;
        await cubit.retry(row.localId);
        expect(repo.sendKeys, hasLength(1), reason: 'no plaintext RPC');
        expect(cubit.state.outgoing.single.localId, row.localId);
        expect(cubit.state.outgoing.single.status, OutgoingStatus.failed);
        expect(cubit.state.refusedProblem, expectedProblem);
      });

      test("required off: today's plaintext retry", () async {
        final cubit = build();
        final row = await failedRow(cubit);
        await cubit.retry(row.localId);
        expect(repo.sendKeys, [row.localId, row.localId]);
        // Delivered: the row leaves the outbox (the thread shows the message).
        expect(
          cubit.state.outgoing.where((m) => m.status == OutgoingStatus.failed),
          isEmpty,
        );
        expect(repo.stored, contains(row.localId));
        expect(cubit.state.refusedProblem, SendProblem.none);
      });

      test('a flag that turns on between two sends: the second makes no '
          'RPC', () async {
        final cubit = build();
        cubit.textChanged('one');
        await cubit.send();
        expect(repo.sendKeys, hasLength(1));
        requiredNow = () => true;
        cubit.textChanged('two');
        await cubit.send();
        expect(repo.sendKeys, hasLength(1));
        expect(cubit.state.draft.text, 'two');
        expect(cubit.state.refusedProblem, expectedProblem);
      });

      test('a flag that turns on between the optimistic row and the call: '
          'the row becomes failed and nothing is sent', () async {
        final cubit = build();
        // Off until the optimistic row is on screen (sending), on after:
        // the check right before the call is the one that refuses.
        requiredNow = () =>
            cubit.state.outgoing.any((m) => m.status == OutgoingStatus.sending);
        cubit.textChanged('hello');
        await cubit.send();
        expect(repo.sendKeys, isEmpty);
        final row = cubit.state.outgoing.single;
        expect(row.status, OutgoingStatus.failed);
        expect(row.text, 'hello');
        expect(cubit.state.refusedProblem, expectedProblem);
      });
    });
  }
}
