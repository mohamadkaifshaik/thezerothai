import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dzeroth/core/vault/vault_owner_web.dart'
    show debugLocksProvider;
import 'package:dzeroth/core/vault/web_interop.dart' show settle;

@JS('navigator.locks')
external _RawLocks get _locks;

@JS('addEventListener')
external void _addEventListener(String type, JSFunction listener);

@JS('removeEventListener')
external void _removeEventListener(String type, JSFunction listener);

/// What the owner sees as `navigator.locks`: `real`, `missing`, `rejecting`
/// (request() returns a promise that rejects before any grant, like a
/// SecurityError) or `throwing` (request() throws at once).
void useLocks(String mode) {
  switch (mode) {
    case 'real':
      debugLocksProvider = () => _locks;
    case 'missing':
      debugLocksProvider = () => null;
    case 'rejecting':
      debugLocksProvider = () => JSObject()
        ..setProperty(
          'request'.toJS,
          ((JSAny? n, JSAny? o, JSAny? cb) => Future<JSAny?>.error(
            StateError('SecurityError'),
          ).toJS).toJS,
        );
    case 'throwing':
      JSAny? thrower(JSAny? n, JSAny? o, JSAny? cb) =>
          throw StateError('SecurityError');
      debugLocksProvider = () =>
          JSObject()..setProperty('request'.toJS, thrower.toJS);
    default:
      throw ArgumentError.value(mode, 'mode');
  }
}

/// Runs [body] and returns how many `unhandledrejection` events the page saw
/// during it and a short wait after.
Future<int> unhandledRejectionsDuring(Future<void> Function() body) async {
  var count = 0;
  final listener = ((JSAny? _) => count++).toJS;
  _addEventListener('unhandledrejection', listener);
  try {
    await body();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  } finally {
    _removeEventListener('unhandledrejection', listener);
  }
  return count;
}

extension type _RawLocks(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    String name,
    JSObject options,
    JSFunction callback,
  );
}

/// A raw lock held by the test (the "other tab").
class RawLockHolder {
  RawLockHolder._();

  final Completer<JSAny?> _hold = Completer<JSAny?>();
  final Completer<bool> _stolen = Completer<bool>();
  late Future<void> _done;

  /// Resolves the held promise and waits until the lock is free.
  Future<void> release() async {
    if (!_hold.isCompleted) _hold.complete(null);
    await _done;
  }

  /// Completes true when the browser took the lock away from this holder.
  Future<bool> get wasStolen => _stolen.future;
}

/// Requests [name] directly. Null when [ifAvailable] and it is held. Returns
/// once the lock is granted (or refused), not when it is released.
Future<RawLockHolder?> rawLockRequest(
  String name, {
  bool ifAvailable = false,
  bool steal = false,
}) {
  final holder = RawLockHolder._();
  final granted = Completer<RawLockHolder?>();
  final options = JSObject()..setProperty('mode'.toJS, 'exclusive'.toJS);
  if (ifAvailable) options.setProperty('ifAvailable'.toJS, true.toJS);
  if (steal) options.setProperty('steal'.toJS, true.toJS);
  final callback = ((JSAny? lock) {
    if (lock == null) {
      granted.complete(null);
      return null;
    }
    granted.complete(holder);
    return holder._hold.future.toJS;
  }).toJS;
  holder._done = settle(_locks.request(name, options, callback)).then<void>(
    (_) {
      if (!holder._stolen.isCompleted) holder._stolen.complete(false);
    },
    onError: (Object _) {
      if (!holder._stolen.isCompleted) holder._stolen.complete(true);
      if (!granted.isCompleted) granted.complete(null);
    },
  );
  return granted.future;
}
