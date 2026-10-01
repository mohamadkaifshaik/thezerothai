import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/features/posts/domain/posts_feature_flag.dart';
import 'package:dzeroth/features/timeline/data/timeline_repository.dart';
import 'package:dzeroth/features/timeline/data/timeline_store.dart';
import 'package:dzeroth/features/timeline/domain/feed_key.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/gen/dzeroth/timeline/v1/timeline.pb.dart' as tl;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';
import '../support/posts_fixtures.dart';

/// The in-flight RPC of a user who signs out must never write into the next
/// user's cache (CLAUDE.md rule 10). Each test starts an RPC held at a gate,
/// signs out (`wipeSessionData` + the in-memory `clearCache`), then lets the
/// RPC complete.
void main() {
  late AppDatabase db;
  late TimelineRepository timeline;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    timeline = TimelineRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((_, _) async => throw StateError('unused')),
      ),
      store: TimelineStore(db),
      gate: PostsFeatureGate(isPostsEnabled: () => true),
    );
  });
  tearDown(() => db.close());

  Future<void> signOut([GraphRepository? graphRepository]) async {
    await wipeSessionData(database: db, timelineRepository: timeline);
    graphRepository?.clearCache();
  }

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue, reason: 'condition never became true');
  }

  GraphRepository graphWith(
    Future<Object> Function(String procedure, Object input) handler,
  ) => GraphRepository(
    apiClient: ApiClient.withTransport(FakeTransport(handler)),
    database: db,
  );

  IdentityRepository identityWith(
    Future<Object> Function(String procedure, Object input) handler,
  ) => IdentityRepository(
    apiClient: ApiClient.withTransport(FakeTransport(handler)),
    database: db,
  );

  graph.FollowResponse following() => graph.FollowResponse(
    relationship: graph.Relationship(
      followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
    ),
  );

  identity.GetMeResponse me(String id) => identity.GetMeResponse(
    profile: identity.Profile(userId: id, handle: 'h$id', displayName: id),
  );

  group('graph', () {
    test('follow completing after sign-out writes nothing', () async {
      final gate = Completer<void>();
      final repo = graphWith((_, _) async {
        await gate.future;
        return following();
      });

      final pending = repo.follow(userId: 'target', idempotencyKey: 'k');
      await signOut(repo);
      gate.complete();
      await pending;

      expect(await db.cachedFollowingIds(), isEmpty);
      expect(repo.cached('target'), isNull);
    });

    test('a follow in the NEXT session still persists', () async {
      final repo = graphWith((_, _) async => following());
      await repo.follow(userId: 'a', idempotencyKey: 'k1');
      await signOut(repo);

      await repo.follow(userId: 'b', idempotencyKey: 'k2');

      expect(await db.cachedFollowingIds(), ['b']);
      expect(repo.cached('b'), isNotNull);
    });

    test('relationshipsFor completing after sign-out leaves the cache '
        'empty', () async {
      final gate = Completer<void>();
      final repo = graphWith((_, _) async {
        await gate.future;
        return graph.GetRelationshipsResponse(
          relationships: [
            graph.Relationship(
              userId: 'x',
              blocking: true,
              followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
            ),
          ],
        );
      });

      final pending = repo.relationshipsFor(['x']);
      await signOut(repo);
      gate.complete();
      await pending;

      expect(repo.cached('x'), isNull);
    });

    test(
      'a list page completing after sign-out leaves the cache empty',
      () async {
        final gate = Completer<void>();
        final repo = graphWith((_, _) async {
          await gate.future;
          return graph.ListFollowersResponse(
            users: [
              graph.UserListItem(
                user: common.AuthorSnapshot(userId: 'x'),
                relationship: graph.Relationship(muting: true),
              ),
            ],
          );
        });

        final pending = repo.listFollowers(
          userId: 'me',
          pageSize: 20,
          pageToken: '',
        );
        await signOut(repo);
        gate.complete();
        await pending;

        expect(repo.cached('x'), isNull);
      },
    );

    test(
      'primeFromDatabase racing a sign-out leaves the cache empty',
      () async {
        await db.upsertFollowing('old', epoch: db.sessionEpoch.value);
        final repo = graphWith((_, _) async => throw StateError('unused'));

        final pending = repo.primeFromDatabase();
        await signOut(repo);
        await pending;

        expect(repo.cached('old'), isNull);
      },
    );
  });

  group('identity', () {
    test('GetMe completing after sign-out writes nothing', () async {
      final gate = Completer<void>();
      final repo = identityWith((_, _) async {
        await gate.future;
        return me('old-user');
      });

      final pending = repo.getMe();
      await signOut();
      gate.complete();
      await pending;

      expect(await db.profileByUserId('old-user'), isNull);
    });

    test('a GetMe in the NEXT session still caches', () async {
      final repo = identityWith((_, _) async => me('u1'));
      await repo.getMe();
      await signOut();

      final repo2 = identityWith((_, _) async => me('u2'));
      await repo2.getMe();

      expect(await db.profileByUserId('u1'), isNull);
      expect(await db.profileByUserId('u2'), isNotNull);
    });
  });

  group('timeline', () {
    test('a refresh in flight at sign-out is not handed to the next user, '
        'and the next user\'s write lands', () async {
      const home = FeedKey.home();
      final gate = Completer<void>();
      var calls = 0;
      final store = TimelineStore(db);
      final repo = TimelineRepository(
        apiClient: ApiClient.withTransport(
          FakeTransport((procedure, input) async {
            calls++;
            if (calls == 1) {
              await gate.future;
              return tl.GetHomeTimelineResponse(
                posts: [postView(1, authorId: 'old')],
                sinceToken: 'old-since',
              );
            }
            return tl.GetHomeTimelineResponse(
              posts: [postView(9, authorId: 'new')],
              sinceToken: 'new-since',
            );
          }),
        ),
        store: store,
        gate: PostsFeatureGate(isPostsEnabled: () => true),
      );

      final first = repo.refresh(home);
      await until(() => calls == 1);
      await wipeSessionData(database: db, timelineRepository: repo);

      // The new user must run a fresh fetch (not share the old future, not
      // queue behind the old lock) and the write must land.
      final second = await repo.refresh(home);
      expect(calls, 2);
      expect(second.sinceToken, 'new-since');

      gate.complete();
      await first;

      final snap = await store.read(home);
      expect(snap.sinceToken, 'new-since');
      expect(
        [for (final e in snap.entries) e.postView!.post.postId],
        [postId(9)],
      );
    });
  });
}
