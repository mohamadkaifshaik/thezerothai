import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacon_people_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacon_people_state.dart';
import 'package:dzeroth/features/graph/data/graph_repository.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/graph/v1/graph.pb.dart' as graph;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/beacons_fixtures.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

class _MockGraph extends Mock implements GraphRepository {}

const _bid = '1234567890123456789';
const _requested = pb.ParticipantFilter.PARTICIPANT_FILTER_REQUESTED;
const _accepted = pb.ParticipantFilter.PARTICIPANT_FILTER_ACCEPTED;

/// `/plans/:id/people` (R38): one ListParticipants per load, the organiser's
/// actions each with one key, and a reload after every action (R35).
void main() {
  late _MockBeacons beacons;
  late _MockGraph graphRepo;
  late List<({pb.ParticipantFilter filter, int limit, String token})> lists;

  setUpAll(() {
    registerFallbackValue(_accepted);
  });

  setUp(() {
    beacons = _MockBeacons();
    graphRepo = _MockGraph();
    lists = [];
  });

  void stubList(ParticipantsPage Function(String token) answer) {
    when(
      () => beacons.listParticipants(
        beaconId: _bid,
        filter: any(named: 'filter'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenAnswer((inv) async {
      final token = inv.namedArguments[#pageToken] as String;
      lists.add((
        filter: inv.namedArguments[#filter] as pb.ParticipantFilter,
        limit: inv.namedArguments[#limit] as int,
        token: token,
      ));
      return answer(token);
    });
  }

  BeaconPeopleCubit cubit(
    pb.ParticipantFilter filter, {
    bool withGraph = true,
  }) => BeaconPeopleCubit(
    repository: beacons,
    beaconId: _bid,
    filter: filter,
    graph: withGraph ? graphRepo : null,
  );

  test(
    'load sends the filter and 20; loadMore appends with the token',
    () async {
      stubList(
        (token) => token.isEmpty
            ? ParticipantsPage(
                participants: [participant(userId: 'u1')],
                nextPageToken: 't1',
              )
            : ParticipantsPage(participants: [participant(userId: 'u2')]),
      );
      final c = cubit(_accepted);

      await c.load();
      expect(c.state.status, PeopleLoad.ready);
      expect(c.state.rows.map((p) => p.user.userId), ['u1']);
      expect(c.state.hasMore, isTrue);
      expect(lists.single, (filter: _accepted, limit: 20, token: ''));

      await c.loadMore();
      expect(c.state.rows.map((p) => p.user.userId), ['u1', 'u2']);
      expect(c.state.hasMore, isFalse);
      expect(lists.last.token, 't1');
    },
  );

  test('a failed load is an error with nothing to show', () async {
    when(
      () => beacons.listParticipants(
        beaconId: _bid,
        filter: any(named: 'filter'),
        limit: any(named: 'limit'),
        pageToken: any(named: 'pageToken'),
      ),
    ).thenThrow(NotFoundException('gone'));
    final c = cubit(_accepted);
    await c.load();
    expect(c.state.status, PeopleLoad.error);
    expect(c.state.error, isA<NotFoundException>());
  });

  test('accept and decline respond with one key each and reload', () async {
    stubList(
      (_) => ParticipantsPage(participants: [participant(userId: 'u2')]),
    );
    when(
      () => beacons.respondToJoinRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: any(named: 'userId'),
        accept: any(named: 'accept'),
      ),
    ).thenAnswer((_) async => beaconView(startAt: DateTime.now()));
    final c = cubit(_requested);
    await c.load();
    final busy = <String?>[];
    final sub = c.stream.listen((s) => busy.add(s.busyUserId));

    expect(await c.accept('u2'), isTrue);
    expect(await c.decline('u3'), isTrue);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(busy, contains('u2'));
    expect(c.state.busyUserId, isNull);
    final captured = verify(
      () => beacons.respondToJoinRequest(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: captureAny(named: 'userId'),
        accept: captureAny(named: 'accept'),
      ),
    ).captured;
    expect(captured, [isNotEmpty, 'u2', true, isNotEmpty, 'u3', false]);
    expect(lists, hasLength(3)); // load + one reload per action
  });

  test('a refused accept keeps the rows, sets the copy and reuses the key on '
      'retry', () async {
    stubList(
      (_) => ParticipantsPage(participants: [participant(userId: 'u2')]),
    );
    when(
      () => beacons.respondToJoinRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: 'u2',
        accept: true,
      ),
    ).thenThrow(StateConflictException('full'));
    final c = cubit(_requested);
    await c.load();

    expect(await c.accept('u2'), isFalse);
    expect(c.state.actionError, 'This plan is full.');
    expect(c.state.rows, hasLength(1));
    expect(await c.accept('u2'), isFalse);
    final keys = verify(
      () => beacons.respondToJoinRequest(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: 'u2',
        accept: true,
      ),
    ).captured;
    expect(keys[0], keys[1]);
  });

  test('declineAndBlock declines, then blocks; a failed block still reloads '
      'and says so (Review Focus 3)', () async {
    stubList((_) => ParticipantsPage(participants: const []));
    when(
      () => beacons.respondToJoinRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: any(named: 'userId'),
        accept: false,
      ),
    ).thenAnswer((_) async => beaconView(startAt: DateTime.now()));
    when(
      () => graphRepo.block(
        userId: 'u2',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenThrow(NetworkException('offline'));
    final c = cubit(_requested);
    await c.load();

    expect(await c.declineAndBlock('u2'), isFalse);

    verify(
      () => beacons.respondToJoinRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: 'u2',
        accept: false,
      ),
    ).called(1);
    verify(
      () => graphRepo.block(
        userId: 'u2',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).called(1);
    expect(lists, hasLength(2));
    expect(c.state.actionError, isNotNull);
    expect(c.state.actionError, isNot(contains('offline')));

    when(
      () => graphRepo.block(
        userId: 'u3',
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((_) async => graph.Relationship());
    expect(await c.declineAndBlock('u3'), isTrue);
    expect(c.state.actionError, isNull);
  });

  test('remove sends the user and reloads', () async {
    stubList(
      (_) => ParticipantsPage(participants: [participant(userId: 'u2')]),
    );
    when(
      () => beacons.removeParticipant(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: 'u2',
      ),
    ).thenAnswer((_) async => beaconView(startAt: DateTime.now()));
    final c = cubit(_accepted);
    await c.load();

    expect(await c.remove('u2'), isTrue);

    verify(
      () => beacons.removeParticipant(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        userId: 'u2',
      ),
    ).called(1);
    expect(lists, hasLength(2));
  });
}
