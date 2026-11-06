import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/feature_flags/service_feature_gate.dart';
import 'package:dzeroth/core/network/api_client.dart';
import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_transport.dart';
import '../../../support/posts_fixtures.dart';

const _svc = '/dzeroth.beacons.v1.BeaconService/';
const _key = 'key-0123456789-abcdef';
const _bid = '1234567890123456789';

pb.BeaconView _view({String id = _bid}) => pb.BeaconView(
  beacon: pb.Beacon(beaconId: id, title: 'Coffee'),
  viewer: pb.ViewerState(),
);

void main() {
  late FakeTransport transport;
  late BeaconsRepository repo;
  late List<Object> requests;
  late Object Function(String procedure) answer;
  var enabled = true;
  var reported = 0;

  setUp(() {
    enabled = true;
    reported = 0;
    requests = [];
    answer = (_) => throw StateError('unscripted');
    transport = FakeTransport((procedure, input) async {
      requests.add(input);
      final r = answer(procedure);
      if (r is Exception) throw r;
      return r;
    });
    repo = BeaconsRepository(
      apiClient: ApiClient.withTransport(transport),
      gate: ServiceFeatureGate(
        isEnabled: () => enabled,
        onUnexpectedError: (_, _) => reported++,
      ),
    );
  });

  String lastProcedure() =>
      transport.calledProcedures.last.substring(_svc.length);

  test('listBeacons defaults to the public audience', () async {
    answer = (_) =>
        pb.ListBeaconsResponse(views: [_view()], nextPageToken: 't1');

    final page = await repo.listBeacons(limit: 20);

    final sent = requests.single as pb.ListBeaconsRequest;
    expect(lastProcedure(), 'ListBeacons');
    expect(sent.public, isTrue);
    expect(sent.hasCommunityId(), isFalse);
    expect(sent.limit, 20);
    expect(sent.pageToken, isEmpty);
    expect(sent.hasFrom(), isFalse);
    expect(page.views.single.beacon.beaconId, _bid);
    expect(page.nextPageToken, 't1');
    expect(page.hasMore, isTrue);
  });

  test('listBeacons with a community and a page token', () async {
    answer = (_) => pb.ListBeaconsResponse();

    final page = await repo.listBeacons(communityId: 'c1', pageToken: 't1');

    final sent = requests.single as pb.ListBeaconsRequest;
    expect(sent.communityId, 'c1');
    expect(sent.public, isFalse);
    expect(sent.pageToken, 't1');
    expect(page.views, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('getBeacon sends the id and returns the view', () async {
    answer = (_) => pb.GetBeaconResponse(view: _view());

    final v = await repo.getBeacon(_bid);

    expect(lastProcedure(), 'GetBeacon');
    expect((requests.single as pb.GetBeaconRequest).beaconId, _bid);
    expect(v.beacon.title, 'Coffee');
  });

  test('createBeacon sets the key on the request it is given', () async {
    answer = (_) => pb.CreateBeaconResponse(view: _view());

    final v = await repo.createBeacon(
      idempotencyKey: _key,
      request: pb.CreateBeaconRequest(
        public: true,
        title: 'Coffee',
        venue: 'Hall',
      ),
    );

    final sent = requests.single as pb.CreateBeaconRequest;
    expect(lastProcedure(), 'CreateBeacon');
    expect(sent.idempotencyKey, _key);
    expect(sent.public, isTrue);
    expect(sent.title, 'Coffee');
    expect(v.beacon.beaconId, _bid);
  });

  test('cancelBeacon sends the key and the id', () async {
    answer = (_) => pb.CancelBeaconResponse();

    await repo.cancelBeacon(idempotencyKey: _key, beaconId: _bid);

    final sent = requests.single as pb.CancelBeaconRequest;
    expect(lastProcedure(), 'CancelBeacon');
    expect(sent.idempotencyKey, _key);
    expect(sent.beaconId, _bid);
  });

  test('flag off: no RPC, FEATURE_DISABLED beacons', () async {
    enabled = false;

    await expectLater(
      repo.getBeacon(_bid),
      throwsA(isA<FeatureDisabledException>()),
    );
    await expectLater(
      repo.listBeacons(),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, isEmpty);
    expect(repo.enabled, isFalse);
  });

  test('a server FEATURE_DISABLED is typed and stops further calls', () async {
    answer = (_) => serverError(
      connect.Code.failedPrecondition,
      common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
      metadata: {'feature': kFeatureBeacons},
    );

    await expectLater(
      repo.getBeacon(_bid),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureBeacons,
        ),
      ),
    );
    await expectLater(
      repo.getBeacon(_bid),
      throwsA(isA<FeatureDisabledException>()),
    );
    expect(requests, hasLength(1));
  });

  test('UNIMPLEMENTED is "not available yet": typed, not reported, '
      'gate stays on', () async {
    answer = (p) => p.endsWith('GetBeacon')
        ? connect.ConnectException(connect.Code.unimplemented, 'nope')
        : pb.ListBeaconsResponse();

    await expectLater(
      repo.getBeacon(_bid),
      throwsA(
        isA<FeatureDisabledException>().having(
          (e) => e.feature,
          'feature',
          kFeatureBeacons,
        ),
      ),
    );
    expect(reported, 0);
    expect(repo.enabled, isTrue);
    await repo.listBeacons();
  });

  test('NOT_FOUND is a typed NotFoundException', () async {
    answer = (_) =>
        connect.ConnectException(connect.Code.notFound, 'beacon not found');

    await expectLater(repo.getBeacon(_bid), throwsA(isA<NotFoundException>()));
  });

  test(
    'a state conflict is typed by its reason, never "profile required"',
    () async {
      answer = (_) => serverError(
        connect.Code.failedPrecondition,
        common.ErrorReason.ERROR_REASON_UNSPECIFIED,
        metadata: {'reason': 'ended'},
      );

      await expectLater(
        repo.cancelBeacon(idempotencyKey: _key, beaconId: _bid),
        throwsA(
          isA<StateConflictException>().having(
            (e) => e.reason,
            'reason',
            'ended',
          ),
        ),
      );
      expect(reported, 0);
    },
  );

  test(
    'requestToJoin sends the key, id and note and returns the viewer',
    () async {
      answer = (_) =>
          pb.RequestToJoinResponse(viewer: pb.ViewerState(canWithdraw: true));

      final v = await repo.requestToJoin(
        idempotencyKey: _key,
        beaconId: _bid,
        note: 'see you',
      );

      final sent = requests.single as pb.RequestToJoinRequest;
      expect(lastProcedure(), 'RequestToJoin');
      expect(sent.idempotencyKey, _key);
      expect(sent.beaconId, _bid);
      expect(sent.note, 'see you');
      expect(v.canWithdraw, isTrue);
    },
  );

  test('withdraw and leave send the key and the id', () async {
    answer = (p) => p.endsWith('WithdrawJoinRequest')
        ? pb.WithdrawJoinRequestResponse()
        : pb.LeaveBeaconResponse();

    await repo.withdrawJoinRequest(idempotencyKey: _key, beaconId: _bid);
    expect(lastProcedure(), 'WithdrawJoinRequest');
    await repo.leaveBeacon(idempotencyKey: _key, beaconId: _bid);
    expect(lastProcedure(), 'LeaveBeacon');
    expect((requests[0] as pb.WithdrawJoinRequestRequest).beaconId, _bid);
    expect((requests[1] as pb.LeaveBeaconRequest).idempotencyKey, _key);
  });

  test('respond maps accept and decline; remove sends the user', () async {
    answer = (p) => p.endsWith('RespondToJoinRequest')
        ? pb.RespondToJoinRequestResponse(view: _view())
        : pb.RemoveParticipantResponse(view: _view());

    await repo.respondToJoinRequest(
      idempotencyKey: _key,
      beaconId: _bid,
      userId: 'u2',
      accept: true,
    );
    await repo.respondToJoinRequest(
      idempotencyKey: _key,
      beaconId: _bid,
      userId: 'u2',
      accept: false,
    );
    final v = await repo.removeParticipant(
      idempotencyKey: _key,
      beaconId: _bid,
      userId: 'u2',
    );

    expect(
      (requests[0] as pb.RespondToJoinRequestRequest).response,
      pb.JoinResponse.JOIN_RESPONSE_ACCEPT,
    );
    final declined = requests[1] as pb.RespondToJoinRequestRequest;
    expect(declined.response, pb.JoinResponse.JOIN_RESPONSE_DECLINE);
    expect(declined.userId, 'u2');
    final removed = requests[2] as pb.RemoveParticipantRequest;
    expect(removed.userId, 'u2');
    expect(removed.beaconId, _bid);
    expect(v.beacon.beaconId, _bid);
  });

  test(
    'listParticipants sends the filter and token and maps the page',
    () async {
      answer = (_) => pb.ListParticipantsResponse(
        participants: [
          pb.Participant(
            state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
            note: 'hi',
          ),
        ],
        nextPageToken: 't2',
      );

      final page = await repo.listParticipants(
        beaconId: _bid,
        filter: pb.ParticipantFilter.PARTICIPANT_FILTER_REQUESTED,
        limit: 20,
        pageToken: 't1',
      );

      final sent = requests.single as pb.ListParticipantsRequest;
      expect(sent.beaconId, _bid);
      expect(sent.filter, pb.ParticipantFilter.PARTICIPANT_FILTER_REQUESTED);
      expect(sent.limit, 20);
      expect(sent.pageToken, 't1');
      expect(page.participants.single.note, 'hi');
      expect(page.hasMore, isTrue);
    },
  );

  test('listMyBeacons sends the role, window and limit', () async {
    answer = (_) => pb.ListMyBeaconsResponse(views: [_view()]);

    final page = await repo.listMyBeacons(
      role: pb.MyBeaconsRole.MY_BEACONS_ROLE_ORGANISER,
      window: pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST,
      limit: 20,
    );

    final sent = requests.single as pb.ListMyBeaconsRequest;
    expect(sent.role, pb.MyBeaconsRole.MY_BEACONS_ROLE_ORGANISER);
    expect(sent.window, pb.MyBeaconsWindow.MY_BEACONS_WINDOW_PAST);
    expect(sent.limit, 20);
    expect(page.views, hasLength(1));
    expect(page.hasMore, isFalse);
  });

  test(
    'updateBeacon sends only the fields set on the request, plus the key',
    () async {
      answer = (_) => pb.UpdateBeaconResponse(view: _view());

      await repo.updateBeacon(
        idempotencyKey: _key,
        request: pb.UpdateBeaconRequest(beaconId: _bid, title: 'Tea'),
      );

      final sent = requests.single as pb.UpdateBeaconRequest;
      expect(sent.idempotencyKey, _key);
      expect(sent.beaconId, _bid);
      expect(sent.hasTitle(), isTrue);
      expect(sent.title, 'Tea');
      expect(sent.hasDetails(), isFalse);
      expect(sent.hasOpenSpots(), isFalse);
    },
  );
}
