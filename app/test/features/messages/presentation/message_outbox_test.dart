import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/data/message_outbox.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_send_repository.dart';
import '../../../support/thread_test_support.dart';

MessageComposerCubit _cubit(FakeSendRepository repo) => MessageComposerCubit(
  repository: repo,
  conversationId: kThreadId,
  outbox: repo.outbox,
);

void main() {
  late FakeSendRepository repo;

  setUp(() => repo = FakeSendRepository());

  test('draft text survives rebuilding the cubit', () async {
    final first = _cubit(repo)..textChanged('half written');
    await first.close();
    final second = _cubit(repo);
    expect(second.state.draft.text, 'half written');
    await second.close();
  });

  test('a failed row survives with the same key and resends with it', () async {
    repo.failures.add(const NetworkException('offline'));
    final first = _cubit(repo)..textChanged('hello');
    await first.send();
    final key = first.state.outgoing.single.localId;
    expect(first.state.outgoing.single.status, OutgoingStatus.failed);
    await first.close();

    final second = _cubit(repo);
    expect(second.state.outgoing.single.localId, key);
    expect(second.state.outgoing.single.status, OutgoingStatus.failed);
    await second.retry(key);
    expect(repo.sendKeys, [key, key]);
    expect(repo.stored, hasLength(1));
    await second.close();
  });

  test(
    'commit then lost response: a new screen retries with the key',
    () async {
      repo.lostResponses.add(const NetworkException('timeout'));
      final first = _cubit(repo)..textChanged('once');
      await first.send();
      final key = first.state.outgoing.single.localId;
      await first.close();

      final second = _cubit(repo);
      await second.retry(key);
      expect(repo.sendKeys, [key, key]);
      expect(repo.stored, hasLength(1));
      expect(second.state.outgoing, isEmpty);
      await second.close();
    },
  );

  test('typing the same text again after leaving reuses the key', () async {
    repo.failures.add(const NetworkException('offline'));
    final first = _cubit(repo)..textChanged('same');
    await first.send();
    final key = first.state.outgoing.single.localId;
    await first.close();

    final second = _cubit(repo)..textChanged('same');
    await second.send();
    expect(repo.sendKeys.last, key);
    await second.close();
  });

  test('clearSession empties the outbox and stales live cubits', () async {
    repo.failures.add(const NetworkException('offline'));
    final cubit = _cubit(repo)..textChanged('secret');
    await cubit.send();
    expect(repo.outbox.isEmpty, isFalse);

    repo.clearSession();
    cubit.textChanged('written after sign-out');
    expect(repo.outbox.isEmpty, isTrue);
    expect(cubit.keyFor('x'), isNull);
    await cubit.close();

    final fresh = _cubit(repo);
    expect(fresh.state.draft.text, isEmpty);
    expect(fresh.state.outgoing, isEmpty);
    await fresh.close();
  });

  test('a send finishing after sign-out leaves the outbox empty', () async {
    repo.sendGate = Completer<void>();
    final cubit = _cubit(repo)..textChanged('hi');
    final sending = cubit.send();
    await pumpEventQueue();
    repo.clearSession();
    repo.sendGate!.complete();
    await sending;
    await cubit.close();
    expect(repo.outbox.isEmpty, isTrue);
  });

  test('success after the screen closed drops the row and the key', () async {
    repo.sendGate = Completer<void>();
    final cubit = _cubit(repo)..textChanged('hi');
    final sending = cubit.send();
    await pumpEventQueue();
    await cubit.close();
    expect(repo.outbox.rowsOf(kThreadId), hasLength(1));
    repo.sendGate!.complete();
    await sending;
    expect(repo.outbox.rowsOf(kThreadId), isEmpty);
    expect(repo.outbox.peekKey(kThreadId, 'hi'), isNull);
  });

  test(
    'failure after the screen closed leaves a failed row with its key',
    () async {
      repo.sendGate = Completer<void>();
      repo.failures.add(const NetworkException('offline'));
      final cubit = _cubit(repo)..textChanged('hi');
      final sending = cubit.send();
      await pumpEventQueue();
      await cubit.close();
      repo.sendGate!.complete();
      await sending;
      final rows = repo.outbox.rowsOf(kThreadId);
      expect(rows.single.status, OutgoingStatus.failed);
      expect(rows.single.error, isA<NetworkException>());
      expect(repo.outbox.peekKey(kThreadId, 'hi'), rows.single.localId);
    },
  );

  test('CANNOT_MESSAGE clears the key and the row', () async {
    repo.failures.add(const CannotMessageException());
    final cubit = _cubit(repo)..textChanged('hi');
    await cubit.send();
    expect(cubit.state.outgoing, isEmpty);
    expect(repo.outbox.rowsOf(kThreadId), isEmpty);
    expect(repo.outbox.peekKey(kThreadId, 'hi'), isNull);
    await cubit.close();
  });

  test('CANNOT_MESSAGE after the screen closed clears key and row', () async {
    repo.sendGate = Completer<void>();
    repo.failures.add(const CannotMessageException());
    final cubit = _cubit(repo)..textChanged('hi');
    final sending = cubit.send();
    await pumpEventQueue();
    await cubit.close();
    repo.sendGate!.complete();
    await sending;
    expect(repo.outbox.rowsOf(kThreadId), isEmpty);
    expect(repo.outbox.peekKey(kThreadId, 'hi'), isNull);
  });

  test('a draft thread keeps its text and is dropped once the conversation '
      'exists', () async {
    final scope = MessageOutbox.draftScope('u-peer');
    MessageComposerCubit draft() => MessageComposerCubit(
      repository: repo,
      outbox: repo.outbox,
      recipientUserId: 'u-peer',
    );
    final first = draft()..textChanged('typed');
    await first.close();
    expect(repo.outbox.draftOf(scope), 'typed');
    final second = draft();
    expect(second.state.draft.text, 'typed');

    await second.send();
    expect(repo.outbox.draftOf(scope), isEmpty);
    expect(repo.outbox.rowsOf(scope), isEmpty);
    expect(repo.outbox.peekKey(scope, 'typed'), isNull);
    await second.close();
  });

  test('another conversation does not see the draft', () async {
    final first = _cubit(repo)..textChanged('mine');
    await first.close();
    final other = MessageComposerCubit(
      repository: repo,
      conversationId: 'other',
      outbox: repo.outbox,
    );
    expect(other.state.draft.text, isEmpty);
    await other.close();
  });
}
