import 'dart:async';

import 'package:connectrpc/connect.dart' as connect;
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
        updatedAt: DateTime.now().toUtc(),
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

  test('list rows use the server excerpt and never decode a body', () async {
    reply.complete(
      pb.ListArticlesResponse(
        articles: [
          pb.Article(
            articleId: 'a' * 32,
            authorId: 'alice',
            title: 'Title',
            excerpt: 'Server excerpt',
          ),
          // A list row's body is never read, even if one were present.
          pb.Article(
            articleId: 'b' * 32,
            authorId: 'alice',
            bodyJson: 'not json',
            excerpt: 'Second',
          ),
        ],
        nextPageToken: 'b' * 32,
      ),
    );
    final page = await repo.list(published: false);
    expect(page.articles.map((a) => a.summary), ['Server excerpt', 'Second']);
    expect(page.articles.every((a) => a.draft.blocks.isEmpty), isTrue);
    expect(page.nextPageToken, 'b' * 32);
  });

  test('get decodes the full body and keeps the excerpt', () async {
    reply.complete(
      pb.GetArticleResponse(
        article: pb.Article(
          articleId: 'a' * 32,
          authorId: 'alice',
          bodyJson:
              '[{"kind":"paragraph","runs":[{"text":"Full body","marks":[]}]}]',
          excerpt: 'Full body',
        ),
      ),
    );
    final record = await repo.get('a' * 32);
    expect(record.draft.blocks.single.plainText, 'Full body');
    expect(record.summary, 'Full body');
  });

  group('save', () {
    final draft = ArticleDraft(id: 'a' * 32, authorId: 'alice', revision: 1);
    test('a stale revision (ABORTED) is an ArticleRevisionConflict', () async {
      reply.completeError(
        connect.ConnectException(connect.Code.aborted, 'article changed'),
      );
      await expectLater(
        repo.save(draft, expectedRevision: 1),
        throwsA(isA<ArticleRevisionConflict>()),
      );
    });
    test(
      'an expected conflict is not reported as an unexpected error',
      () async {
        final reported = <Object>[];
        final reporting = RpcArticlesRepository(
          apiClient: ApiClient.withTransport(transport),
          store: store,
          gate: PostsFeatureGate(
            isPostsEnabled: () => true,
            onUnexpectedError: (error, _) => reported.add(error),
          ),
          currentUid: () => uid,
        );
        reply.completeError(
          connect.ConnectException(connect.Code.aborted, 'article changed'),
        );
        await expectLater(
          reporting.save(draft, expectedRevision: 1),
          throwsA(isA<ArticleRevisionConflict>()),
        );
        expect(reported, isEmpty);
      },
    );
    test('other failures keep their typed error', () async {
      reply.completeError(
        connect.ConnectException(connect.Code.notFound, 'article not found'),
      );
      await expectLater(
        repo.save(draft, expectedRevision: 1),
        throwsA(isA<NotFoundException>()),
      );
    });
  });

  test('disabled articles make no RPC', () async {
    enabled = false;
    await expectLater(
      repo.list(published: false),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(transport.calledProcedures, isEmpty);
  });
}
