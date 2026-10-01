import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/storage/session_epoch.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_transport.dart';

class MockAppDatabase extends Mock implements AppDatabase {}

void main() {
  late MockAppDatabase database;

  setUp(() {
    database = MockAppDatabase();
    when(() => database.sessionEpoch).thenReturn(SessionEpoch());
    when(() => database.cachedFollowingIds()).thenAnswer((_) async => []);
    when(() => database.upsertFollowing(any(), epoch: any(named: 'epoch')))
        .thenAnswer((_) async {});
    when(() => database.removeFollowing(any(), epoch: any(named: 'epoch')))
        .thenAnswer((_) async {});
  });

  GraphRepository buildRepository(
    Future<Object> Function(String procedure, Object input) handler,
  ) {
    final apiClient = ApiClient.withTransport(FakeTransport(handler));
    return GraphRepository(apiClient: apiClient, database: database);
  }

  group('relationshipsFor', () {
    test('never re-fetches an id already cached this session', () async {
      var callCount = 0;
      final repository = buildRepository((procedure, input) async {
        if (procedure.endsWith('/GetRelationships')) {
          callCount++;
          final request = input as graph.GetRelationshipsRequest;
          return graph.GetRelationshipsResponse(
            relationships: [
              for (final id in request.userIds)
                graph.Relationship(
                  userId: id,
                  followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
                ),
            ],
          );
        }
        throw UnimplementedError(procedure);
      });

      final first = await repository.relationshipsFor(['a', 'b']);
      expect(callCount, 1);
      expect(first['a']!.followState, graph.FollowState.FOLLOW_STATE_FOLLOWING);

      // 'a' and 'b' are now cached; only 'c' should trigger a network call.
      await repository.relationshipsFor(['a', 'b', 'c']);
      expect(callCount, 2);
    });

    test('primeFromListItem seeds the cache at 0 extra reads', () async {
      var callCount = 0;
      final repository = buildRepository((procedure, input) async {
        callCount++;
        throw UnimplementedError(procedure);
      });

      repository.primeFromListItem(
        graph.UserListItem(
          user: common.AuthorSnapshot(userId: 'u1'),
          relationship: graph.Relationship(
            blocking: false,
            muting: true,
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
        ),
      );

      final result = await repository.relationshipsFor(['u1']);
      expect(callCount, 0);
      expect(result['u1']!.muting, isTrue);
    });

    test('an unknown id defaults to NONE without a server round trip for '
        'ids already answered in the same batch', () async {
      final repository = buildRepository((procedure, input) async {
        return graph.GetRelationshipsResponse(relationships: const []);
      });

      final result = await repository.relationshipsFor(['unknown']);
      expect(
        result['unknown']!.followState,
        graph.FollowState.FOLLOW_STATE_NONE,
      );
    });
  });

  group('follow/unfollow', () {
    test(
      'follow caches the relationship and updates the following cache',
      () async {
        final repository = buildRepository((procedure, input) async {
          expect(procedure, endsWith('/Follow'));
          final request = input as graph.FollowRequest;
          expect(request.idempotencyKey, 'key-1');
          return graph.FollowResponse(
            relationship: graph.Relationship(
              followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
            ),
          );
        });

        final relationship = await repository.follow(
          userId: 'target',
          idempotencyKey: 'key-1',
        );

        expect(relationship.userId, 'target');
        expect(
          relationship.followState,
          graph.FollowState.FOLLOW_STATE_FOLLOWING,
        );
        expect(
          repository.cached('target')?.followState,
          graph.FollowState.FOLLOW_STATE_FOLLOWING,
        );
        verify(
          () => database.upsertFollowing('target', epoch: any(named: 'epoch')),
        ).called(1);
      },
    );

    test('unfollow removes the row from the following cache', () async {
      final repository = buildRepository((procedure, input) async {
        expect(procedure, endsWith('/Unfollow'));
        return graph.UnfollowResponse(
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
        );
      });

      await repository.unfollow(userId: 'target', idempotencyKey: 'key-2');

      verify(
        () => database.removeFollowing('target', epoch: any(named: 'epoch')),
      ).called(1);
    });

    test('a server error is surfaced as the mapped AppException', () async {
      final repository = buildRepository((procedure, input) async {
        throw connect.ConnectException(connect.Code.notFound, 'no such user');
      });

      await expectLater(
        repository.follow(userId: 'missing', idempotencyKey: 'k'),
        throwsA(isA<NotFoundException>()),
      );
    });
  });

  group('block', () {
    test('also drops the target from the following cache', () async {
      final repository = buildRepository((procedure, input) async {
        expect(procedure, endsWith('/Block'));
        return graph.BlockResponse(
          relationship: graph.Relationship(blocking: true),
        );
      });

      final relationship = await repository.block(
        userId: 'target',
        idempotencyKey: 'key-3',
      );

      expect(relationship.blocking, isTrue);
      verify(
        () => database.removeFollowing('target', epoch: any(named: 'epoch')),
      ).called(1);
    });
  });

  group('list pages', () {
    test(
      'listFollowers primes the relationship cache from list rows',
      () async {
        final repository = buildRepository((procedure, input) async {
          expect(procedure, endsWith('/ListFollowers'));
          return graph.ListFollowersResponse(
            users: [
              graph.UserListItem(
                user: common.AuthorSnapshot(userId: 'row-1', handle: 'row1'),
                relationship: graph.Relationship(
                  followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
                ),
              ),
            ],
            nextPageToken: 'next',
          );
        });

        final page = await repository.listFollowers(
          userId: 'target',
          pageSize: 20,
          pageToken: '',
        );

        expect(page.items, hasLength(1));
        expect(page.hasMore, isTrue);
        expect(
          repository.cached('row-1')?.followState,
          graph.FollowState.FOLLOW_STATE_FOLLOWING,
        );
      },
    );
  });

  test('clearCache wipes the session relationship cache', () async {
    final repository = buildRepository((procedure, input) async {
      return graph.GetRelationshipsResponse(
        relationships: [graph.Relationship(userId: 'a')],
      );
    });
    await repository.relationshipsFor(['a']);
    expect(repository.cached('a'), isNotNull);

    repository.clearCache();

    expect(repository.cached('a'), isNull);
  });
}
