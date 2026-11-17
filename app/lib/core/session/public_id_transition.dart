import 'dart:async';

import '../feature_flags/public_ids_feature_flag.dart';
import '../storage/app_database.dart';

/// Drops what is cached with ids of the wrong kind when the server flag
/// `public_ids` appears in or disappears from `GetMe.enabled_features` for the
/// signed-in account (the rollout, or a rollback).
///
/// The kind of the ids the account last saw is persisted with the cache it
/// describes ([kPublicIdsSeenKey], an account setting): it is removed with the
/// cache on sign-out and an account switch, so it is per account and a wipe
/// runs exactly once per transition, never on a relaunch. A cache that
/// predates the marker was filled while the flag was off; a cache that was just
/// claimed holds nothing id-bearing, so its first flag set is not a transition.
///
/// What a wipe clears: see [AppDatabase.clearIdBearingCache], the callers'
/// `wipe` (in-memory repositories) and `AccountSessionReset.runIdBearing`
/// (hoisted cubits). It keeps drafts, unsent posts and every other piece of the
/// user's own content, and it does not sign anyone out.
class PublicIdTransition {
  PublicIdTransition({
    required AppDatabase database,
    required Future<void> Function() wipe,
    void Function(Object error, StackTrace stack)? onError,
  }) : _database = database,
       _wipe = wipe,
       _onError = onError;

  final AppDatabase _database;
  final Future<void> Function() _wipe;
  final void Function(Object error, StackTrace stack)? _onError;
  final StreamController<void> _wiped = StreamController<void>.broadcast(
    sync: true,
  );

  Future<void> _tail = Future<void>.value();

  /// Fires after each wipe, so holders of in-memory state (the hoisted cubits)
  /// forget too.
  Stream<void> get wiped => _wiped.stream;

  /// Called with every fresh `GetMe` flag set, before its answer is cached or
  /// shown, and the session epoch the request started under. Returns the new
  /// session epoch when it wiped (the answer must then be cached under it),
  /// else null. Never throws: a failed wipe is reported and tried again with
  /// the next `GetMe` (the marker is not advanced).
  Future<int?> onFlagSet(Set<String> enabledFeatures, int epoch) {
    final next = _tail.then((_) => _evaluate(enabledFeatures, epoch));
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<int?> _evaluate(Set<String> enabledFeatures, int epoch) async {
    if (!_database.sessionEpoch.allows(epoch)) return null;
    final enabled = enabledFeatures.contains(kFeaturePublicIds);
    final now = enabled ? '1' : '0';
    try {
      final stored = await _database.readSetting(kPublicIdsSeenKey);
      if (!_database.sessionEpoch.allows(epoch)) return null;
      // '-': freshly claimed cache. null: older than the marker, filled while
      // the flag was off ('0').
      final last = stored == '-' ? null : (stored ?? '0') == '1';
      if (last == enabled) {
        if (stored == null) await _remember(now, epoch);
        return null;
      }
      if (last == null) {
        await _remember(now, epoch);
        return null;
      }
      // Writes of requests that started before the flip carry old-kind ids.
      _database.sessionEpoch.invalidateWrites();
      await _wipe();
      final fresh = _database.sessionEpoch.value;
      await _remember(now, fresh);
      _wiped.add(null);
      return fresh;
    } on Object catch (error, stack) {
      _onError?.call(error, stack);
      return null;
    }
  }

  Future<void> _remember(String value, int epoch) =>
      _database.writeAccountSetting(kPublicIdsSeenKey, value, epoch: epoch);

  Future<void> dispose() => _wiped.close();
}
