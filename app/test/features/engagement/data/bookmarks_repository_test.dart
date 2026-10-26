import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _service = '/dzeroth.engagement.v1.EngagementService/';
const _add = '${_service}AddBookmark';
const _remove = '${_service}RemoveBookmark';

/// A scripted call: the test completes it when it wants the answer.
class _Call {
  _Call(this.procedure, this.input);

  final String procedure;
  final Object input;
  final Completer<Object> answer = Completer<Object>();

  String get key => switch (input) {
    pb.AddBookmarkRequest(:final idempotencyKey) => idempotencyKey,
    pb.RemoveBookmarkRequest(:final idempotencyKey) => idempotencyKey,
    _ => '',
  };

  void ok() => answer.complete(
    procedure == _add
        ? pb.AddBookmarkResponse(
            state: pb.BookmarkState(postId: postId(1), bookmarked: true),
          )
        : pb.RemoveBookmarkResponse(
            state: pb.BookmarkState(postId: postId(1), bookmarked: false),
          ),
  );

  void fail(Object error) => answer.completeError(error);
}

void main() {
  late SessionEpoch epoch;
  late FakeTransport transport;
  late BookmarksRepository repo;
  late List<_Call> calls;
  late List<BookmarkEvent> events;
  var enabled = true;
  var refreshAsked = 0;
  Object? Function(String procedure)? immediate;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    enabled = true;
    refreshAsked = 0;
    immediate = null;
    epoch = SessionEpoch();
    calls = [];
    events = [];
    transport = FakeTransport((procedure, input) {
      final call = _Call(procedure, input);
      calls.add(call);
      final answer = immediate?.call(procedure);
      if (answer is _Reply) {
        if (answer.error != null) return Future.error(answer.error!);
        call.ok();
      }
      return call.answer.future;
    });
    repo = BookmarksRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabled,
        onDisabledByServer: () => refreshAsked++,
      ),
      epoch: epoch,
    );
    repo.events.listen(events.add);
  });

  tearDown(() => repo.dispose());

  group('toggle', () {
    test(
      'adds with the post id and a key, then settles with a toast',
      () async {
        final future = repo.setBookmarked(postId(1), saved: true);
        await settle();

        // Optimistic at once, before the answer.
        expect(repo.isBookmarked(postId(1)), isTrue);
        expect(repo.snapshot()[postId(1)]!.busy, isTrue);
        expect(calls, hasLength(1));
        final sent = calls.single.input as pb.AddBookmarkRequest;
        expect(sent.postId, postId(1));
        expect(sent.idempotencyKey, isNotEmpty);

        calls.single.ok();
        await future;

        expect(repo.isBookmarked(postId(1)), isTrue);
        expect(repo.snapshot()[postId(1)]!.busy, isFalse);
        final settled = events.whereType<BookmarkSettled>().single;
        expect(settled.postId, postId(1));
        expect(settled.saved, isTrue);
      },
    );

    test('remove sends RemoveBookmark and settles as removed', () async {
      final future = repo.setBookmarked(postId(1), saved: false, server: true);
      await settle();
      expect(repo.isBookmarked(postId(1), server: true), isFalse);
      expect(calls.single.procedure, _remove);

      calls.single.ok();
      await future;
      expect(events.whereType<BookmarkSettled>().single.saved, isFalse);
    });

    test('a no-op toggle sends nothing', () async {
      await repo.setBookmarked(postId(1), saved: false);
      await repo.setBookmarked(postId(1), saved: true, server: true);
      expect(calls, isEmpty);
    });

    test('failure rolls back and reports once, typed', () async {
      final future = repo.setBookmarked(postId(1), saved: true);
      await settle();
      calls.single.fail(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
          metadata: {'limit': 'bookmarks'},
        ),
      );
      await future;

      expect(repo.isBookmarked(postId(1)), isFalse);
      expect(repo.snapshot()[postId(1)]!.busy, isFalse);
      final failed = events.whereType<BookmarkFailed>().single;
      expect(failed.wanted, isTrue);
      expect(
        failed.error,
        isA<LimitReachedException>().having(
          (e) => e.quota,
          'quota',
          'bookmarks',
        ),
      );
      expect(events.whereType<BookmarkSettled>(), isEmpty);
    });

    test('a retry after a failure reuses the key; the opposite intent gets '
        'a new one', () async {
      var future = repo.setBookmarked(postId(1), saved: true);
      await settle();
      final firstKey = calls[0].key;
      calls[0].fail(const NetworkException('offline'));
      await future;

      future = repo.setBookmarked(postId(1), saved: true);
      await settle();
      expect(calls[1].key, firstKey);
      calls[1].ok();
      await future;

      future = repo.setBookmarked(postId(1), saved: false);
      await settle();
      expect(calls[2].procedure, _remove);
      expect(calls[2].key, isNot(firstKey));
      calls[2].ok();
      await future;
    });
  });

  group('serialisation per post, latest intent wins', () {
    test('taps during a request send nothing; the final intent decides '
        'whether a follow-up goes out', () async {
      final first = repo.setBookmarked(postId(1), saved: true);
      await settle();
      // off, then on again while the add is in flight.
      unawaited(repo.setBookmarked(postId(1), saved: false));
      unawaited(repo.setBookmarked(postId(1), saved: true));
      await settle();
      expect(calls, hasLength(1), reason: 'one request at a time');
      expect(repo.isBookmarked(postId(1)), isTrue);

      calls[0].ok();
      await first;

      expect(calls, hasLength(1), reason: 'the add already is the latest');
      expect(repo.isBookmarked(postId(1)), isTrue);
    });

    test('add then remove sends both, in order, with different keys and '
        'one toast only if the state changed', () async {
      final first = repo.setBookmarked(postId(1), saved: true);
      await settle();
      unawaited(repo.setBookmarked(postId(1), saved: false));
      await settle();
      expect(repo.isBookmarked(postId(1)), isFalse, reason: 'shows the latest');

      calls[0].ok();
      await settle();
      expect(calls, hasLength(2));
      expect(calls[1].procedure, _remove);
      expect(calls[1].key, isNot(calls[0].key));
      calls[1].ok();
      await first;

      expect(repo.isBookmarked(postId(1)), isFalse);
      // Started un-bookmarked and ended un-bookmarked: nothing to announce.
      expect(events.whereType<BookmarkSettled>(), isEmpty);
    });

    test('different posts do not wait for each other', () async {
      unawaited(repo.setBookmarked(postId(1), saved: true));
      unawaited(repo.setBookmarked(postId(2), saved: true));
      await settle();
      expect(calls, hasLength(2));
    });

    test('a failure in a burst rolls back to the last confirmed state '
        'and drops the queued intent', () async {
      final first = repo.setBookmarked(postId(1), saved: true);
      await settle();
      calls[0].ok();
      await first;

      final second = repo.setBookmarked(postId(1), saved: false);
      await settle();
      unawaited(repo.setBookmarked(postId(1), saved: true));
      await settle();
      calls[1].fail(const NetworkException('offline'));
      await second;

      expect(repo.isBookmarked(postId(1)), isTrue, reason: 'still bookmarked');
      expect(calls, hasLength(2));
    });
  });

  group('overlay precedence', () {
    test('nothing known: not bookmarked', () {
      expect(repo.isBookmarked(postId(1)), isFalse);
    });

    test('no server flag: the local set is the only source', () {
      repo.recordListed([postId(1), postId(2)]);
      expect(repo.isBookmarked(postId(1)), isTrue);
      expect(repo.isBookmarked(postId(3)), isFalse);
    });

    test('a server flag wins over a list entry', () {
      repo.recordListed([postId(1)]);
      expect(repo.isBookmarked(postId(1), server: false), isFalse);
      expect(repo.isBookmarked(postId(1), server: true), isTrue);
    });

    test('a server flag with no session entry is used as is', () {
      expect(repo.isBookmarked(postId(1), server: true), isTrue);
      expect(repo.isBookmarked(postId(1), server: false), isFalse);
    });

    test('a toggle beats the row it was made on (a cached row cannot undo '
        'it); a row that says something else is newer and wins', () async {
      final add = repo.setBookmarked(postId(1), saved: true, server: false);
      await settle();
      calls.last.ok();
      await add;
      // The cached row still says false, as when the user tapped.
      expect(repo.isBookmarked(postId(1), server: false), isTrue);
      // A refreshed row that differs from that base is newer: it wins.
      expect(repo.isBookmarked(postId(1), server: true), isTrue);

      final remove = repo.setBookmarked(postId(2), saved: false, server: true);
      await settle();
      calls.last.ok();
      await remove;
      expect(repo.isBookmarked(postId(2), server: true), isFalse);
      expect(repo.isBookmarked(postId(2), server: false), isFalse);
    });

    test('a refreshed row restarts the next toggle from what it says '
        '(not from the old session state)', () async {
      final add = repo.setBookmarked(postId(1), saved: true, server: false);
      await settle();
      calls.last.ok();
      await add;

      // The feed refreshed: the row now says true, and the user taps to
      // remove. A stale "bookmarked" session state must not turn it into a
      // no-op, nor an add.
      final remove = repo.setBookmarked(postId(1), saved: false, server: true);
      await settle();
      expect(calls, hasLength(2));
      expect(calls.last.procedure, _remove);
      calls.last.ok();
      await remove;
    });

    test('while a request runs the toggle always shows', () async {
      unawaited(repo.setBookmarked(postId(1), saved: true, server: false));
      await settle();
      expect(repo.isBookmarked(postId(1), server: true), isTrue);
      expect(repo.isBookmarked(postId(1), server: false), isTrue);
    });

    test('recordListed leaves an in-flight intent alone and notifies '
        'only on a change', () async {
      unawaited(repo.setBookmarked(postId(1), saved: false, server: true));
      await settle();
      events.clear();
      repo.recordListed([postId(1)]);
      expect(repo.isBookmarked(postId(1), server: true), isFalse);
      expect(events, isEmpty);

      repo.recordListed([postId(5)]);
      expect(events.whereType<BookmarksChanged>(), hasLength(1));
      repo.recordListed([postId(5)]);
      expect(events.whereType<BookmarksChanged>(), hasLength(1));
    });
  });

  group('session', () {
    test('ending the epoch empties the overlay for every reader', () async {
      repo.recordListed([postId(1)]);
      final future = repo.setBookmarked(postId(2), saved: true);
      await settle();
      calls.single.ok();
      await future;
      expect(repo.isBookmarked(postId(1)), isTrue);
      expect(repo.isBookmarked(postId(2)), isTrue);

      epoch.end();

      expect(repo.isBookmarked(postId(1)), isFalse);
      expect(repo.isBookmarked(postId(2)), isFalse);
      expect(repo.snapshot(), isEmpty);
    });

    test('an answer that lands after sign-out is ignored', () async {
      final future = repo.setBookmarked(postId(1), saved: true);
      await settle();
      epoch.end();

      calls.single.ok();
      await future;

      expect(repo.isBookmarked(postId(1)), isFalse);
      expect(events.whereType<BookmarkSettled>(), isEmpty);
      expect(events.whereType<BookmarkFailed>(), isEmpty);
    });

    test('an error that lands after sign-out is not shown to the next '
        'user', () async {
      final future = repo.setBookmarked(postId(1), saved: true);
      await settle();
      epoch.end();
      calls.single.fail(const NetworkException('offline'));
      await future;
      expect(events.whereType<BookmarkFailed>(), isEmpty);
    });

    test('clearSession drops entries and in-flight work', () async {
      repo.recordListed([postId(1)]);
      final future = repo.setBookmarked(postId(2), saved: true);
      await settle();
      repo.clearSession();
      calls.single.ok();
      await future;
      expect(repo.snapshot(), isEmpty);
      expect(events.whereType<BookmarkSettled>(), isEmpty);
    });

    test('a toggle after sign-out starts clean', () async {
      repo.recordListed([postId(1)]);
      epoch.end();
      final future = repo.setBookmarked(postId(1), saved: true);
      await settle();
      expect(calls, hasLength(1), reason: 'not "already bookmarked"');
      calls.single.ok();
      await future;
    });
  });

  group('flag', () {
    test('AddBookmark with the flag off sends nothing and is rolled '
        'back', () async {
      enabled = false;
      await repo.setBookmarked(postId(1), saved: true);

      expect(calls, isEmpty);
      expect(repo.isBookmarked(postId(1)), isFalse);
      final failed = events.whereType<BookmarkFailed>().single;
      expect(failed.error, isA<FeatureDisabledException>());
    });

    test('RemoveBookmark ignores the bookmarks gate (ADR-0023 D5): a user '
        'dropped from the allowlist can still remove', () async {
      enabled = false;
      final future = repo.setBookmarked(postId(1), saved: false, server: true);
      await settle();
      expect(calls.single.procedure, _remove);
      calls.single.ok();
      await future;
      expect(repo.isBookmarked(postId(1), server: true), isFalse);
    });

    test('FEATURE_DISABLED to Add is remembered, asks for a GetMe, and '
        'does not block Remove', () async {
      immediate = (_) => _Reply.error(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          metadata: {'feature': 'bookmarks'},
        ),
      );
      await repo.setBookmarked(postId(1), saved: true);
      expect(refreshAsked, 1);
      expect(repo.enabled, isFalse);
      expect(
        events.whereType<BookmarkFailed>().single.error,
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          'bookmarks',
        ),
      );

      immediate = (_) => const _Reply.ok();
      await repo.setBookmarked(postId(2), saved: false, server: true);
      expect(calls.last.procedure, _remove);
      expect(events.whereType<BookmarkSettled>().single.saved, isFalse);
    });
  });
}

class _Reply {
  const _Reply.ok() : error = null;
  _Reply.error(Object this.error);

  final Object? error;
}
