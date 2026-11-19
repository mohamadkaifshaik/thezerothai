import 'dart:async';
import 'dart:typed_data';

import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/crypto/crypto_types.dart';
import 'package:dzeroth/core/crypto/guarded_crypto_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_crypto_engine.dart';

/// An inner engine whose `wireEpoch` waits on a completer the test controls.
class _Scripted extends FakeCryptoEngine {
  final pending = <Completer<int>>[];
  int calls = 0;

  @override
  Future<int> wireEpoch(Uint8List wire) {
    calls++;
    final c = Completer<int>();
    pending.add(c);
    return c.future;
  }
}

/// A scripted engine that reports its health like the web engine.
class _Worker extends _Scripted implements EngineHealth {
  @override
  bool failed = false;
  int closes = 0;

  @override
  void close() {
    closes++;
    failed = true;
    // A closed worker fails what it still holds, as the web engine does.
    for (final c in pending) {
      if (!c.isCompleted) {
        c.completeError(const MlsException(MlsErrorCode.internal, 'closed'));
      }
    }
  }
}

final _wire = Uint8List(4);

/// Runs [body] and returns the error it threw (or fails the test).
Future<MlsException> _fails(Future<Object?> f) async {
  try {
    await f;
  } on MlsException catch (e) {
    return e;
  }
  throw TestFailure('expected an MlsException');
}

void main() {
  test('a call that never answers fails with deadline at exactly 30 s', () {
    fakeAsync((async) {
      final inner = _Scripted();
      final guarded = GuardedCryptoEngine(create: () => inner);
      MlsException? error;
      guarded
          .wireEpoch(_wire)
          .then<void>(
            (_) {},
            onError: (Object e) {
              error = e as MlsException;
            },
          );
      async.elapse(const Duration(seconds: 29, milliseconds: 999));
      expect(error, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(error?.code, MlsErrorCode.deadline);
      expect(error?.message, 'engine call timed out');
    });
  });

  test('a result arriving at 31 s is dropped', () {
    fakeAsync((async) {
      final inner = _Scripted();
      final guarded = GuardedCryptoEngine(create: () => inner);
      final errors = <Object>[];
      var completed = 0;
      guarded
          .wireEpoch(_wire)
          .then<void>((_) => completed++, onError: errors.add);
      async.elapse(const Duration(seconds: 30));
      expect(errors, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      inner.pending.single.complete(7);
      async.flushMicrotasks();
      expect(errors, hasLength(1));
      expect(completed, 0);
      // Nothing reached the zone as an uncaught error either (fakeAsync
      // would rethrow it on flush).
      inner.pending.length;
    });
  });

  test('a late error of a timed-out call reaches no listener', () {
    fakeAsync((async) {
      final inner = _Scripted();
      final guarded = GuardedCryptoEngine(create: () => inner);
      guarded.wireEpoch(_wire).then<void>((_) {}, onError: (Object _) {});
      async.elapse(const Duration(seconds: 30));
      inner.pending.single.completeError(
        const MlsException(MlsErrorCode.internal, 'late'),
      );
      async.flushMicrotasks();
    });
  });

  test('a failed worker is closed and replaced once, the triggering call '
      'rethrows', () {
    fakeAsync((async) {
      final workers = <_Worker>[];
      final guarded = GuardedCryptoEngine(
        create: () {
          final w = _Worker();
          workers.add(w);
          return w;
        },
      );
      Object? error;
      guarded
          .wireEpoch(_wire)
          .then<void>(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          );
      async.elapse(const Duration(seconds: 30));
      expect((error as MlsException).code, MlsErrorCode.deadline);
      expect(workers, hasLength(2));
      expect(workers.first.closes, 1);
      expect(workers.last.closes, 0);
      expect(guarded.unavailable.value, isFalse);
      // The replacement serves the next call; the old call was not re-run.
      expect(workers.first.calls, 1);
      int? epoch;
      guarded.wireEpoch(_wire).then((v) => epoch = v);
      async.flushMicrotasks();
      workers.last.pending.single.complete(5);
      async.flushMicrotasks();
      expect(epoch, 5);
      expect(workers.last.calls, 1);
    });
  });

  test('a second failure sets unavailable and later calls fail at once '
      'without reaching an engine', () {
    fakeAsync((async) {
      final workers = <_Worker>[];
      final guarded = GuardedCryptoEngine(
        create: () {
          final w = _Worker();
          workers.add(w);
          return w;
        },
      );
      final errors = <MlsException>[];
      void call() => guarded
          .wireEpoch(_wire)
          .then<void>(
            (_) {},
            onError: (Object e) => errors.add(e as MlsException),
          );
      call();
      async.elapse(const Duration(seconds: 30));
      call();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(errors.map((e) => e.code), [
        MlsErrorCode.deadline,
        MlsErrorCode.deadline,
      ]);
      expect(guarded.unavailable.value, isTrue);
      expect(workers, hasLength(2));
      final callsBefore = workers.map((w) => w.calls).toList();
      call();
      async.flushMicrotasks();
      expect(errors.last.code, MlsErrorCode.unavailable);
      expect(workers, hasLength(2));
      expect(workers.map((w) => w.calls).toList(), callsBefore);
    });
  });

  test('three calls in flight on a worker that dies count as one failure', () {
    fakeAsync((async) {
      final workers = <_Worker>[];
      final guarded = GuardedCryptoEngine(
        create: () {
          final w = _Worker();
          workers.add(w);
          return w;
        },
      );
      final errors = <MlsException>[];
      for (var i = 0; i < 3; i++) {
        guarded
            .wireEpoch(_wire)
            .then<void>(
              (_) {},
              onError: (Object e) => errors.add(e as MlsException),
            );
      }
      async.flushMicrotasks();
      expect(workers.single.pending, hasLength(3));
      // The worker dies: every pending call fails with its own error.
      workers.single
        ..failed = true
        ..pending.first.completeError(
          const MlsException(MlsErrorCode.internal, 'worker failed'),
        )
        ..pending[1].completeError(
          const MlsException(MlsErrorCode.internal, 'worker failed'),
        )
        ..pending[2].completeError(
          const MlsException(MlsErrorCode.internal, 'worker failed'),
        );
      async.flushMicrotasks();
      expect(errors, hasLength(3));
      expect(errors.every((e) => e.code == MlsErrorCode.internal), isTrue);
      expect(workers, hasLength(2));
      expect(guarded.unavailable.value, isFalse);
    });
  });

  test('timeouts of calls in flight on a replaced worker count nothing', () {
    fakeAsync((async) {
      final workers = <_Worker>[];
      final guarded = GuardedCryptoEngine(
        create: () {
          final w = _Worker();
          workers.add(w);
          return w;
        },
      );
      final errors = <MlsException>[];
      for (var i = 0; i < 2; i++) {
        guarded
            .wireEpoch(_wire)
            .then<void>(
              (_) {},
              onError: (Object e) => errors.add(e as MlsException),
            );
      }
      async.elapse(const Duration(seconds: 30));
      // The first fails with deadline and closes the worker; the second fails
      // with the closed worker's own error (or its own deadline) and counts
      // nothing.
      expect(errors, hasLength(2));
      expect(errors.first.code, MlsErrorCode.deadline);
      expect(workers, hasLength(2));
      expect(guarded.unavailable.value, isFalse);
    });
  });

  test('parse(deadline) and parse(unavailable) are internal', () {
    expect(MlsErrorCode.parse('deadline'), MlsErrorCode.internal);
    expect(MlsErrorCode.parse('unavailable'), MlsErrorCode.internal);
    expect(MlsErrorCode.parse('own_leaf'), MlsErrorCode.ownLeaf);
    expect(MlsErrorCode.deadline.wire, 'deadline');
    expect(MlsErrorCode.unavailable.wire, 'unavailable');
  });

  test('onAppResumed allows one more replacement', () {
    fakeAsync((async) {
      final workers = <_Worker>[];
      final guarded = GuardedCryptoEngine(
        create: () {
          final w = _Worker();
          workers.add(w);
          return w;
        },
      );
      void call() =>
          guarded.wireEpoch(_wire).then<void>((_) {}, onError: (Object _) {});
      call();
      async.elapse(const Duration(seconds: 30));
      call();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(guarded.unavailable.value, isTrue);
      expect(workers, hasLength(2));

      guarded.onAppResumed();
      expect(guarded.unavailable.value, isFalse);
      call();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      // The engine of the second failure was closed and not rebuilt, so the
      // first call after resume creates one (3) and its failure, the first
      // since resume, replaces it once (4).
      expect(workers, hasLength(4));
      expect(guarded.unavailable.value, isFalse);
      call();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(guarded.unavailable.value, isTrue);
    });
  });

  test('an engine without EngineHealth is never replaced on a timeout', () {
    fakeAsync((async) {
      var created = 0;
      final inner = _Scripted();
      final guarded = GuardedCryptoEngine(
        create: () {
          created++;
          return inner;
        },
      );
      final errors = <MlsException>[];
      for (var i = 0; i < 3; i++) {
        guarded
            .wireEpoch(_wire)
            .then<void>(
              (_) {},
              onError: (Object e) => errors.add(e as MlsException),
            );
        async.elapse(const Duration(seconds: 30));
      }
      expect(errors.map((e) => e.code), everyElement(MlsErrorCode.deadline));
      expect(errors, hasLength(3));
      expect(created, 1);
      expect(guarded.unavailable.value, isFalse);
    });
  });

  test('nothing is created before the first call', () {
    var created = 0;
    final guarded = GuardedCryptoEngine(
      create: () {
        created++;
        return FakeCryptoEngine();
      },
    );
    guarded.onAppResumed();
    expect(created, 0);
    expect(guarded.unavailable.value, isFalse);
  });

  test('create throwing counts as a failure', () async {
    var created = 0;
    final guarded = GuardedCryptoEngine(
      create: () {
        created++;
        throw StateError('no worker');
      },
    );
    final first = await _fails(guarded.wireEpoch(_wire));
    expect(first.code, MlsErrorCode.internal);
    expect(guarded.unavailable.value, isFalse);
    await _fails(guarded.wireEpoch(_wire));
    expect(guarded.unavailable.value, isTrue);
    final third = await _fails(guarded.wireEpoch(_wire));
    expect(third.code, MlsErrorCode.unavailable);
    expect(created, 2);
  });

  test(
    'close closes the inner engine and later calls are unavailable',
    () async {
      final worker = _Worker();
      final guarded = GuardedCryptoEngine(create: () => worker);
      final r = await guarded.randomBytes(8);
      expect(r, hasLength(8));
      guarded.close();
      expect(worker.closes, 1);
      final e = await _fails(guarded.randomBytes(8));
      expect(e.code, MlsErrorCode.unavailable);
    },
  );

  test('every method forwards to the inner engine', () async {
    final guarded = GuardedCryptoEngine(create: FakeCryptoEngine.new);
    final id = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final created = await guarded.createDevice(id);
    final key = await guarded.randomBytes(32);
    final aad = Uint8List.fromList([1, 2]);
    final sealed = await guarded.seal(key, aad, Uint8List.fromList([9]));
    expect(await guarded.open(key, aad, sealed), [9]);
    final packages = await guarded.generateKeyPackages(
      created.deviceState,
      count: 1,
      lastResort: false,
    );
    final info = await guarded.inspectKeyPackage(packages.keyPackages.single);
    expect(info.deviceId, id);
    final group = await guarded.createGroup(
      created.deviceState,
      Uint8List.fromList(List.generate(16, (i) => 100 + i)),
    );
    expect((await guarded.describe(group)).epoch, 0);
  });
}
