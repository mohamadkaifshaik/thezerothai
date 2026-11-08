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
  bool canRequest = false,
  bool canWithdraw = false,
  bool canLeave = false,
  pb.ParticipantState state = pb.ParticipantState.PARTICIPANT_STATE_UNSPECIFIED,
}) => pb.BeaconView(
  beacon: pb.Beacon(beaconId: _bid, title: 'Coffee'),
  viewer: pb.ViewerState(
    canRequest: canRequest,
    canWithdraw: canWithdraw,
    canLeave: canLeave,
    participantState: state,
  ),
);

/// The viewer's actions (R35, R36): each sends one key, is busy while it
/// runs, and ends with a fresh GetBeacon so the buttons follow the server.
void main() {
  late _MockBeacons beacons;
  late List<pb.BeaconView> gets;

  setUp(() {
    beacons = _MockBeacons();
    gets = [];
    when(() => beacons.getBeacon(_bid))
        .thenAnswer((_) async => gets.removeAt(0));
  });

  List<String> keysOf(void Function() call) =>
      verify(call).captured.cast<String>();

  test(
    'request sends the note and key, is busy, then reloads the view',
    () async {
      gets.addAll([
        _view(canRequest: true),
        _view(
          canWithdraw: true,
          state: pb.ParticipantState.PARTICIPANT_STATE_REQUESTED,
        ),
      ]);
      when(
        () => beacons.requestToJoin(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
          note: any(named: 'note'),
        ),
      ).thenAnswer((_) async => pb.ViewerState(canWithdraw: true));
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();
      final seen = <BeaconAction?>[];
      final sub = cubit.stream.listen((s) => seen.add(s.busy));

      final ok = await cubit.request('see you');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(ok, isTrue);
      expect(seen.first, BeaconAction.request);
      expect(cubit.state.busy, isNull);
      expect(cubit.state.view?.viewer.canWithdraw, isTrue);
      expect(cubit.state.actionError, isNull);
      verify(() => beacons.getBeacon(_bid)).called(2);
      final sent = verify(
        () => beacons.requestToJoin(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          beaconId: _bid,
          note: captureAny(named: 'note'),
        ),
      ).captured;
      expect(sent[0], isNotEmpty);
      expect(sent[1], 'see you');
    },
  );

  test(
    'a refused request sets the copy and still reloads; a retry reuses the '
    'key and a request after a success gets a new one (Review Focus 2)',
    () async {
      gets.addAll([
        _view(canRequest: true),
        _view(canRequest: true),
        _view(canWithdraw: true),
        _view(canRequest: true),
        _view(canWithdraw: true),
      ]);
      var fail = true;
      when(
        () => beacons.requestToJoin(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
          note: any(named: 'note'),
        ),
      ).thenAnswer((_) async {
        if (fail) throw StateConflictException('full');
        return pb.ViewerState(canWithdraw: true);
      });
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      expect(await cubit.request('x'), isFalse);
      expect(cubit.state.actionError, 'This plan is full.');
      verify(() => beacons.getBeacon(_bid)).called(2);
      fail = false;
      expect(await cubit.request('x'), isTrue);
      expect(cubit.state.actionError, isNull);
      expect(await cubit.request('x'), isTrue);

      final keys = keysOf(
        () => beacons.requestToJoin(
          idempotencyKey: captureAny(named: 'idempotencyKey'),
          beaconId: _bid,
          note: any(named: 'note'),
        ),
      );
      expect(keys, hasLength(3));
      expect(keys[0], keys[1]);
      expect(keys[2], isNot(keys[0]));
    },
  );

  test('withdraw and leave send their key and reload', () async {
    gets.addAll([
      _view(canWithdraw: true),
      _view(canRequest: true),
      _view(canLeave: true),
      _view(canRequest: true),
    ]);
    when(
      () => beacons.withdrawJoinRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).thenAnswer((_) async {});
    when(
      () => beacons.leaveBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).thenAnswer((_) async {});
    final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
    await cubit.load();

    expect(await cubit.withdraw(), isTrue);
    expect(cubit.state.view?.viewer.canRequest, isTrue);
    await cubit.load();
    expect(await cubit.leave(), isTrue);
    expect(cubit.state.view?.viewer.canRequest, isTrue);

    verify(
      () => beacons.withdrawJoinRequest(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).called(1);
    verify(
      () => beacons.leaveBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).called(1);
    verify(() => beacons.getBeacon(_bid)).called(4);
  });

  test('a refused leave keeps the view and names the reason', () async {
    gets.addAll([_view(canLeave: true), _view(canLeave: true)]);
    when(
      () => beacons.leaveBeacon(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
      ),
    ).thenThrow(StateConflictException('not_participant'));
    final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
    await cubit.load();

    expect(await cubit.leave(), isFalse);
    expect(cubit.state.actionError, "You're not in this plan any more.");
    expect(cubit.state.busy, isNull);
  });

  group('request keys follow the payload (C01)', () {
    void stubRequest({required bool Function() fails}) {
      when(
        () => beacons.requestToJoin(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
          note: any(named: 'note'),
        ),
      ).thenAnswer((_) async {
        if (fails()) throw NetworkException('offline');
        return pb.ViewerState(canWithdraw: true);
      });
    }

    List<String> requestKeys() => keysOf(
      () => beacons.requestToJoin(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        beaconId: _bid,
        note: any(named: 'note'),
      ),
    );

    test('an edited note after a failure gets a new key', () async {
      gets.addAll(List.generate(3, (_) => _view(canRequest: true)));
      stubRequest(fails: () => true);
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      expect(await cubit.request('first'), isFalse);
      expect(await cubit.request('second'), isFalse);

      final keys = requestKeys();
      expect(keys, hasLength(2));
      expect(keys[1], isNot(keys[0]));
    });

    test('the same note retried after a failure reuses the key', () async {
      gets.addAll(List.generate(3, (_) => _view(canRequest: true)));
      stubRequest(fails: () => true);
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      expect(await cubit.request('same'), isFalse);
      expect(await cubit.request('same'), isFalse);

      final keys = requestKeys();
      expect(keys[1], keys[0]);
    });

    test('request, withdraw, request again uses a fresh key', () async {
      gets.addAll(List.generate(4, (_) => _view(canRequest: true)));
      stubRequest(fails: () => false);
      when(
        () => beacons.withdrawJoinRequest(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
        ),
      ).thenAnswer((_) async {});
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      expect(await cubit.request('same'), isTrue);
      expect(await cubit.withdraw(), isTrue);
      expect(await cubit.request('same'), isTrue);

      final keys = requestKeys();
      expect(keys, hasLength(2));
      expect(keys[1], isNot(keys[0]));
    });
  });

  group('leave and withdraw treat NOT_FOUND as done', () {
    test('withdraw: no copy, ok, reloads', () async {
      gets.addAll([_view(canWithdraw: true), _view(canRequest: true)]);
      when(
        () => beacons.withdrawJoinRequest(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
        ),
      ).thenThrow(NotFoundException('gone'));
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      expect(await cubit.withdraw(), isTrue);
      expect(cubit.state.actionError, isNull);
      expect(cubit.state.view?.viewer.canRequest, isTrue);
      verify(() => beacons.getBeacon(_bid)).called(2);
    });

    test('leave: no copy, ok, reloads', () async {
      gets.addAll([_view(canLeave: true), _view(canRequest: true)]);
      when(
        () => beacons.leaveBeacon(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
        ),
      ).thenThrow(NotFoundException('gone'));
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      expect(await cubit.leave(), isTrue);
      expect(cubit.state.actionError, isNull);
      verify(() => beacons.getBeacon(_bid)).called(2);
    });

    test('a failed reload after NOT_FOUND shows the load error', () async {
      var calls = 0;
      when(() => beacons.getBeacon(_bid)).thenAnswer((_) async {
        if (calls++ == 0) return _view(canLeave: true);
        throw NotFoundException('gone');
      });
      when(
        () => beacons.leaveBeacon(
          idempotencyKey: any(named: 'idempotencyKey'),
          beaconId: _bid,
        ),
      ).thenThrow(NotFoundException('gone'));
      final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
      await cubit.load();

      await cubit.leave();
      expect(cubit.state.actionError, isNull);
      expect(cubit.state.status, BeaconDetailStatus.error);
    });
  });

  test('the note is trimmed before it is keyed and sent', () async {
    gets.addAll(List.generate(3, (_) => _view(canRequest: true)));
    when(
      () => beacons.requestToJoin(
        idempotencyKey: any(named: 'idempotencyKey'),
        beaconId: _bid,
        note: any(named: 'note'),
      ),
    ).thenThrow(NetworkException('offline'));
    final cubit = BeaconDetailCubit(repository: beacons, beaconId: _bid);
    await cubit.load();

    await cubit.request(' hi ');
    await cubit.request('hi');

    final captured = verify(
      () => beacons.requestToJoin(
        idempotencyKey: captureAny(named: 'idempotencyKey'),
        beaconId: _bid,
        note: captureAny(named: 'note'),
      ),
    ).captured;
    expect(captured[1], 'hi');
    expect(captured[3], 'hi');
    expect(captured[0], captured[2]);
  });
}
