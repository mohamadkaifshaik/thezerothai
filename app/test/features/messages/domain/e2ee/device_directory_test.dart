import 'dart:async';
import 'dart:convert';

import 'package:dzeroth/core/network/app_exception.dart';
import 'package:dzeroth/features/keys/data/keys_repository.dart';
import 'package:dzeroth/features/messages/domain/e2ee/device_directory.dart';
import 'package:dzeroth/features/messages/domain/e2ee/sync_budget.dart';
import 'package:dzeroth/gen/dzeroth/keys/v1/keys.pb.dart' as pb;
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// A scripted [KeysRepository]: records the calls, answers from the hooks.
class _Keys implements KeysRepository {
  int listCalls = 0;
  final List<List<String>> getCalls = [];
  Future<pb.ListMyKeyDevicesResponse> Function() onList = () async =>
      pb.ListMyKeyDevicesResponse(devices: [_device(1)]);
  Future<pb.GetKeyDevicesResponse> Function(List<String> ids) onGet = (
    ids,
  ) async => _usersFor(ids);

  @override
  Future<pb.ListMyKeyDevicesResponse> listMine() {
    listCalls++;
    return onList();
  }

  @override
  Future<pb.GetKeyDevicesResponse> getDevices(List<String> userIds) {
    getCalls.add(List.of(userIds));
    return onGet(userIds);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected call');
}

pb.KeyDevice _device(int n, {bool inactive = false}) => pb.KeyDevice(
  deviceId: 'device-${n.toString().padLeft(12, '0')}',
  signaturePublicKey: List.filled(32, n),
  inactive: inactive,
);

pb.GetKeyDevicesResponse _usersFor(List<String> ids) =>
    pb.GetKeyDevicesResponse(
      users: [
        for (var i = 0; i < ids.length; i++)
          pb.UserKeyDevices(userId: ids[i], devices: [_device(i + 1)]),
      ],
    );

/// Counts the takes and the pauses; otherwise a real budget.
class _CountingBudget extends SyncBudget {
  _CountingBudget(DateTime Function() now)
    : super(perMinute: 1000, ownDeviceCount: () => 1, now: now);

  final List<BudgetPriority> taken = [];
  final List<DateTime> pauses = [];

  @override
  Future<void> take(BudgetPriority priority, {Object? lane}) {
    taken.add(priority);
    return super.take(priority, lane: lane);
  }

  @override
  void pauseUntil(DateTime until) {
    pauses.add(until);
    super.pauseUntil(until);
  }
}

class _Rig {
  _Rig() {
    budget = _CountingBudget(() => clock);
    directory = DeviceDirectory(keys: keys, budget: budget, now: () => clock);
  }

  DateTime clock = _epoch.add(const Duration(days: 1));
  final _Keys keys = _Keys();
  late final _CountingBudget budget;
  late final DeviceDirectory directory;

  void advance(Duration d) => clock = clock.add(d);
}

void main() {
  test('CANNOT_MESSAGE, FEATURE_DISABLED, a timeout and an unknown error are '
      'unreadable, never an empty readable list', () async {
    final errors = <Object>[
      const CannotMessageException(),
      const FeatureDisabledException('off'),
      TimeoutException('slow'),
      const NetworkException('offline'),
      const UnknownApiException('weird'),
      StateError('anything'),
    ];
    for (final error in errors) {
      final rig = _Rig();
      rig.keys.onList = () => Future.error(error);
      rig.keys.onGet = (_) => Future.error(error);
      final own = await rig.directory.own();
      final peer = await rig.directory.peer('p1');
      for (final list in [own, peer]) {
        expect(list.state, ListState.unreadable, reason: '$error');
        expect(list.readable, isFalse);
        expect(list.readableNonEmpty, isFalse);
        expect(list.devices, isEmpty);
        expect(list.fetchedAt, isNull);
      }
    }
  });

  test('a call past the 30 s deadline is unreadable', () {
    fakeAsync((async) {
      final rig = _Rig();
      rig.keys.onList = () => Completer<pb.ListMyKeyDevicesResponse>().future;
      DeviceList? out;
      rig.directory.own().then((l) => out = l);
      async.elapse(const Duration(seconds: 29));
      expect(out, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(out?.state, ListState.unreadable);
    });
  });

  test('RATE_LIMITED keeps the last readable list, pauses the budget until '
      'retry_after and reports deferred', () async {
    final rig = _Rig();
    final first = await rig.directory.peer('p1');
    expect(first.state, ListState.readable);
    final fetched = rig.clock;
    rig.advance(const Duration(minutes: 40));
    rig.keys.onGet = (_) => Future.error(
      const RateLimitedException('slow down', retryAfter: Duration(minutes: 5)),
    );
    final second = await rig.directory.peer('p1');
    expect(second.state, ListState.deferred);
    expect(second.readable, isFalse);
    expect(second.devices, hasLength(1));
    expect(second.fetchedAt, fetched);
    expect(rig.budget.pauses, [rig.clock.add(const Duration(minutes: 5))]);

    // While paused: no call at all, the same kept list.
    final callsBefore = rig.keys.getCalls.length;
    final third = await rig.directory.peer('p1', fresh: true);
    expect(third.state, ListState.deferred);
    expect(rig.keys.getCalls.length, callsBefore);
  });

  test('own returns deferred at once while the budget is paused', () async {
    final rig = _Rig();
    final first = await rig.directory.own();
    expect(first.readable, isTrue);
    rig.keys.onList = () => Future.error(
      const RateLimitedException('x', retryAfter: Duration(minutes: 5)),
    );
    final deferred = await rig.directory.own(fresh: true);
    expect(deferred.state, ListState.deferred);
    expect(deferred.devices, hasLength(1));
    final calls = rig.keys.listCalls;
    final again = await rig.directory.own(fresh: true);
    expect(again.state, ListState.deferred);
    expect(again.devices, hasLength(1));
    expect(rig.keys.listCalls, calls);
  });

  test('RATE_LIMITED with no list yet is deferred with no devices; with no '
      'hint the pause is one minute', () async {
    final rig = _Rig();
    rig.keys.onList = () =>
        Future.error(const RateLimitedException('slow down'));
    final own = await rig.directory.own();
    expect(own.state, ListState.deferred);
    expect(own.devices, isEmpty);
    expect(own.fetchedAt, isNull);
    expect(rig.budget.pauses, [rig.clock.add(const Duration(minutes: 1))]);
  });

  test(
    'a readable list is reused for 30 minutes and fetched again after',
    () async {
      final rig = _Rig();
      await rig.directory.peer('p1');
      rig.advance(const Duration(minutes: 29, seconds: 59));
      await rig.directory.peer('p1');
      expect(rig.keys.getCalls, hasLength(1));
      rig.advance(const Duration(seconds: 1));
      await rig.directory.peer('p1');
      expect(rig.keys.getCalls, hasLength(2));
      await rig.directory.own();
      await rig.directory.own();
      expect(rig.keys.listCalls, 1);
    },
  );

  test('fresh always calls', () async {
    final rig = _Rig();
    await rig.directory.peer('p1');
    await rig.directory.peer('p1', fresh: true);
    await rig.directory.own();
    await rig.directory.own(fresh: true);
    expect(rig.keys.getCalls, hasLength(2));
    expect(rig.keys.listCalls, 2);
  });

  test('peers batches 23 ids as 10, 10 and 3', () async {
    final rig = _Rig();
    final ids = [for (var i = 0; i < 23; i++) 'p$i'];
    final out = await rig.directory.peers(ids);
    expect(rig.keys.getCalls.map((c) => c.length), [10, 10, 3]);
    expect(rig.keys.getCalls.expand((c) => c), ids);
    expect(out.keys, ids);
    expect(out.values.every((l) => l.readableNonEmpty), isTrue);
  });

  test('a refused batch is retried singly once and the refused peer is '
      'parked', () async {
    final rig = _Rig();
    rig.keys.onGet = (ids) async {
      if (ids.length > 1 || ids.single == 'b') {
        throw const CannotMessageException();
      }
      return _usersFor(ids);
    };
    final out = await rig.directory.peers(['a', 'b', 'c']);
    expect(rig.keys.getCalls, [
      ['a', 'b', 'c'],
      ['a'],
      ['b'],
      ['c'],
    ]);
    expect(out['a']!.readableNonEmpty, isTrue);
    expect(out['b']!.state, ListState.unreadable);
    expect(out['c']!.readableNonEmpty, isTrue);
  });

  test('a parked peer is left out of later batches until markUsable', () async {
    final rig = _Rig();
    var refuseB = true;
    rig.keys.onGet = (ids) async {
      if (refuseB && ids.contains('b')) throw const CannotMessageException();
      return _usersFor(ids);
    };
    await rig.directory.peers(['a', 'b', 'c']);
    rig.keys.getCalls.clear();
    rig.advance(const Duration(minutes: 31));
    final out = await rig.directory.peers(['a', 'b', 'c']);
    expect(rig.keys.getCalls, [
      ['a', 'c'],
    ]);
    expect(out['b']!.state, ListState.unreadable);

    refuseB = false;
    rig.keys.getCalls.clear();
    rig.directory.markUsable('b');
    final again = await rig.directory.peers(['a', 'b', 'c']);
    expect(rig.keys.getCalls, [
      ['b'],
    ]);
    expect(again['b']!.readableNonEmpty, isTrue);
  });

  test('a parked peer is also forgotten by clear', () async {
    final rig = _Rig();
    rig.keys.onGet = (ids) async => throw const CannotMessageException();
    await rig.directory.peers(['b']);
    rig.keys.onGet = (ids) async => _usersFor(ids);
    rig.keys.getCalls.clear();
    rig.directory.clear();
    await rig.directory.peers(['b']);
    expect(rig.keys.getCalls, [
      ['b'],
    ]);
  });

  test('own uses ListMyKeyDevices and never GetKeyDevices', () async {
    final rig = _Rig();
    final own = await rig.directory.own(fresh: true);
    expect(own.readableNonEmpty, isTrue);
    expect(rig.keys.listCalls, 1);
    expect(rig.keys.getCalls, isEmpty);
    expect(utf8.decode(own.devices.single.deviceId), 'device-000000000001');
    expect(own.devices.single.signatureKey, List.filled(32, 1));
  });

  test('ownDeviceCount counts inactive devices', () async {
    final rig = _Rig();
    expect(rig.directory.ownDeviceCount, 5);
    rig.keys.onList = () async => pb.ListMyKeyDevicesResponse(
      devices: [_device(1), _device(2, inactive: true)],
    );
    final own = await rig.directory.own();
    expect(own.devices.map((d) => d.inactive), [false, true]);
    expect(rig.directory.ownDeviceCount, 2);
    rig.directory.clear();
    expect(rig.directory.ownDeviceCount, 5);
  });

  test('an empty readable list has readableNonEmpty false', () async {
    final rig = _Rig();
    rig.keys.onGet = (ids) async => pb.GetKeyDevicesResponse(
      users: [for (final id in ids) pb.UserKeyDevices(userId: id)],
    );
    final list = await rig.directory.peer('p1');
    expect(list.state, ListState.readable);
    expect(list.readable, isTrue);
    expect(list.readableNonEmpty, isFalse);
    expect(list.fetchedAt, rig.clock);
  });

  test('an answer that does not match the request is unreadable', () async {
    final rig = _Rig();
    rig.keys.onGet = (ids) async => pb.GetKeyDevicesResponse();
    expect((await rig.directory.peer('p1')).state, ListState.unreadable);
    rig.keys.onGet = (ids) async => pb.GetKeyDevicesResponse(
      users: [
        pb.UserKeyDevices(
          userId: 'p1',
          devices: [
            pb.KeyDevice(deviceId: 'short', signaturePublicKey: [1]),
          ],
        ),
      ],
    );
    expect((await rig.directory.peer('p1')).state, ListState.unreadable);
  });

  test('every call takes one unit of the directory budget', () async {
    final rig = _Rig();
    await rig.directory.own(priority: BudgetPriority.user);
    await rig.directory.peer('p1');
    await rig.directory.peers([for (var i = 0; i < 12; i++) 'q$i']);
    expect(rig.budget.taken, [
      BudgetPriority.user,
      BudgetPriority.background,
      BudgetPriority.background,
      BudgetPriority.background,
    ]);
    expect(
      rig.budget.taken.length,
      rig.keys.listCalls + rig.keys.getCalls.length,
    );
  });

  test('a lookup waiting for the budget returns deferred at once when '
      'another answer pauses it', () {
    fakeAsync((async) {
      final keys = _Keys();
      DateTime now() => _epoch.add(async.elapsed);
      final budget = SyncBudget(
        perMinute: 1,
        ownDeviceCount: () => 1,
        now: now,
      );
      final directory = DeviceDirectory(keys: keys, budget: budget, now: now);
      DeviceList? first;
      directory.peer('p2').then((l) => first = l);
      async.flushMicrotasks();
      expect(first?.readableNonEmpty, isTrue);
      final fetched = first!.fetchedAt;
      async.elapse(const Duration(minutes: 31));
      // p1 takes this minute's unit; p2 (stale) and the own list wait.
      directory.peer('p1');
      DeviceList? waitingPeer;
      DeviceList? waitingOwn;
      Map<String, DeviceList>? waitingBatch;
      directory.peer('p2').then((l) => waitingPeer = l);
      directory.own().then((l) => waitingOwn = l);
      directory.peers(['p2', 'p3']).then((m) => waitingBatch = m);
      async.flushMicrotasks();
      expect(waitingPeer, isNull);
      expect(waitingOwn, isNull);
      expect(waitingBatch, isNull);
      final callsBefore = keys.getCalls.length + keys.listCalls;
      // Another conversation's answer was RATE_LIMITED for 20 hours.
      budget.pauseUntil(now().add(const Duration(hours: 20)));
      async.flushMicrotasks();
      expect(waitingPeer?.state, ListState.deferred);
      expect(waitingPeer?.devices, hasLength(1));
      expect(waitingPeer?.fetchedAt, fetched);
      expect(waitingOwn?.state, ListState.deferred);
      expect(waitingOwn?.devices, isEmpty);
      expect(waitingBatch?['p2']?.state, ListState.deferred);
      expect(waitingBatch?['p2']?.devices, hasLength(1));
      expect(waitingBatch?['p3']?.state, ListState.deferred);
      expect(keys.getCalls.length + keys.listCalls, callsBefore);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('fetchedAt is when the request was sent, so a slow answer does not '
      'count early', () async {
    final rig = _Rig();
    final sent = rig.clock;
    final peerAnswer = Completer<pb.GetKeyDevicesResponse>();
    final ownAnswer = Completer<pb.ListMyKeyDevicesResponse>();
    rig.keys.onGet = (_) => peerAnswer.future;
    rig.keys.onList = () => ownAnswer.future;
    final peer = rig.directory.peer('p1');
    final own = rig.directory.own();
    await pumpEventQueue();
    rig.advance(const Duration(seconds: 25));
    peerAnswer.complete(_usersFor(['p1']));
    ownAnswer.complete(pb.ListMyKeyDevicesResponse(devices: [_device(1)]));
    expect((await peer).fetchedAt, sent);
    expect((await own).fetchedAt, sent);
  });

  test('a RATE_LIMITED answer that arrives after clear does not pause the '
      'next session', () async {
    final rig = _Rig();
    final peerAnswer = Completer<pb.GetKeyDevicesResponse>();
    final ownAnswer = Completer<pb.ListMyKeyDevicesResponse>();
    final batchAnswer = Completer<pb.GetKeyDevicesResponse>();
    rig.keys.onGet = (ids) =>
        ids.length > 1 ? batchAnswer.future : peerAnswer.future;
    rig.keys.onList = () => ownAnswer.future;
    final peer = rig.directory.peer('p1');
    final own = rig.directory.own();
    final batch = rig.directory.peers(['a', 'b']);
    await pumpEventQueue();
    rig.directory.clear();
    const limited = RateLimitedException(
      'slow down',
      retryAfter: Duration(hours: 5),
    );
    peerAnswer.completeError(limited);
    ownAnswer.completeError(limited);
    batchAnswer.completeError(limited);
    await peer;
    await own;
    await batch;
    expect(rig.budget.pauses, isEmpty);
    expect(rig.budget.paused, isFalse);
  });

  test(
    'a CANNOT_MESSAGE answer that arrives after clear parks nobody',
    () async {
      final rig = _Rig();
      final answer = Completer<pb.GetKeyDevicesResponse>();
      rig.keys.onGet = (_) => answer.future;
      final peer = rig.directory.peer('b');
      await pumpEventQueue();
      rig.directory.clear();
      answer.completeError(const CannotMessageException());
      await peer;
      rig.keys.onGet = (ids) async => _usersFor(ids);
      rig.keys.getCalls.clear();
      expect((await rig.directory.peers(['b']))['b']!.readableNonEmpty, isTrue);
      expect(rig.keys.getCalls, [
        ['b'],
      ]);
    },
  );

  test('an own list of 60 devices does not lower the budget below 12 a '
      'minute', () {
    fakeAsync((async) {
      final keys = _Keys()
        ..onList = () async => pb.ListMyKeyDevicesResponse(
          devices: [for (var i = 1; i <= 60; i++) _device(i)],
        );
      DateTime now() => _epoch.add(async.elapsed);
      final directory = DeviceDirectory(
        keys: keys,
        budget: SyncBudget(perMinute: 1000, ownDeviceCount: () => 1, now: now),
        now: now,
      );
      DeviceList? own;
      directory.own().then((l) => own = l);
      async.flushMicrotasks();
      expect(own?.devices, hasLength(60));
      expect(directory.ownDeviceCount, 5);
      final budget = SyncBudget(
        perMinute: kDirectoryCallsPerMinute,
        ownDeviceCount: () => directory.ownDeviceCount,
        now: now,
      );
      var served = 0;
      for (var i = 0; i < 13; i++) {
        // The limit itself: user calls (step 2b: other calls leave one
        // unit a minute to them).
        budget.take(BudgetPriority.user).then((_) => served++);
      }
      async.flushMicrotasks();
      expect(served, 12);
      async.elapse(const Duration(minutes: 1));
      expect(served, 13);
    });
  });

  test('an own list with a repeated device id is unreadable', () async {
    final rig = _Rig();
    rig.keys.onList = () async => pb.ListMyKeyDevicesResponse(
      devices: [_device(1), _device(2), _device(1)],
    );
    final own = await rig.directory.own();
    expect(own.state, ListState.unreadable);
    expect(own.devices, isEmpty);
    expect(rig.directory.ownDeviceCount, 5);
    rig.keys.onGet = (ids) async => pb.GetKeyDevicesResponse(
      users: [
        pb.UserKeyDevices(
          userId: ids.single,
          devices: [_device(3), _device(3)],
        ),
      ],
    );
    expect((await rig.directory.peer('p1')).state, ListState.unreadable);
  });

  test('a parked peer is not asked again by peer() until markUsable', () async {
    final rig = _Rig();
    var refuseB = true;
    rig.keys.onGet = (ids) async {
      if (refuseB && ids.contains('b')) throw const CannotMessageException();
      return _usersFor(ids);
    };
    expect((await rig.directory.peer('b')).state, ListState.unreadable);
    rig.keys.getCalls.clear();
    rig.advance(const Duration(minutes: 31));
    expect((await rig.directory.peer('b')).state, ListState.unreadable);
    expect(rig.keys.getCalls, isEmpty);

    refuseB = false;
    rig.directory.markUsable('b');
    final again = await rig.directory.peer('b');
    expect(rig.keys.getCalls, [
      ['b'],
    ]);
    expect(again.readableNonEmpty, isTrue);
  });

  test('a deferral outlasting the limit with an unattributed member is '
      'reported unreadable; without one it stays silent', () {
    final since = _epoch.add(const Duration(days: 1));
    bool outlasted(Duration after, {required bool unattributed}) =>
        deferralOutlasted(
          deferredSince: since,
          unattributedPresent: unattributed,
          now: since.add(after),
        );
    expect(outlasted(const Duration(minutes: 30), unattributed: true), isFalse);
    expect(
      outlasted(const Duration(minutes: 30, seconds: 1), unattributed: true),
      isTrue,
    );
    expect(outlasted(const Duration(hours: 3), unattributed: false), isFalse);
    expect(
      deferralOutlasted(
        deferredSince: null,
        unattributedPresent: true,
        now: since.add(const Duration(hours: 3)),
      ),
      isFalse,
    );
    expect(kDeferredWithUnattributedLimit, const Duration(minutes: 30));
    expect(kMaxServerRetryWait, const Duration(hours: 24));
    expect(kDeviceListReuse, const Duration(minutes: 30));
  });
}
