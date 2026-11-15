import 'package:drift/native.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/presentation/bloc/composer_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/pending_posts_cubit.dart';
import 'package:dzeroth/features/posts/presentation/bloc/post_sender.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../../support/fake_posts_server.dart';

const _uid = 'u1';

/// The hand-off of Post to the session's sender, against the real drafts
/// store: the unsent post survives a kill mid-send, one key is used, and the
/// row goes only when the post exists.
void main() {
  late AppDatabase db;
  late DraftsRepository repo;
  late FakePostsServer server;
  late PendingPostsCubit pending;
  late PostSender sender;
  late ComposerCubit cubit;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = DraftsRepository(db, autosaveDelay: const Duration(minutes: 10));
    server = FakePostsServer();
    pending = PendingPostsCubit();
    sender = PostSender(
      pending: pending,
      repository: server,
      drafts: repo,
      sessionEpoch: db.sessionEpoch,
      postedFor: const Duration(minutes: 10),
    );
    cubit = ComposerCubit(
      postsRepository: server,
      pending: pending,
      sender: sender,
      author: common.AuthorSnapshot(userId: _uid, handle: 'me'),
      drafts: repo,
      uid: _uid,
    );
  });

  tearDown(() async {
    repo.cancelPending();
    await cubit.close();
    await sender.dispose();
    await pending.close();
    await db.close();
  });

  Future<List<ComposerDraftRow>> rows() =>
      db.select(db.composerDraftEntries).get();

  test('Post hands off at once: the row holds the current text and the '
      'key CreatePost uses; it stays while the post is unsent and goes '
      'when it exists', () async {
    // Typed, never autosaved (the debounce is 10 minutes).
    cubit.textChanged('hello there');
    server.script.add(ServerReply.drop);

    await cubit.submit();
    await sender.idle;

    expect(cubit.state.status, ComposerStatus.handedOff);
    final kept = await rows();
    expect(kept.single.draftText, 'hello there');
    expect(kept.single.sendKey, server.receivedKeys.single);
    expect(pending.state.single.status, PendingPostStatus.failed);
    expect(pending.state.single.draftId, kept.single.draftId);

    await sender.retry(pending.state.single.localId);
    await sender.idle;

    expect(server.receivedKeys, hasLength(2));
    expect(server.receivedKeys.toSet(), hasLength(1), reason: 'one key');
    expect(server.accepted, hasLength(1));
    expect(await rows(), isEmpty);
    expect(pending.state.single.status, PendingPostStatus.posted);
  });

  test('a second Post tap after the hand-off sends nothing more', () async {
    cubit.textChanged('once');

    await cubit.submit();
    await cubit.submit();
    await sender.idle;

    expect(server.receivedKeys, hasLength(1));
    expect(pending.state, hasLength(1));
  });
}
