import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/messages/data/messaging_repository.dart';
import 'package:dzeroth/features/messages/data/messaging_store.dart';
import 'package:dzeroth/features/messages/presentation/bloc/conversations_cubit.dart';
import 'package:dzeroth/gen/dzeroth/messaging/v1/messaging.pbenum.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/messaging_fixtures.dart';

class MockMessagingRepository extends Mock implements MessagingRepository {}

void main() {
  late MockMessagingRepository repo;
  late DateTime clock;

  ConversationsSnapshot snap(List<String> ids, {bool more = false}) =>
      ConversationsSnapshot(
        conversations: [for (final id in ids) conv(id)],
        sinceToken: 's',
        olderPageToken: more ? 'older' : '',
      );

  ConversationsCubit build({Folder folder = Folder.FOLDER_INBOX}) =>
      ConversationsCubit(repository: repo, folder: folder, now: () => clock);

  setUpAll(() {
    registerFallbackValue(Folder.FOLDER_INBOX);
  });

  setUp(() {
    repo = MockMessagingRepository();
    clock = kMsgBase;
    when(() => repo.rateLimitedFor()).thenReturn(null);
    when(() => repo.cachedConversations(any()))
        .thenAnswer((_) async => const ConversationsSnapshot());
  });

  /// One cached row with an older page behind it, opened.
  void withOlderPage() {
    when(() => repo.cachedConversations(Folder.FOLDER_INBOX))
        .thenAnswer((_) async => snap(['a'], more: true));
    when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
        .thenAnswer((_) async => ConversationsResult(snap(['a'], more: true)));
  }

  group('load', () {
    test(
      'renders the cache before the network answers, then refreshes',
      () async {
        final network = Completer<ConversationsResult>();
        when(() => repo.cachedConversations(Folder.FOLDER_INBOX))
            .thenAnswer((_) async => snap(['a', 'b'], more: true));
        when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
            .thenAnswer((_) => network.future);
        final cubit = build();
        addTearDown(cubit.close);

        final loading = cubit.load();
        await pumpEventQueue();

        expect(cubit.state.status, ConversationsStatus.ready);
        expect(cubit.state.conversations.map((c) => c.id), ['a', 'b']);
        expect(cubit.state.hasMore, isTrue);
        expect(cubit.state.refreshing, isTrue);

        network.complete(
          ConversationsResult(snap(['c', 'a', 'b']), requestCount: 2),
        );
        await loading;

        expect(cubit.state.conversations.map((c) => c.id), ['c', 'a', 'b']);
        expect(cubit.state.refreshing, isFalse);
        expect(cubit.state.requestCount, 2);
      },
    );

    test('an empty cache and an empty answer is ready and empty', () async {
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX)).thenAnswer(
        (_) async =>
            const ConversationsResult(ConversationsSnapshot(), requestCount: 0),
      );
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.status, ConversationsStatus.ready);
      expect(cubit.state.conversations, isEmpty);
      expect(cubit.state.requestCount, 0);
    });

    test('a failure with nothing cached blocks with the error', () async {
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenThrow(const NetworkException('offline'));
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.status, ConversationsStatus.error);
      expect(cubit.state.error, isA<NetworkException>());
      expect(cubit.state.notice, isNull);
    });

    test('a failure over cached rows is a notice and keeps the rows', () async {
      when(() => repo.cachedConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) async => snap(['a']));
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenThrow(const NetworkException('offline'));
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.status, ConversationsStatus.ready);
      expect(cubit.state.error, isNull);
      expect(cubit.state.notice, isA<NetworkException>());
      expect(cubit.state.conversations, hasLength(1));
    });

    test('an unexpected error is reported (never its text)', () async {
      Object? reported;
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenThrow(const UnknownApiException('boom'));
      final cubit = ConversationsCubit(
        repository: repo,
        onUnexpectedError: (e, _) => reported = e,
      );
      addTearDown(cubit.close);

      await cubit.load();

      expect(reported, isA<UnknownApiException>());
    });

    test('a RATE_LIMITED hold sends nothing and shows the error', () async {
      when(() => repo.rateLimitedFor()).thenReturn(
        const RateLimitedException('x', retryAfter: Duration(minutes: 1)),
      );
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();

      verifyNever(() => repo.refreshConversations(any()));
      expect(cubit.state.error, isA<RateLimitedException>());
    });
  });

  group('request count', () {
    test('only a first INBOX page sets it; a later answer keeps it', () async {
      final answers = [
        ConversationsResult(snap(['a']), requestCount: 3),
        ConversationsResult(snap(['a'])),
      ];
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) async => answers.removeAt(0));
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.load();
      expect(cubit.state.requestCount, 3);
      await cubit.refresh();
      expect(cubit.state.requestCount, 3);
    });

    test('a warm start shows the persisted count before the network', () async {
      final network = Completer<ConversationsResult>();
      when(() => repo.cachedConversations(Folder.FOLDER_INBOX)).thenAnswer(
        (_) async => ConversationsSnapshot(
          conversations: [conv('a')],
          sinceToken: 's',
          requestCount: 4,
        ),
      );
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) => network.future);
      final cubit = build();
      addTearDown(cubit.close);

      final loading = cubit.load();
      await pumpEventQueue();

      expect(cubit.state.requestCount, 4);
      expect(cubit.state.refreshing, isTrue);
      network.complete(ConversationsResult(snap(['a'])));
      await loading;
      expect(cubit.state.requestCount, 4);
    });

    test('the REQUESTS folder never carries a count', () async {
      when(() => repo.refreshConversations(Folder.FOLDER_REQUESTS)).thenAnswer(
        (_) async => ConversationsResult(snap(['a']), requestCount: 5),
      );
      final cubit = build(folder: Folder.FOLDER_REQUESTS);
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.requestCount, isNull);
      verify(() => repo.cachedConversations(Folder.FOLDER_REQUESTS)).called(1);
    });
  });

  group('refreshIfStale (resume, push)', () {
    test('sends nothing inside 60 s; one refresh is scheduled for the end of '
        'the window, not a poll', () {
      fakeAsync((async) {
        var calls = 0;
        when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
            .thenAnswer((_) async {
              calls++;
              return ConversationsResult(snap(['a']));
            });
        final cubit = build();
        cubit.refresh();
        async.flushMicrotasks();
        expect(calls, 1);

        clock = clock.add(const Duration(seconds: 20));
        cubit.refreshIfStale();
        cubit.refreshIfStale();
        async.flushMicrotasks();
        expect(calls, 1);

        clock = clock.add(const Duration(seconds: 40));
        async.elapse(const Duration(seconds: 40));
        async.flushMicrotasks();
        expect(calls, 2);

        // Nothing repeats by itself.
        async.elapse(const Duration(minutes: 10));
        async.flushMicrotasks();
        expect(calls, 2);
        cubit.close();
      });
    });

    test('after 60 s it refreshes at once', () async {
      var calls = 0;
      when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) async {
            calls++;
            return ConversationsResult(snap(['a']));
          });
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.refresh();

      clock = clock.add(kConversationsRefreshInterval);
      await cubit.refreshIfStale();

      expect(calls, 2);
    });

    test('is skipped while a RATE_LIMITED hold is set', () async {
      when(() => repo.rateLimitedFor()).thenReturn(
        const RateLimitedException('x', retryAfter: Duration(minutes: 1)),
      );
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.refreshIfStale();

      verifyNever(() => repo.refreshConversations(any()));
      expect(cubit.state.notice, isNull);
      expect(cubit.state.error, isNull);
    });

    test(
      'refresh() (pull, Retry, the shell on a push) is never throttled',
      () async {
        var calls = 0;
        when(() => repo.refreshConversations(Folder.FOLDER_INBOX))
            .thenAnswer((_) async {
              calls++;
              return ConversationsResult(snap(['a']));
            });
        final cubit = build();
        addTearDown(cubit.close);

        await cubit.refresh();
        await cubit.refresh();

        expect(calls, 2);
      },
    );
  });

  group('paging', () {
    blocTest<ConversationsCubit, ConversationsState>(
      'loadMore appends the older page then clears the footer',
      build: () {
        when(() => repo.loadOlderConversations(Folder.FOLDER_INBOX))
            .thenAnswer((_) async => snap(['a', 'b']));
        return build();
      },
      seed: () => ConversationsState(
        status: ConversationsStatus.ready,
        conversations: [conv('a')],
        hasMore: true,
      ),
      act: (cubit) => cubit.loadMore(),
      expect: () => [
        isA<ConversationsState>().having((s) => s.loadingMore, 'loading', true),
        isA<ConversationsState>().having(
          (s) => s.conversations.length,
          'rows',
          2,
        ),
        isA<ConversationsState>().having(
          (s) => s.loadingMore,
          'loading',
          false,
        ),
      ],
    );

    test('does nothing at the end of the list', () async {
      final cubit = build();
      addTearDown(cubit.close);

      await cubit.loadMore();

      verifyNever(() => repo.loadOlderConversations(any()));
    });

    test(
      'a failed page shows the inline retry and is not retried by itself',
      () async {
        when(() => repo.loadOlderConversations(Folder.FOLDER_INBOX))
            .thenThrow(const NetworkException('offline'));
        withOlderPage();
        final cubit = build();
        addTearDown(cubit.close);
        await cubit.load();

        await cubit.loadMore();
        expect(cubit.state.loadMoreFailed, isTrue);
        await cubit.loadMore();

        verify(() => repo.loadOlderConversations(Folder.FOLDER_INBOX))
            .called(1);
      },
    );

    test('retryLoadMore tries again', () async {
      final answers = <Future<ConversationsSnapshot> Function()>[
        () => throw const NetworkException('offline'),
        () async => snap(['a', 'b']),
      ];
      when(() => repo.loadOlderConversations(Folder.FOLDER_INBOX))
          .thenAnswer((_) => answers.removeAt(0)());
      withOlderPage();
      final cubit = build();
      addTearDown(cubit.close);
      await cubit.load();

      await cubit.loadMore();
      await cubit.retryLoadMore();

      expect(cubit.state.loadMoreFailed, isFalse);
      expect(cubit.state.conversations, hasLength(2));
    });
  });
}
