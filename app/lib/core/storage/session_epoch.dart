/// Generation counter of the signed-in session, shared by every repository
/// that writes the local cache (`AppDatabase.sessionEpoch`).
///
/// A writer reads [value] before it starts an RPC and passes it to the
/// guarded write; the write is dropped when [end] ran in between, so an
/// in-flight request of a signed-out user can never land in the next user's
/// cache (privacy, CLAUDE.md rule 10).
class SessionEpoch {
  int _value = 0;

  int get value => _value;

  /// Invalidates every write started under an earlier [value]. Call on
  /// sign-out, before wiping the database.
  void end() => _value++;

  /// Whether a write that started under [epoch] is still allowed. A null
  /// [epoch] is an unguarded write.
  bool allows(int? epoch) => epoch == null || epoch == _value;
}
