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
import '../../../support/suggestions_fixtures.dart' show suggestedUser;

class _MockDb extends Mock implements AppDatabase {}

/// W3-34: `ListFollowRequests` and `RespondToFollowRequest` on the repository.
void main() {
  late _MockDb database;
  late List<String> calls;
  late Duration clock;
  final base = DateTime.now();

  setUp(() {
    database = _MockDb();
    calls = [];
    clock = Duration.zero;
    when(() => database.sessionEpoch).thenReturn(SessionEpoch());
  });

  GraphRepository build(
    Future<Object> Function(String procedure, Object input) handler,
  ) {
    final client = ApiClient.withTransport(
      FakeTransport((procedure, input) {
        calls.add(procedure.split('/').last);
        return handler(procedure, input);
      }),
    );
    return GraphRepository(
      apiClient: client,
      database: database,
      now: () => base.add(clock),
    );
  }

  test('lists a page and sends the token back unchanged', () async {
    final repo = build((p, input) async {
      final request = input as graph.ListFollowRequestsRequest;
      expect(request.pageSize, 20);
      return graph.ListFollowRequestsResponse(
        requests: [suggestedUser(1)],
        nextPageToken: request.pageToken.isEmpty ? 'opaque==' : '',
      );
    });
    final first = await repo.listFollowRequests(pageSize: 20, pageToken: '');
    expect(first.items, hasLength(1));
    expect(first.nextPageToken, 'opaque==');
    final second = await repo.listFollowRequests(
      pageSize: 20,
      pageToken: first.nextPageToken,
    );
    expect(second.hasMore, isFalse);
  });

  test('follows the cursor through an empty page', () async {
    final repo = build((p, input) async {
      final request = input as graph.ListFollowRequestsRequest;
      return switch (request.pageToken) {
        '' => graph.ListFollowRequestsResponse(nextPageToken: 't1'),
        't1' => graph.ListFollowRequestsResponse(
          requests: [suggestedUser(2)],
          nextPageToken: '',
        ),
        _ => throw StateError('unexpected token'),
      };
    });
    final page = await repo.listFollowRequests(pageSize: 20, pageToken: '');
    expect(page.items.single.user.userId, 'u2');
    expect(calls, ['ListFollowRequests', 'ListFollowRequests']);
  });

  test('stops after a bounded number of empty pages', () async {
    final repo = build(
      (p, input) async => graph.ListFollowRequestsResponse(nextPageToken: 'x'),
    );
    final page = await repo.listFollowRequests(pageSize: 20, pageToken: '');
    expect(page.items, isEmpty);
    expect(page.hasMore, isTrue);
    expect(calls.length, lessThanOrEqualTo(6));
  });

  final unavailable = <String, Object>{
    'FEATURE_DISABLED': serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
    ),
    'UNIMPLEMENTED': connect.ConnectException(
      connect.Code.unimplemented,
      'not implemented',
    ),
  };
  for (final entry in unavailable.entries) {
    test('${entry.key} hides the list and backs off for 10 minutes', () async {
      final repo = build((p, input) async => throw entry.value);
      await expectLater(
        repo.listFollowRequests(pageSize: 20, pageToken: ''),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(repo.followRequestsUnavailable, isTrue);
      // Inside the window: no request at all.
      clock = kFollowRequestsBackoff - const Duration(seconds: 1);
      await expectLater(
        repo.listFollowRequests(pageSize: 20, pageToken: ''),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(calls, ['ListFollowRequests']);
      // After it: asked again.
      clock = kFollowRequestsBackoff + const Duration(seconds: 1);
      expect(repo.followRequestsUnavailable, isFalse);
      await expectLater(
        repo.listFollowRequests(pageSize: 20, pageToken: ''),
        throwsA(isA<FeatureDisabledException>()),
      );
      expect(calls, ['ListFollowRequests', 'ListFollowRequests']);
      // Sign-out clears it.
      repo.clearCache();
      expect(repo.followRequestsUnavailable, isFalse);
    });
  }

  test('an expired cursor surfaces as a page_token validation error', () async {
    final repo = build(
      (p, input) async => throw serverError(
        connect.Code.invalidArgument,
        common.ErrorReason.ERROR_REASON_VALIDATION,
        metadata: {'field': 'page_token'},
      ),
    );
    await expectLater(
      repo.listFollowRequests(pageSize: 20, pageToken: 'old'),
      throwsA(
        isA<ValidationException>().having(
          (e) => e.field,
          'field',
          'page_token',
        ),
      ),
    );
  });

  test(
    'respond sends the key and the answer, returns the relationship',
    () async {
      final repo = build((p, input) async {
        final request = input as graph.RespondToFollowRequestRequest;
        expect(request.idempotencyKey, 'key-1');
        expect(request.requesterUserId, 'u9');
        expect(request.accept, isTrue);
        return graph.RespondToFollowRequestResponse(
          relationship: graph.Relationship(
            followState: graph.FollowState.FOLLOW_STATE_NONE,
          ),
        );
      });
      final relationship = await repo.respondToFollowRequest(
        requesterUserId: 'u9',
        accept: true,
        idempotencyKey: 'key-1',
      );
      expect(relationship.userId, 'u9');
      expect(relationship.followState, graph.FollowState.FOLLOW_STATE_NONE);
      expect(repo.cached('u9'), isNotNull);
    },
  );

  test(
    'respond is never blocked by the list backoff (the undo rule)',
    () async {
      var listCalls = 0;
      final repo = build((p, input) async {
        if (input is graph.ListFollowRequestsRequest) {
          listCalls++;
          throw serverError(
            connect.Code.failedPrecondition,
            common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
          );
        }
        return graph.RespondToFollowRequestResponse(
          relationship: graph.Relationship(),
        );
      });
      await expectLater(
        repo.listFollowRequests(pageSize: 20, pageToken: ''),
        throwsA(isA<FeatureDisabledException>()),
      );
      await repo.respondToFollowRequest(
        requesterUserId: 'u1',
        accept: false,
        idempotencyKey: 'k',
      );
      expect(listCalls, 1);
      expect(calls, ['ListFollowRequests', 'RespondToFollowRequest']);
    },
  );
}
