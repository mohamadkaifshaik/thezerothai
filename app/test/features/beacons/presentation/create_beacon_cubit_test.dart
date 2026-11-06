import 'dart:async';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/domain/beacons_feature_flag.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/create_beacon_cubit.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

pb.CreateBeaconRequest _request({String title = 'Coffee'}) =>
    pb.CreateBeaconRequest(public: true, title: title, venue: 'Hall');

pb.BeaconView _view() => pb.BeaconView(
  beacon: pb.Beacon(beaconId: '1234567890123456789', title: 'Coffee'),
  viewer: pb.ViewerState(canManage: true),
);

/// `/plans/new`: one CreateBeacon per submit, one idempotency key per
/// distinct payload, reused on a retry (R31).
void main() {
  late _MockBeacons beacons;

  setUpAll(() => registerFallbackValue(pb.CreateBeaconRequest()));

  setUp(() {
    beacons = _MockBeacons();
  });

  List<String> sentKeys() => verify(
    () => beacons.createBeacon(
      idempotencyKey: captureAny(named: 'idempotencyKey'),
      request: any(named: 'request'),
    ),
  ).captured.cast<String>();

  test('create is busy then created, and passes the request through', () async {
    pb.CreateBeaconRequest? sent;
    when(
      () => beacons.createBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        request: any(named: 'request'),
      ),
    ).thenAnswer((inv) async {
      sent = inv.namedArguments[#request] as pb.CreateBeaconRequest;
      return _view();
    });
    final cubit = CreateBeaconCubit(repository: beacons);
    final busy = <bool>[];
    final sub = cubit.stream.listen((s) => busy.add(s.busy));

    await cubit.create(_request());
    // The stream delivers the last state a tick after the call returns.
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(busy, [true, false]);
    expect(cubit.state.created?.beacon.beaconId, '1234567890123456789');
    expect(cubit.state.error, isNull);
    expect(sent?.title, 'Coffee');
    expect(sent?.public, isTrue);
  });

  test('a retry of the same payload reuses the key; a changed payload gets '
      'a new one', () async {
    var fail = true;
    when(
      () => beacons.createBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        request: any(named: 'request'),
      ),
    ).thenAnswer((_) async {
      if (fail) throw NetworkException('offline');
      return _view();
    });
    final cubit = CreateBeaconCubit(repository: beacons);

    await cubit.create(_request());
    expect(
      cubit.state.error,
      'No connection. Check your network and try again.',
    );
    expect(cubit.state.created, isNull);
    fail = false;
    await cubit.create(_request());
    await cubit.create(_request(title: 'Tea'));

    final keys = sentKeys();
    expect(keys, hasLength(3));
    expect(keys[0], keys[1]);
    expect(keys[2], isNot(keys[0]));
  });

  test('the open-plans limit reads as its copy and the form stays', () async {
    when(
      () => beacons.createBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        request: any(named: 'request'),
      ),
    ).thenThrow(LimitReachedException('no', quota: kBeaconsOpenLimit));
    final cubit = CreateBeaconCubit(repository: beacons);

    await cubit.create(_request());

    expect(cubit.state.busy, isFalse);
    expect(
      cubit.state.error,
      'You can have up to $kMaxOpenBeacons open plans. Cancel one to create '
      'another.',
    );
    expect(cubit.state.created, isNull);
  });

  test('a second create while busy is ignored', () async {
    final gate = Completer<pb.BeaconView>();
    when(
      () => beacons.createBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        request: any(named: 'request'),
      ),
    ).thenAnswer((_) => gate.future);
    final cubit = CreateBeaconCubit(repository: beacons);

    final first = cubit.create(_request());
    await cubit.create(_request());
    gate.complete(_view());
    await first;

    expect(sentKeys(), hasLength(1));
  });
}
