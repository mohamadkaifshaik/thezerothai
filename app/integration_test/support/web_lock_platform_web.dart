import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dzeroth/core/vault/web_interop.dart' show settle;

@JS('navigator.locks')
external _RawLocks get _locks;

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
