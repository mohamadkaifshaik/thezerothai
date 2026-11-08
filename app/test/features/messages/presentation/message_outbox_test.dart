import 'package:dzeroth/core/network/app_exception.dart';
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

  test('clearSession empties the outbox', () async {
    repo.failures.add(const NetworkException('offline'));
    final cubit = _cubit(repo)..textChanged('secret');
    await cubit.send();
    cubit.textChanged('another draft');
    await cubit.close();
    expect(repo.outbox.isEmpty, isFalse);

    repo.outbox.clear();
    final fresh = _cubit(repo);
    expect(fresh.state.draft.text, isEmpty);
    expect(fresh.state.outgoing, isEmpty);
    await fresh.close();
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
