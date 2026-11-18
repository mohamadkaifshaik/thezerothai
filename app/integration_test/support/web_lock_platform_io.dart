/// A raw lock held by the test. Web only.
class RawLockHolder {
  Future<void> release() => throw UnsupportedError('Web Locks need a browser');

  /// Completes when the browser took the lock away (a stealing request).
  Future<bool> get wasStolen =>
      throw UnsupportedError('Web Locks need a browser');
}

/// Requests [name] directly. Null when [ifAvailable] and it is held.
Future<RawLockHolder?> rawLockRequest(
  String name, {
  bool ifAvailable = false,
  bool steal = false,
}) => throw UnsupportedError('Web Locks need a browser');
