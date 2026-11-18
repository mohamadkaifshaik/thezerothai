// Single-tab ownership of the vault on the web, through the Web Locks API.
//
// How a lock is held: `navigator.locks.request(name, {mode: 'exclusive',
// ifAvailable: true}, callback)` calls `callback(lock)` when the lock is
// granted (`lock` is null when another context holds it, and the request then
// ends). The lock stays held for as long as the Promise the callback returned
// is pending. The callback returns a Promise made from a Dart Completer, and
// release() completes it. The browser frees the lock itself when the tab
// closes or crashes.
//
// acquire() completes from inside the callback: the promise request() returns
// only settles when the lock is released, so it is never awaited for the
// answer. If that outer promise rejects after the grant (a context that
// requested the same name with `steal: true` makes it reject with
// AbortError), ownership is gone and `lost` emits. This code never steals.
//
// Web only (dart:js_interop); reached through the conditional import in
// vault_owner.dart. Nothing here logs.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/web_interop.dart' show settle;

@JS('navigator')
external JSAny? get _navigator;

extension type _Locks(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    String name,
    JSObject options,
    JSFunction callback,
  );
}

_Locks? _locksOrNull() {
  try {
    final nav = _navigator;
    if (nav == null || !nav.isA<JSObject>()) return null;
    final locks = (nav as JSObject).getProperty<JSAny?>('locks'.toJS);
    if (locks == null || !locks.isA<JSObject>()) return null;
    final o = locks as JSObject;
    if (!o.has('request')) return null;
    return _Locks(o);
  } on Object {
    return null;
  }
}

VaultOwner createPlatformVaultOwner() => WebVaultOwner();

class _Request {
  _Request(this.uid);

  final String uid;

  /// True when the callback ran with a lock, false when it ran with null or
  /// the request failed first.
  final Completer<bool> granted = Completer<bool>();

  bool held = false;

  /// Completing it resolves the promise the callback returned: the release.
  final Completer<JSAny?> hold = Completer<JSAny?>();

  /// The settled outer request promise (never throws).
  Future<void> done = Future<void>.value();
}

class WebVaultOwner implements VaultOwner {
  final StreamController<void> _lost = StreamController<void>.broadcast();
  _Request? _current;

  @override
  bool get supported => _locksOrNull() != null;

  @override
  Stream<void> get lost => _lost.stream;

  @override
  Future<bool> acquire(String uid) {
    final current = _current;
    if (current != null) {
      if (current.uid != uid) {
        throw StateError('the vault is owned for another user: release first');
      }
      // Never a second request: our own hold would refuse it.
      return current.granted.future;
    }
    final locks = _locksOrNull();
    if (locks == null) return Future<bool>.value(false);
    final request = _Request(uid);
    _current = request;
    try {
      final options = JSObject()
        ..setProperty('mode'.toJS, 'exclusive'.toJS)
        ..setProperty('ifAvailable'.toJS, true.toJS);
      final callback = ((JSAny? lock) {
        if (lock == null) {
          // Cleared here, before acquire's caller continues.
          _end(request, lost: false);
          return null;
        }
        request.held = true;
        if (!request.granted.isCompleted) request.granted.complete(true);
        return request.hold.future.toJS;
      }).toJS;
      request.done =
          settle(locks.request(vaultLockName(uid), options, callback))
              .then<void>(
                (_) => _end(request, lost: false),
                onError: (Object _) => _end(request, lost: true),
              );
    } on Object {
      _end(request, lost: false);
    }
    return request.granted.future;
  }

  void _end(_Request request, {required bool lost}) {
    // Failed or refused before a grant: acquire answers false.
    if (!request.granted.isCompleted) request.granted.complete(false);
    if (!request.hold.isCompleted) request.hold.complete(null);
    if (!identical(_current, request)) return;
    _current = null;
    // A rejection of a request that was granted means the lock was taken.
    if (lost && request.held && !_lost.isClosed) _lost.add(null);
  }

  @override
  Future<void> release() async {
    final request = _current;
    if (request == null) return;
    final granted = await request.granted.future;
    if (!identical(_current, request)) return;
    _current = null;
    if (!granted) return;
    request.hold.complete(null);
    // The lock is free once the outer promise has settled.
    await request.done;
  }
}
