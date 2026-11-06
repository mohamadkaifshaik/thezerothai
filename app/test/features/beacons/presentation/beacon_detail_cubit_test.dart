import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/beacons/data/beacons_repository.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacon_detail_cubit.dart';
import 'package:dzeroth/features/beacons/presentation/bloc/beacon_detail_state.dart';
import 'package:dzeroth/gen/dzeroth/beacons/v1/beacons.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockBeacons extends Mock implements BeaconsRepository {}

const _bid = '1234567890123456789';

pb.BeaconView _view({
  pb.BeaconStatus status = pb.BeaconStatus.BEACON_STATUS_OPEN,
  bool canManage = true,
}) => pb.BeaconView(
  beacon: pb.Beacon(beaconId: _bid, title: 'Coffee', status: status),
  viewer: pb.ViewerState(canManage: canManage),
);

/// `/plans/:id`: one GetBeacon, and the organiser's Cancel (R32). The status
/// shown is always the server's.
void main() {
  late _MockBeacons beacons;

  setUp(() {
    beacons = _MockBeacons();
  });

  test('load is ready with the view; NOT_FOUND is an error', () async {
    when(() => beacons.getBeacon(_bid)).thenAnswer((_) async => _view());
    final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);

    await cubit.load();

    expect(cubit.state.status, BeaconDetailStatus.ready);
    expect(cubit.state.view?.beacon.title, 'Coffee');

    when(() => beacons.getBeacon(_bid)).thenThrow(NotFoundException('gone'));
    await cubit.load();
    expect(cubit.state.status, BeaconDetailStatus.error);
    expect(cubit.state.error, isA<NotFoundException>());
  });

  test(
    'cancel sends one key, shows busy, then the view reads CANCELLED',
    () async {
      final gets = [
        _view(),
        _view(status: pb.BeaconStatus.BEACON_STATUS_CANCELLED),
      ];
      when(() => beacons.getBeacon(_bid))
          .thenAnswer((_) async => gets.removeAt(0));
      when(
        () => beacons.cancelBeacon(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
        ),
      ).thenAnswer((_) async {});
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();
      final seen = <bool>[];
      final sub = cubit.stream.listen((s) => seen.add(s.cancelBusy));

      await cubit.cancel();
      // The stream delivers the last state a tick after the call returns.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen.first, isTrue);
      expect(seen.last, isFalse);
      expect(
        cubit.state.view?.beacon.status,
        pb.BeaconStatus.BEACON_STATUS_CANCELLED,
      );
      expect(cubit.state.actionError, isNull);
      final key =
          verify(
                () => beacons.cancelBeacon(
                  idempotencyKey: captureAny(named: 'idempotencyKey'),
                  beaconId: _bid,
                ),
              ).captured.single
              as String;
      expect(key, isNotEmpty);
    },
  );

  test('a refused cancel keeps the view, sets the copy, and a retry reuses '
      'the key', () async {
    when(() => beacons.getBeacon(_bid)).thenAnswer((_) async => _view());
    when(
      () => beacons.cancelBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).thenThrow(StateConflictException('ended'));
    final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
    await cubit.load();

    await cubit.cancel();
    expect(cubit.state.cancelBusy, isFalse);
    expect(cubit.state.view?.beacon.status, pb.BeaconStatus.BEACON_STATUS_OPEN);
    expect(cubit.state.actionError, 'This plan has already ended.');

    await cubit.cancel();
    final keys = verify(
      () => beacons.cancelBeacon(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).captured;
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });
}
