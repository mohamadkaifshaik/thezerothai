import 'dart:async';

import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/onboarding/data/identity_repository.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

/// A response that completes only when the test says so, so the test can
/// sign out while the RPC is in flight.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('graph: follow completing after sign-out writes nothing', () async {
    final gate = Completer<void>();
    final repo = GraphRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          await gate.future;
          return graph.FollowResponse(
            relationship: graph.Relationship(
              followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
            ),
          );
        }),
      ),
      database: db,
    );

    final pending = repo.follow(userId: 'target', idempotencyKey: 'k');
    await Future<void>.delayed(Duration.zero);
    await wipeSessionData(database: db);
    repo.clearCache();
    gate.complete();
    await pending;

    expect(await db.cachedFollowingIds(), isEmpty);
    // The in-memory cache must not carry the old user's follow either.
    expect(repo.cached('target'), isNull);
  });

  test('graph: follow within the same session still writes', () async {
    final repo = GraphRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport(
          (procedure, input) async => graph.FollowResponse(
            relationship: graph.Relationship(
              followState: graph.FollowState.FOLLOW_STATE_FOLLOWING,
            ),
          ),
        ),
      ),
      database: db,
    );

    await repo.follow(userId: 'target', idempotencyKey: 'k');

    expect(await db.cachedFollowingIds(), ['target']);
  });

  test('identity: GetMe completing after sign-out writes nothing', () async {
    final gate = Completer<void>();
    final repo = IdentityRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport((procedure, input) async {
          await gate.future;
          return identity.GetMeResponse(
            profile: identity.Profile(
              userId: 'old-user',
              handle: 'old',
              displayName: 'Old',
            ),
          );
        }),
      ),
      database: db,
    );

    final pending = repo.getMe();
    await Future<void>.delayed(Duration.zero);
    await wipeSessionData(database: db);
    gate.complete();
    await pending;

    expect(await db.profileByUserId('old-user'), isNull);
  });

  test('identity: GetMe within the same session still caches', () async {
    final repo = IdentityRepository(
      apiClient: ApiClient.withTransport(
        FakeTransport(
          (procedure, input) async => identity.GetMeResponse(
            profile: identity.Profile(
              userId: 'u1',
              handle: 'h',
              displayName: 'H',
            ),
          ),
        ),
      ),
      database: db,
    );

    await repo.getMe();

    expect(await db.profileByUserId('u1'), isNotNull);
  });
}
