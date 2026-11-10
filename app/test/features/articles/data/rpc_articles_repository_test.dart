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
import 'package:dzeroth/features/posts/domain/reply_audience.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/articles/v1/articles.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_articles_server.dart';
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
      isReplyAudienceEnabled: () => false,
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
          isReplyAudienceEnabled: () => false,
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
    test('the draft cap is a LimitReachedException naming article_drafts, '
        'not an unexpected error', () async {
      final reported = <Object>[];
      final reporting = RpcArticlesRepository(
        apiClient: ApiClient.withTransport(transport),
        store: store,
        gate: PostsFeatureGate(
          isPostsEnabled: () => true,
          onUnexpectedError: (error, _) => reported.add(error),
        ),
        currentUid: () => uid,
        isReplyAudienceEnabled: () => false,
      );
      reply.completeError(
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_LIMIT_REACHED,
          metadata: {'limit': kArticleDraftsLimit},
        ),
      );
      final error = await reporting
          .save(draft, expectedRevision: 0)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        isA<LimitReachedException>().having(
          (e) => e.quota,
          'quota',
          kArticleDraftsLimit,
        ),
      );
      expect(isArticleDraftLimit(error!), isTrue);
      expect(reported, isEmpty);
    });
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

  group('publish reply policy', () {
    late FakeArticlesServer server;
    // `reply_audience` in the viewer's enabled_features (GetMe).
    late bool flagListed;
    late RpcArticlesRepository publisher;
    setUp(() {
      server = FakeArticlesServer(
        articleId: 'a' * 32,
        authorId: 'alice',
        revision: 2,
      );
      flagListed = false;
      publisher = RpcArticlesRepository(
        apiClient: ApiClient.withTransport(FakeTransport(server.handle)),
        store: store,
        gate: PostsFeatureGate(isPostsEnabled: () => true),
        currentUid: () => uid,
        isReplyAudienceEnabled: () => flagListed,
      );
    });
    ArticleRecord draft({
      bool pending = false,
      ReplyPolicy stored = ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
    }) => ArticleRecord(
      draft: ArticleDraft(id: 'a' * 32, authorId: uid, revision: 2),
      updatedAt: DateTime.now().toUtc(),
      publicationPending: pending,
      publicationReplyPolicy: stored,
    );

    test('with posts on and reply_audience off the default publish sends '
        'UNSPECIFIED and succeeds', () async {
      final published = await publisher.publish(draft(), idempotencyKey: 'k');
      expect(server.sent, [ReplyPolicy.REPLY_POLICY_UNSPECIFIED]);
      expect(published.published, isTrue);
    });

    test('the capability follows enabled_features and the gate', () {
      expect(publisher.canChooseReplyAudience, isFalse);
      flagListed = true;
      expect(publisher.canChooseReplyAudience, isTrue);
    });

    test(
      'with reply_audience on every choice maps like the composer',
      () async {
        flagListed = true;
        server.replyAudienceOn = true;
        for (final audience in ReplyAudience.values) {
          server.published = false;
          await publisher.publish(
            draft(),
            idempotencyKey: 'k-${audience.name}',
            replyAudience: audience,
          );
        }
        expect(server.sent, [
          ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
          ReplyPolicy.REPLY_POLICY_FOLLOWING,
          ReplyPolicy.REPLY_POLICY_MENTIONED_ONLY,
        ]);
      },
    );

    test('the flag turned off mid-session is FEATURE_DISABLED reply_audience '
        'and the capability goes until the next GetMe', () async {
      flagListed = true;
      final error = await publisher
          .publish(
            draft(),
            idempotencyKey: 'k',
            replyAudience: ReplyAudience.following,
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(
        error,
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureReplyAudience,
        ),
      );
      expect(publisher.canChooseReplyAudience, isFalse);
      // The refusal cleared the pending key: Everyone goes through.
      await publisher.publish(draft(), idempotencyKey: 'k');
      expect(server.sent.last, ReplyPolicy.REPLY_POLICY_UNSPECIFIED);
    });

    for (final stored in [
      // Left pending by a client that sent an explicit EVERYONE.
      ReplyPolicy.REPLY_POLICY_EVERYONE,
      ReplyPolicy.REPLY_POLICY_UNSPECIFIED,
      ReplyPolicy.REPLY_POLICY_FOLLOWING,
    ]) {
      test('a pending publication repeats its stored $stored', () async {
        server
          ..replyAudienceOn = true
          ..pendingKey = 'k'
          ..replyPolicy = stored;
        // The capability changed since the first attempt: the dialog shows
        // the stored choice locked, and the stored value goes out unchanged.
        final published = await publisher.publish(
          draft(pending: true, stored: stored),
          idempotencyKey: 'k',
          replyAudience: ReplyAudience.fromWire(stored),
        );
        expect(server.sent, [stored]);
        expect(published.published, isTrue);
      });
    }

    test('a retry after a lost reply resends the first choice even if the '
        'capability went in between', () async {
      flagListed = true;
      server
        ..replyAudienceOn = true
        ..loseNextReply = true;
      await expectLater(
        publisher.publish(
          draft(),
          idempotencyKey: 'k',
          replyAudience: ReplyAudience.following,
        ),
        throwsA(isA<NetworkException>()),
      );
      flagListed = false;
      // The screen keeps the first options for the key and the refresh says
      // pending; the stored FOLLOWING is resent, not a coerced UNSPECIFIED.
      await publisher.publish(
        draft(pending: true, stored: ReplyPolicy.REPLY_POLICY_FOLLOWING),
        idempotencyKey: 'k',
        replyAudience: ReplyAudience.following,
      );
      expect(server.sent, [
        ReplyPolicy.REPLY_POLICY_FOLLOWING,
        ReplyPolicy.REPLY_POLICY_FOLLOWING,
      ]);
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
