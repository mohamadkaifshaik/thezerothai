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

import 'package:dzeroth/core/vault/vault_cipher.dart'
    show requireVaultKeyAlias, vaultKeyAlias;
import 'package:dzeroth/core/vault/vault_owner.dart';
import 'package:dzeroth/core/vault/web_interop.dart' show settle;
import 'package:flutter/foundation.dart' show visibleForTesting;

@JS('navigator')
external JSAny? get _navigator;

extension type _Locks(JSObject _) implements JSObject {
  external JSPromise<JSAny?> request(
    String name,
    JSObject options,
    JSFunction callback,
  );
}

JSObject? _realLocks() {
  final nav = _navigator;
  if (nav == null || !nav.isA<JSObject>()) return null;
  final locks = (nav as JSObject).getProperty<JSAny?>('locks'.toJS);
  if (locks == null || !locks.isA<JSObject>()) return null;
  return locks as JSObject;
}

/// Tests only: the `navigator.locks` object (null: the browser has none).
/// The default reads the real one.
@visibleForTesting
JSObject? Function() debugLocksProvider = _realLocks;

_Locks? _locksOrNull() {
  try {
    final o = debugLocksProvider();
    if (o == null || !o.has('request')) return null;
    return _Locks(o);
  } on Object {
    return null;
  }
}

VaultOwner createPlatformVaultOwner() => WebVaultOwner();

class _Request {
  _Request(this.uid);

  /// The vault alias of the user (named uid for history; never a raw uid).
  final String uid;

  /// True when the callback ran with a lock, false when it ran with null or
  /// the request failed first.
  final Completer<bool> granted = Completer<bool>();

  bool held = false;

  /// Set synchronously by the first release(); every release() shares it.
  Future<void>? releasing;

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
  Future<bool> acquire(String uid) => acquireForAlias(vaultKeyAlias(uid));

  /// Ownership is identified by the alias, so [acquire] and this method
  /// share one lock (and one "another user" check) for the same user.
  @override
  Future<bool> acquireForAlias(String alias) {
    final uid = requireVaultKeyAlias(alias);
    final current = _current;
    if (current != null) {
      final releasing = current.releasing;
      if (releasing != null) {
        // Never share a hold that is being dropped: wait until the lock is
        // free, then ask again (a fresh request, or an earlier waiter's).
        return releasing.then((_) => acquireForAlias(uid));
      }
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
        if (request.releasing != null) {
          // Released before the grant arrived: give the lock back at once and
          // tell the caller it does not own it.
          if (!request.hold.isCompleted) request.hold.complete(null);
          if (!request.granted.isCompleted) request.granted.complete(false);
          return request.hold.future.toJS;
        }
        request.held = true;
        if (!request.granted.isCompleted) request.granted.complete(true);
        return request.hold.future.toJS;
      }).toJS;
      request.done =
          settle(locks.request(vaultLockNameForAlias(uid), options, callback))
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
    if (lost && request.held && request.releasing == null && !_lost.isClosed) {
      _lost.add(null);
    }
  }

  /// Gives the lock up. Every caller (also a second, concurrent one) completes
  /// only when the browser has freed the lock. [_current] stays set until
  /// then, marked as releasing, so an [acquire] in that window waits and then
  /// makes a fresh request instead of sharing a hold that is being dropped.
  @override
  Future<void> release() {
    final request = _current;
    if (request == null) return Future<void>.value();
    return request.releasing ??= _releaseRequest(request);
  }

  Future<void> _releaseRequest(_Request request) async {
    try {
      final granted = await request.granted.future;
      if (granted && !request.hold.isCompleted) {
        request.hold.complete(null);
      }
      // The lock is free once the outer promise has settled (also after a
      // steal or a refusal, where it already has).
      await request.done;
    } finally {
      if (identical(_current, request)) _current = null;
    }
  }
}
