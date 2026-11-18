import 'dart:async';

/// An async mutex per string key: calls with one key run one at a time in the
/// order they were made (FIFO); calls with different keys never wait for each
/// other.
///
/// A body that throws (or throws synchronously) releases its key; the error
/// goes to that caller only and the next waiter still runs. A key with nobody
/// running or waiting leaves no entry behind, so the map does not grow.
///
/// NOT re-entrant. Calling [run] with a key from inside the body of a [run]
/// on the same key would wait for itself forever. In debug builds (asserts
/// enabled) that is detected through a zone value and the returned future
/// fails at once with a [StateError]. Release builds do not check: do not
/// nest runs on one key. The check follows the async chain of the body; work
/// that outlives the body (a timer, a stream listener) is no longer counted as
/// holding the key.
///
/// Uses no timers.
class KeyedMutex {
  final Map<String, Future<void>> _tails = {};
  final Object _zoneKey = Object();

  /// Runs [body] once every earlier call with [key] has finished and returns
  /// its result.
  Future<T> run<T>(String key, Future<T> Function() body) {
    var debug = false;
    assert(() {
      debug = true;
      return true;
    }());
    if (debug && _heldHere(key)) {
      return Future<T>.error(
        StateError(
          'KeyedMutex.run("$key") called from inside a run on the same key: '
          'it would never finish (the mutex is not re-entrant)',
        ),
      );
    }
    final previous = _tails[key];
    final gate = Completer<void>();
    _tails[key] = gate.future;
    return _run<T>(key, body, previous, gate);
  }

  bool _heldHere(String key) {
    final holds = Zone.current[_zoneKey] as List<_Hold>?;
    if (holds == null) return false;
    return holds.any((h) => h.active && h.key == key);
  }

  Future<T> _run<T>(
    String key,
    Future<T> Function() body,
    Future<void>? previous,
    Completer<void> gate,
  ) async {
    final hold = _Hold(key);
    try {
      // Tails are completed normally (never with an error), so this never
      // throws.
      if (previous != null) await previous;
      final holds = <_Hold>[
        ...(Zone.current[_zoneKey] as List<_Hold>? ?? const <_Hold>[]),
        hold,
      ];
      return await Zone.current
          .fork(zoneValues: {_zoneKey: holds})
          .run<Future<T>>(body);
    } finally {
      hold.active = false;
      if (identical(_tails[key], gate.future)) _tails.remove(key);
      gate.complete();
    }
  }

  /// The number of keys with a running or waiting call. For tests.
  int get debugKeyCount => _tails.length;
}

class _Hold {
  _Hold(this.key);

  final String key;
  bool active = true;
}
