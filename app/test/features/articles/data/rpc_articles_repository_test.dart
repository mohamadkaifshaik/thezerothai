import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/articles/data/rpc_articles_repository.dart';
import 'package:dzeroth/features/articles/domain/article.dart';
import 'package:dzeroth/features/articles/domain/articles_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/articles/v1/articles.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

void main() {
  late AppDatabase db;
  late TimelineStore store;
  late String uid;
  late bool enabled;
  late Completer<Object> reply;
  late RpcArticlesRepository repo;
  late FakeTransport transport;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = TimelineStore(db);
    uid = 'alice';
    enabled = true;
    reply = Completer<Object>();
    transport = FakeTransport((procedure, input) => reply.future);
    repo = RpcArticlesRepository(
      apiClient: ApiClient.withTransport(transport),
      store: store,
      gate: PostsFeatureGate(isPostsEnabled: () => enabled),
      currentUid: () => uid,
    );
  });
  tearDown(() => db.close());

  test('an article read cannot cross an account switch', () async {
    final read = repo.get('a' * 32);
    final check = expectLater(read, throwsStateError);
    uid = 'bob';
    db.sessionEpoch.end();
    reply.complete(
      pb.GetArticleResponse(
        article: pb.Article(
          articleId: 'a' * 32,
          authorId: 'alice',
          bodyJson: '[]',
        ),
      ),
    );
    await check;
  });

  test(
    'publication completing after sign-out cannot enter loaded feeds',
    () async {
      await store.applyColdOpen(
        const FeedKey.home(),
        posts: [postView(1)],
        sinceToken: 's',
        nextPageToken: '',
        session: store.session,
      );
      final record = ArticleRecord(
        draft: ArticleDraft(id: 'a' * 32, authorId: uid),
        updatedAt: DateTime.utc(2026),
      );
      final publish = repo.publish(record, idempotencyKey: 'key');
      final check = expectLater(publish, throwsStateError);
      uid = 'bob';
      db.sessionEpoch.end();
      reply.complete(
        pb.PublishArticleResponse(
          article: pb.Article(
            articleId: 'a' * 32,
            authorId: 'alice',
            bodyJson: '[]',
          ),
          post: postView(2, authorId: 'alice'),
        ),
      );
      await check;
      expect(
        (await store.read(const FeedKey.home())).posts
            .map((p) => p.post.postId),
        [postId(1)],
      );
    },
  );

  test('disabled articles make no RPC', () async {
    enabled = false;
    await expectLater(
      repo.list(published: false),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(transport.calledProcedures, isEmpty);
  });
}
