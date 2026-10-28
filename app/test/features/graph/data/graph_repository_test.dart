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
import '../../../support/posts_fixtures.dart' show serverError;

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
        database.sessionEpoch.value,
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
        verify(() => database.upsertFollowing('target', epoch: 0)).called(1);
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

      verify(() => database.removeFollowing('target', epoch: 0)).called(1);
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
      verify(() => database.removeFollowing('target', epoch: 0)).called(1);
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

  group('profileRelationshipFor (GetProfileRelationship, ADR-0024 D7)', () {
    late DateTime clock;
    late List<String> calls;

    setUp(() {
      clock = DateTime.now();
      calls = [];
    });

    GraphRepository build(
      Future<Object> Function(String procedure, Object input) onCall,
    ) {
      final apiClient = ApiClient.withTransport(
        FakeTransport((procedure, input) {
          calls.add(procedure.split('/').last);
          return onCall(procedure, input);
        }),
      );
      return GraphRepository(
        apiClient: apiClient,
        database: database,
        now: () => clock,
      );
    }

    Future<Object> live(String procedure, Object input) async {
      if (procedure.endsWith('/GetProfileRelationship')) {
        return graph.GetProfileRelationshipResponse(
          // No user_id on the wire: the repository fills in the requested id.
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
          followedBy: true,
        );
      }
      throw UnimplementedError(procedure);
    }

    test('one call answers both: the relationship and followed_by', () async {
      final repository = build(live);

      final result = await repository.profileRelationshipFor('target');

      expect(calls, ['GetProfileRelationship']);
      expect(result.followedBy, isTrue);
      expect(result.relationship.userId, 'target');
      expect(
        result.relationship.followState,
        graph.FollowState.FOLLOW_STATE_FOLLOWING,
      );
      expect(
        repository.cached('target')?.followState,
        graph.FollowState.FOLLOW_STATE_FOLLOWING,
      );
    });

    test('a fresh answer costs no call; a stale one asks again', () async {
      final repository = build(live);
      await repository.profileRelationshipFor('target');

      clock = clock.add(kFollowedByTtl - const Duration(seconds: 1));
      final again = await repository.profileRelationshipFor('target');
      expect(calls, hasLength(1));
      expect(again.followedBy, isTrue);

      clock = clock.add(const Duration(seconds: 2));
      await repository.profileRelationshipFor('target');
      expect(calls, hasLength(2));
    });

    test('a relationship known from a list row still asks for followed_by '
        '(rows never carry it)', () async {
      final repository = build(live);
      repository.primeFromListItem(
        graph.UserListItem(
          user: common.AuthorSnapshot(userId: 'target'),
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
          ),
        ),
        database.sessionEpoch.value,
      );

      final result = await repository.profileRelationshipFor('target');

      expect(calls, ['GetProfileRelationship']);
      expect(result.followedBy, isTrue);
    });

    test('block says the target no longer follows the viewer', () async {
      final repository = build((procedure, input) async {
        if (procedure.endsWith('/Block')) {
          return graph.BlockResponse(
            relationship: graph.Relationship(blocking: true),
          );
        }
        return live(procedure, input);
      });
      await repository.profileRelationshipFor('target');

      await repository.block(userId: 'target', idempotencyKey: 'k');
      final result = await repository.profileRelationshipFor('target');

      expect(calls, ['GetProfileRelationship', 'Block']);
      expect(result.followedBy, isFalse);
      expect(result.relationship.blocking, isTrue);
    });

    final unavailableCases = <String, Object>{
      'UNIMPLEMENTED (the skeleton, until W3-11)': connect.ConnectException(
        connect.Code.unimplemented,
        'GetProfileRelationship is not implemented yet',
      ),
      'FEATURE_DISABLED (the graph flag is off)': serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      ),
    };
    for (final unavailable in unavailableCases.entries) {
      test('${unavailable.key}: falls back to GetRelationships, followed_by '
          'unknown, and stops asking for a while', () async {
        final repository = build((procedure, input) async {
          if (procedure.endsWith('/GetProfileRelationship')) {
            throw unavailable.value;
          }
          return graph.GetRelationshipsResponse(
            relationships: [
              graph.Relationship(
                userId: 'target',
                followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
              ),
            ],
          );
        });

        final first = await repository.profileRelationshipFor('target');
        expect(calls, ['GetProfileRelationship', 'GetRelationships']);
        expect(first.followedBy, isNull);
        expect(
          first.relationship.followState,
          graph.FollowState.FOLLOW_STATE_FOLLOWING,
        );

        // Within the backoff window: no retry storm. A profile already known
        // costs nothing, a new one costs the plain GetRelationships.
        clock = clock.add(
          kProfileRelationshipBackoff - const Duration(seconds: 1),
        );
        final second = await repository.profileRelationshipFor('target');
        expect(second.followedBy, isNull);
        expect(second.relationship.userId, 'target');
        await repository.profileRelationshipFor('other');
        expect(calls, [
          'GetProfileRelationship',
          'GetRelationships',
          'GetRelationships',
        ]);

        // After it, one more attempt (the RPC may be live by now).
        clock = clock.add(const Duration(seconds: 2));
        await repository.profileRelationshipFor('target');
        expect(calls.where((c) => c == 'GetProfileRelationship'), hasLength(2));
      });
    }

    test('any other failure is thrown as its AppException and is not '
        'remembered', () async {
      final failures = <connect.ConnectException>[
        connect.ConnectException(connect.Code.notFound, 'gone'),
        serverError(
          connect.Code.failedPrecondition,
          common.ErrorReason.ERROR_REASON_PROFILE_REQUIRED,
        ),
        connect.ConnectException(connect.Code.resourceExhausted, 'slow down'),
      ];
      final expected = <Matcher>[
        isA<NotFoundException>(),
        isA<ProfileRequiredException>(),
        isA<QuotaExceededException>(),
      ];
      var attempt = 0;
      final repository = build((procedure, input) async {
        throw failures[attempt++];
      });

      for (final matcher in expected) {
        await expectLater(
          repository.profileRelationshipFor('target'),
          throwsA(matcher),
        );
      }
      // Each one reached the server: nothing was remembered as unavailable.
      expect(calls, [
        'GetProfileRelationship',
        'GetProfileRelationship',
        'GetProfileRelationship',
      ]);
    });

    test('clearCache forgets followed_by and the backoff', () async {
      var available = false;
      final repository = build((procedure, input) async {
        if (procedure.endsWith('/GetProfileRelationship') && !available) {
          throw connect.ConnectException(connect.Code.unimplemented, 'no');
        }
        if (procedure.endsWith('/GetRelationships')) {
          return graph.GetRelationshipsResponse(relationships: const []);
        }
        return live(procedure, input);
      });
      await repository.profileRelationshipFor('target');
      calls.clear();

      repository.clearCache();
      available = true;
      final result = await repository.profileRelationshipFor('target');

      expect(calls, ['GetProfileRelationship']);
      expect(result.followedBy, isTrue);
    });
  });

  group('follow of a protected account (ADR-0025 D6)', () {
    test(
      'REQUESTED is cached but never joins the local following set',
      () async {
        final repository = buildRepository((procedure, input) async {
          expect(procedure, endsWith('/Follow'));
          return graph.FollowResponse(
            relationship: graph.Relationship(
              followState: graph.FollowState.FOLLOW_STATE_REQUESTED,
            ),
          );
        });

        final relationship = await repository.follow(
          userId: 'target',
          idempotencyKey: 'key-1',
        );

        expect(
          relationship.followState,
          graph.FollowState.FOLLOW_STATE_REQUESTED,
        );
        expect(
          repository.cached('target')?.followState,
          graph.FollowState.FOLLOW_STATE_REQUESTED,
        );
        verifyNever(
          () => database.upsertFollowing(any(), epoch: any(named: 'epoch')),
        );
        verify(() => database.removeFollowing('target', epoch: 0)).called(1);
      },
    );
  });
}
