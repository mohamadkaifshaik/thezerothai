import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/features/notifications/data/notifications_store.dart';
import 'package:dzeroth/features/notifications/presentation/bloc/follow_back_cubit.dart';
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pb.dart'
    as pb;
import 'package:dzeroth/gen/dzeroth/notifications/v1/notifications.pbenum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../../support/notifications_fixtures.dart';

class _MockGraph extends Mock implements GraphRepository {}

List<NotificationEntry> _entries(List<pb.Notification> items) =>
    snapshotOfNotifs(items).entries;

graph.Relationship _none(String id) => graph.Relationship(
  userId: id,
  followState: graph.FollowState.FOLLOW_STATE_NONE,
);

void main() {
  late _MockGraph repo;

  setUpAll(() => registerFallbackValue(<String>[]));

  setUp(() {
    repo = _MockGraph();
    when(() => repo.relationshipsFor(any())).thenAnswer(
      (call) async => {
        for (final id in call.positionalArguments.first as List<String>)
          id: _none(id),
      },
    );
  });

  group('followBackActorOf', () {
    test('a single-actor follow names its actor', () {
      expect(followBackActorOf(notif('f', actorId: 'u2')), 'u2');
    });
    test('a collapsed follow, another type or no id names nobody', () {
      expect(followBackActorOf(notif('f', actorCount: 2)), isNull);
      expect(
        followBackActorOf(
          notif('l', type: NotificationType.NOTIFICATION_TYPE_LIKE),
        ),
        isNull,
      );
      expect(followBackActorOf(notif('f', actorId: '')), isNull);
    });
  });

  blocTest<FollowBackCubit, FollowBackState>(
    'one batched call for the follow actors of a page, deduplicated',
    build: () => FollowBackCubit(graph: repo),
    act: (cubit) => cubit.resolve(
      _entries([
        notif('a', actorId: 'u1'),
        notif('b', actorId: 'u2'),
        notif('c', actorId: 'u1'),
        notif('d', actorId: 'u3', actorCount: 4),
        notif('e', type: NotificationType.NOTIFICATION_TYPE_LIKE),
      ]),
    ),
    expect: () => [
      FollowBackState(relationships: {'u1': _none('u1'), 'u2': _none('u2')}),
    ],
    verify: (_) {
      expect(verify(() => repo.relationshipsFor(captureAny())).captured, [
        ['u1', 'u2'],
      ]);
    },
  );

  blocTest<FollowBackCubit, FollowBackState>(
    'a page with no new follow actor costs nothing',
    build: () => FollowBackCubit(graph: repo),
    act: (cubit) async {
      await cubit.resolve(_entries([notif('a', actorId: 'u1')]));
      await cubit.resolve(_entries([notif('a', actorId: 'u1')]));
    },
    verify: (_) => verify(() => repo.relationshipsFor(any())).called(1),
  );

  blocTest<FollowBackCubit, FollowBackState>(
    'a failure marks the actors failed, and the next page asks again',
    build: () => FollowBackCubit(graph: repo),
    act: (cubit) async {
      when(() => repo.relationshipsFor(any()))
          .thenThrow(const NetworkException('offline'));
      await cubit.resolve(_entries([notif('a', actorId: 'u1')]));
      when(() => repo.relationshipsFor(any()))
          .thenAnswer((_) async => {'u1': _none('u1')});
      await cubit.resolve(_entries([notif('a', actorId: 'u1')]));
    },
    expect: () => [
      const FollowBackState(failed: {'u1'}),
      const FollowBackState(),
      FollowBackState(relationships: {'u1': _none('u1')}),
    ],
  );
}
