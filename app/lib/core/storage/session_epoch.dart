import 'dart:async';

/// Generation counter of the signed-in session, shared by every repository
/// that writes the local cache (`AppDatabase.sessionEpoch`).
///
/// A writer reads [value] before it starts an RPC and passes it to the
/// guarded write; the write is dropped when [end] ran in between, so an
/// in-flight request of a signed-out user can never land in the next user's
/// cache (privacy, the privacy rule).
class SessionEpoch {
  int _value = 0;

  // Never closed: an epoch lives as long as the app (or the test's database).
  final StreamController<int> _ended = StreamController<int>.broadcast();

  int get value => _value;

  /// The new [value] each time [end] runs. For a holder that must react to a
  /// sign-out or an account switch (the composer closes); a guarded write
  /// needs only [allows].
  Stream<int> get ended => _ended.stream;

  /// Invalidates every write started under an earlier [value]. Call on
  /// sign-out, before wiping the database.
  void end() {
    _value++;
    _ended.add(_value);
  }

  /// Drops every write started under an earlier [value] WITHOUT announcing a
  /// session end: the account is still signed in, so holders that close or
  /// reset on [ended] (the composer, the post sender, the plan-form memory)
  /// keep going. Used when only the cached ids became the wrong kind
  /// (`public_ids` flipped); the lazily epoch-aware repositories still see the
  /// new [value] and drop their memory.
  void invalidateWrites() => _value++;

  /// Passed by a write that intentionally bypasses the guard. Every guarded
  /// write takes a required epoch, so skipping the check is always explicit.
  static const int unguarded = -1;

  /// Whether a write that started under [epoch] is still allowed.
  bool allows(int epoch) => epoch == unguarded || epoch == _value;
}
