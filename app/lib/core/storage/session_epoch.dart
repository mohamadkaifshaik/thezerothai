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
    _cache++;
    _ended.add(_value);
  }

  int _cache = 0;

  /// Generation of the id-bearing local cache (timelines, notifications,
  /// messages, profiles, follows, suggestions). Advances on every [end] and
  /// also on [invalidateWrites]. Only the stores of that cache capture it and
  /// check [allowsCache]; the account session ([value], [allows], [ended]:
  /// composer, post sender, subscriptions, drafts, unsent posts, recent
  /// searches, plan memory) is untouched by [invalidateWrites].
  int get cacheValue => _cache;

  /// Drops every id-bearing cache write started under an earlier
  /// [cacheValue], and nothing else: the account is still signed in, so
  /// in-flight user work keeps its [value]. Used when the cached ids became
  /// the wrong kind (`public_ids` flipped).
  void invalidateWrites() => _cache++;

  /// Whether a cache write that started under [cacheEpoch] ([cacheValue]) is
  /// still allowed.
  bool allowsCache(int cacheEpoch) =>
      cacheEpoch == unguarded || cacheEpoch == _cache;

  /// Passed by a write that intentionally bypasses the guard. Every guarded
  /// write takes a required epoch, so skipping the check is always explicit.
  static const int unguarded = -1;

  /// Whether a write that started under [epoch] is still allowed.
  bool allows(int epoch) => epoch == unguarded || epoch == _value;
}
