import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_composer_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_search_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/message_search_state.dart';
import 'package:dzeroth/features/messages/presentation/bloc/share_post_cubit.dart';
import 'package:dzeroth/features/messages/presentation/bloc/thread_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_send_repository.dart';
import '../../../support/messaging_fixtures.dart';
import '../../../support/thread_test_support.dart';

class _MockRepo extends Mock implements MessagingRepository {}

const _secret = 'a typed secret';

/// Every presentation cubit that catches `on Object` reports a FIXED
/// `StateError('<step>')`, never the thrown object (a thrown error can carry
/// what was typed or decrypted). Each test throws a [StateError] carrying
/// [_secret] from a plain-path dependency and checks what the reporter gets.
class _Reports {
  final List<Object> errors = [];
  void call(Object error, StackTrace stack) => errors.add(error);

  /// The one step name reported, after checking it is a [StateError] that
  /// does not carry the thrown text.
  String get step {
    expect(errors, hasLength(1));
    final error = errors.single;
    expect(error, isA<StateError>());
    final message = (error as StateError).message;
    expect(message, isNot(contains(_secret)));
    return message;
  }
}

void main() {
  group('thread cubit', () {
    late _MockRepo repo;
    late FakeThreadPoller poller;
    late StreamController<void> changes;
    late _Reports reports;

    ThreadCubit make() => ThreadCubit(
      repository: repo,
      poller: poller,
      conversationId: kThreadId,
      onUnexpectedError: reports.call,
    );

    ThreadSnapshot snapshot() => ThreadSnapshot(
      messages: msgs(1, 1),
      conversation: threadConv(),
      sinceToken: 's',
    );

    setUp(() {
      repo = _MockRepo();
      poller = FakeThreadPoller();
      changes = StreamController<void>.broadcast();
      reports = _Reports();
      when(() => repo.rateLimitedFor()).thenReturn(null);
      when(() => repo.conversationsChanged).thenAnswer((_) => changes.stream);
      when(() => repo.dropBlockedRequest(any())).thenAnswer((_) async {});
      when(() => repo.cachedConversation(any())).thenAnswer((_) async => null);
      when(() => repo.refreshThread(kThreadId))
          .thenThrow(const NetworkException('offline'));
    });
    tearDown(() => changes.close());

    test('a failing cached read reports a fixed step', () async {
      when(() => repo.cachedThread(kThreadId)).thenThrow(StateError(_secret));
      final cubit = make();
      addTearDown(cubit.close);
      await cubit.load();
      expect(reports.errors.first, isA<StateError>());
      expect((reports.errors.first as StateError).message, 'cachedThread');
    });

    test('a failing header follow reports a fixed step', () async {
      when(() => repo.cachedThread(kThreadId))
          .thenAnswer((_) async => snapshot());
      when(() => repo.refreshThread(kThreadId))
          .thenAnswer((_) async => snapshot());
      final cubit = make();
      addTearDown(cubit.close);
      await cubit.load();
      when(() => repo.cachedConversation(kThreadId))
          .thenThrow(StateError(_secret));
      changes.add(null);
      await pumpEventQueue();
      expect(reports.step, 'cachedConversation');
    });

    test('a failing drop of a blocked request reports a fixed step', () async {
      when(() => repo.dropBlockedRequest(kThreadId))
          .thenThrow(StateError(_secret));
      final cubit = make();
      addTearDown(cubit.close);
      cubit.markPeerBlocked();
      await pumpEventQueue();
      expect(reports.step, 'dropBlockedRequest');
    });

    test('a failing read after a send reports a fixed step', () async {
      when(() => repo.cachedThread(kThreadId)).thenThrow(StateError(_secret));
      final cubit = make();
      addTearDown(cubit.close);
      await cubit.noteSent();
      expect(reports.step, 'noteSent');
    });
  });

  group('composer cubit', () {
    test('an unexpected send failure reports a fixed step', () async {
      final repo = FakeSendRepository()..failures.add(StateError(_secret));
      final reports = _Reports();
      final cubit = MessageComposerCubit(
        repository: repo,
        outbox: repo.outbox,
        conversationId: kThreadId,
        onUnexpectedError: reports.call,
      );
      addTearDown(cubit.close);
      cubit.textChanged('hello');
      await cubit.send();
      expect(reports.step, 'sendMessage');
    });

    test('a failing onSent reports a fixed step', () async {
      final repo = FakeSendRepository();
      final reports = _Reports();
      final cubit = MessageComposerCubit(
        repository: repo,
        outbox: repo.outbox,
        conversationId: kThreadId,
        onSent: () async => throw StateError(_secret),
        onUnexpectedError: reports.call,
      );
      addTearDown(cubit.close);
      cubit.textChanged('hello');
      await cubit.send();
      expect(reports.step, 'onSent');
    });
  });

  group('search cubit', () {
    late _MockRepo repo;
    late _Reports reports;

    setUp(() {
      repo = _MockRepo();
      reports = _Reports();
      when(() => repo.conversationsChanged)
          .thenAnswer((_) => const Stream<void>.empty());
    });

    test('a failing corpus read reports a fixed step', () async {
      when(
        () => repo.cachedSearchCorpus(
          conversationId: any(named: 'conversationId'),
        ),
      ).thenThrow(StateError(_secret));
      final cubit = MessageSearchCubit(
        repository: repo,
        debounce: Duration.zero,
        onUnexpectedError: reports.call,
      );
      addTearDown(cubit.close);
      cubit.setQuery('needle');
      await cubit.stream.firstWhere(
        (s) => s.status == MessageSearchStatus.ready,
      );
      expect(reports.step, 'searchCorpus');
    });

    test('a failing older page reports a fixed step', () async {
      when(
        () => repo.cachedSearchCorpus(
          conversationId: any(named: 'conversationId'),
        ),
      ).thenAnswer((_) async => const SearchCorpus());
      when(() => repo.olderSearchToken('c1')).thenAnswer((_) async => 'tok');
      when(() => repo.fetchOlderForSearch('c1', 'tok'))
          .thenThrow(StateError(_secret));
      final cubit = MessageSearchCubit(
        repository: repo,
        conversationId: 'c1',
        debounce: Duration.zero,
        onUnexpectedError: reports.call,
      );
      addTearDown(cubit.close);
      cubit.setQuery('needle');
      await cubit.stream.firstWhere(
        (s) => s.status == MessageSearchStatus.ready,
      );
      await cubit.loadOlder();
      expect(reports.step, 'searchOlder');
    });
  });

  group('conversations cubit', () {
    late _MockRepo repo;
    late StreamController<void> changes;
    late _Reports reports;

    setUpAll(() => registerFallbackValue(Folder.FOLDER_INBOX));
    setUp(() {
      repo = _MockRepo();
      changes = StreamController<void>.broadcast();
      reports = _Reports();
      when(() => repo.rateLimitedFor()).thenReturn(null);
      when(() => repo.conversationsChanged).thenAnswer((_) => changes.stream);
      when(() => repo.refreshConversations(any())).thenAnswer(
        (_) async => ConversationsResult(
          ConversationsSnapshot(conversations: [conv('a')], sinceToken: 's'),
        ),
      );
    });
    tearDown(() => changes.close());

    test('a failing cached read reports a fixed step', () async {
      when(() => repo.cachedConversations(any()))
          .thenThrow(StateError(_secret));
      final cubit = ConversationsCubit(
        repository: repo,
        onUnexpectedError: reports.call,
      );
      addTearDown(cubit.close);
      await cubit.load();
      expect(reports.step, 'cachedConversations');
    });

    test(
      'a failing reload after a cache change reports a fixed step',
      () async {
        when(() => repo.cachedConversations(any()))
            .thenAnswer((_) async => const ConversationsSnapshot());
        final cubit = ConversationsCubit(
          repository: repo,
          onUnexpectedError: reports.call,
        );
        addTearDown(cubit.close);
        await cubit.load();
        when(() => repo.cachedConversations(any()))
            .thenThrow(StateError(_secret));
        changes.add(null);
        await pumpEventQueue();
        expect(reports.step, 'reloadFromCache');
      },
    );
  });

  group('share cubit', () {
    test('an unexpected send failure reports a fixed step', () async {
      final repo = FakeSendRepository()..failures.add(StateError(_secret));
      final reports = _Reports();
      final cubit = SharePostCubit(
        repository: repo,
        postId: '1234567890123456789',
        url: 'https://dzeroth.com/post/1234567890123456789',
        ownUserId: 'u-me',
        onUnexpectedError: reports.call,
      )..toggle(common.AuthorSnapshot(userId: 'u1', handle: 'user1'));
      addTearDown(cubit.close);
      await cubit.send();
      expect(reports.step, 'sendShare');
    });
  });
}
