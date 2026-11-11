import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/follow_requests_preview_cubit.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/suggestions_fixtures.dart';

class _MockGraph extends Mock implements GraphRepository {}

void main() {
  late _MockGraph repo;
  final rows = [for (var i = 1; i <= 3; i++) suggestedUser(i)];

  void stubList(Future<GraphPage> Function() answer) => when(
    () => repo.listFollowRequests(
      pageSize: any(named: 'pageSize'),
      pageToken: any(named: 'pageToken'),
    ),
  ).thenAnswer((_) => answer());

  void stubRespond(Future<graph.Relationship> Function() answer) => when(
    () => repo.respondToFollowRequest(
      requesterUserId: any(named: 'requesterUserId'),
      accept: any(named: 'accept'),
      idempotencyKey: any(named: 'idempotencyKey'),
    ),
  ).thenAnswer((_) => answer());

  setUp(() {
    repo = _MockGraph();
    stubList(() async => GraphPage(items: rows, nextPageToken: ''));
  });

  blocTest<FollowRequestsPreviewCubit, FollowRequestsPreviewState>(
    'nothing is asked until loadOnce; then one ListFollowRequests(3), once',
    build: () => FollowRequestsPreviewCubit(graph: repo),
    act: (cubit) async {
      await cubit.loadOnce();
      await cubit.loadOnce();
    },
    expect: () => [
      const FollowRequestsPreviewState(
        status: FollowRequestsPreviewStatus.loading,
      ),
      FollowRequestsPreviewState(
        status: FollowRequestsPreviewStatus.ready,
        items: rows,
      ),
    ],
    verify: (_) =>
        verify(() => repo.listFollowRequests(pageSize: 3, pageToken: ''))
            .called(1),
  );

  blocTest<FollowRequestsPreviewCubit, FollowRequestsPreviewState>(
    'FEATURE_DISABLED is unavailable (nothing drawn), reload does nothing',
    build: () => FollowRequestsPreviewCubit(graph: repo),
    setUp: () =>
        stubList(() async => throw const FeatureDisabledException('off')),
    act: (cubit) async {
      await cubit.loadOnce();
      await cubit.reload();
    },
    expect: () => [
      const FollowRequestsPreviewState(
        status: FollowRequestsPreviewStatus.loading,
      ),
      const FollowRequestsPreviewState(
        status: FollowRequestsPreviewStatus.unavailable,
      ),
    ],
  );

  blocTest<FollowRequestsPreviewCubit, FollowRequestsPreviewState>(
    'a failure offers Retry; reload asks again',
    build: () => FollowRequestsPreviewCubit(graph: repo),
    setUp: () => stubList(() async => throw const NetworkException('offline')),
    act: (cubit) async {
      await cubit.loadOnce();
      stubList(() async => GraphPage(items: rows, nextPageToken: ''));
      await cubit.reload();
    },
    skip: 2,
    expect: () => [
      const FollowRequestsPreviewState(
        status: FollowRequestsPreviewStatus.loading,
      ),
      FollowRequestsPreviewState(
        status: FollowRequestsPreviewStatus.ready,
        items: rows,
      ),
    ],
  );

  test('accept: the row leaves at once, the key is reused on a retry, and '
      'a failure puts the row back in place', () async {
    final cubit = FollowRequestsPreviewCubit(graph: repo);
    addTearDown(cubit.close);
    await cubit.loadOnce();
    stubRespond(() async => throw const NetworkException('offline'));

    final failed = await cubit.accept(rows[1]);
    expect(failed, isA<FollowRequestAcceptFailed>());
    expect(cubit.state.items, rows);

    stubRespond(() async => graph.Relationship(userId: 'u2'));
    final ok = await cubit.accept(rows[1]);
    expect(ok, isA<FollowRequestAccepted>());
    expect(cubit.state.items, [rows[0], rows[2]]);
    final keys = verify(
      () => repo.respondToFollowRequest(
        requesterUserId: 'u2',
        accept: true,
        idempotencyKey: captureAny(named: 'idempotencyKey'),
      ),
    ).captured;
    expect(keys, hasLength(2));
    expect(keys.first, keys.last);
    // A row that is no longer shown is not answered twice.
    expect(await cubit.accept(rows[1]), isNull);
  });

  test(
    'answering the last row shown asks again when the server has more',
    () async {
      stubList(() async => GraphPage(items: [rows[0]], nextPageToken: 'p2'));
      stubRespond(() async => graph.Relationship(userId: 'u1'));
      final cubit = FollowRequestsPreviewCubit(graph: repo);
      addTearDown(cubit.close);
      await cubit.loadOnce();
      expect(cubit.state.hasMore, isTrue);

      stubList(() async => GraphPage(items: [rows[2]], nextPageToken: ''));
      await cubit.accept(rows[0]);
      await pumpEventQueue();
      expect(cubit.state.items, [rows[2]]);
      verify(() => repo.listFollowRequests(pageSize: 3, pageToken: ''))
          .called(2);
    },
  );
}
