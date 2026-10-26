import 'dart:async';

import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/engagement/data/bookmarks_repository.dart';
import 'package:dzeroth/features/engagement/domain/bookmark_entry.dart';
import 'package:dzeroth/features/engagement/presentation/bloc/bookmarks_cubit.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/engagement/v1/engagement.pb.dart' as eng;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_transport.dart';
import '../../../../support/posts_fixtures.dart';

pb.PostView _view() => pb.PostView(
  post: pb.Post(
    postId: postId(1),
    author: common.AuthorSnapshot(userId: 'u1', handle: 'alice'),
  ),
);

void main() {
  late SessionEpoch epoch;
  late BookmarksRepository repo;
  late BookmarksCubit cubit;
  late List<Completer<Object>> pending;

  setUp(() {
    epoch = SessionEpoch();
    pending = [];
    repo = BookmarksRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) {
          final c = Completer<Object>();
          pending.add(c);
          return c.future;
        }),
      ),
      gate: ServiceFeatureGate(isEnabled: () => true),
      epoch: epoch,
    );
    cubit = BookmarksCubit(repository: repo);
  });

  tearDown(() async {
    await cubit.close();
    await repo.dispose();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('the default server adapter is the single W2-1b hook: no flag yet', () {
    expect(serverBookmarkedOf(_view()), isNull);
    expect(cubit.serverStateOf(_view()), isNull);
  });

  test('mirrors the optimistic entry, then the settled toast', () async {
    unawaited(cubit.setBookmarked(postId(1), _view(), saved: true));
    await settle();

    expect(cubit.isBookmarked(postId(1), _view()), isTrue);
    expect(cubit.state.entries[postId(1)]!.busy, isTrue);

    pending.single.complete(
      eng.AddBookmarkResponse(
        state: eng.BookmarkState(postId: postId(1), bookmarked: true),
      ),
    );
    await settle();

    expect(cubit.state.entries[postId(1)]!.busy, isFalse);
    expect(cubit.state.notice!.saved, isTrue);
    expect(cubit.state.notice!.postId, postId(1));
    cubit.noticeShown();
    expect(cubit.state.notice, isNull);
  });

  test('a failure is reported once with the failed intent', () async {
    unawaited(cubit.setBookmarked(postId(1), _view(), saved: true));
    await settle();
    pending.single.completeError(const NetworkException('offline'));
    await settle();

    expect(cubit.isBookmarked(postId(1), _view()), isFalse);
    final failure = cubit.state.failure!;
    expect(failure.saving, isTrue);
    expect(failure.error, isA<NetworkException>());
    cubit.failureShown();
    expect(cubit.state.failure, isNull);
  });

  test('a server flag from the injected adapter is honoured', () {
    final server = BookmarksCubit(repository: repo, serverStateOf: (_) => true);
    addTearDown(server.close);
    expect(server.isBookmarked(postId(1), _view()), isTrue);
  });

  test('reset (sign-out) forgets entries, toast and failure', () async {
    repo.recordListed([postId(1)]);
    expect(cubit.isBookmarked(postId(1), _view()), isTrue);

    cubit.reset();

    expect(cubit.state.entries, isEmpty);
    expect(cubit.isBookmarked(postId(1), _view()), isFalse);
    expect(repo.isBookmarked(postId(1)), isFalse);
  });

  test('the epoch ending (sign-out elsewhere) shows through the cubit too', () {
    repo.recordListed([postId(1)]);
    expect(cubit.state.entries, isNotEmpty);

    epoch.end();
    // The next write or event re-reads the session; a read alone is pure.
    repo.recordListed([postId(2)]);

    expect(cubit.isBookmarked(postId(1), _view()), isFalse);
    expect(cubit.state.entries.keys, [postId(2)]);
  });

  test('BookmarkEntry.resolve: precedence in one table', () {
    const listed = BookmarkEntry(saved: true);
    expect(listed.resolve(null), isTrue);
    expect(listed.resolve(false), isFalse, reason: 'server flag wins');

    const toggled = BookmarkEntry(saved: true, touched: true, base: false);
    expect(toggled.resolve(null), isTrue);
    expect(toggled.resolve(false), isTrue, reason: 'the row the user acted on');
    expect(toggled.resolve(true), isTrue);

    const busy = BookmarkEntry(
      saved: false,
      busy: true,
      touched: true,
      base: true,
    );
    expect(busy.resolve(true), isFalse, reason: 'in flight');
  });
}
