import 'dart:async';

import '../storage/app_database.dart';
import 'telemetry_inputs.dart';

/// The two kinds of telemetry a person can consent to (ADR-0032), one switch
/// each. A third kind adds a value here and a key, not a new mechanism.
enum TelemetryKind {
  crash('crash'),
  usage('usage');

  const TelemetryKind(this.keyName);

  /// The part of the `AppSettingEntries` key that names the kind.
  final String keyName;
}

/// What the person chose for one kind: [unasked] until the card or a Settings
/// switch records an answer. Only [on] collects.
enum ConsentChoice {
  unasked,
  on,
  off;

  static ConsentChoice parse(String? raw) => switch (raw) {
    'on' => ConsentChoice.on,
    'off' => ConsentChoice.off,
    _ => ConsentChoice.unasked,
  };
}

/// Where consent is remembered, per account and per kind (ADR-0032 F1, A:
/// opt-in for both), and the [TelemetryConsentSource] the controller reads.
///
/// A copy of `DatabasePushOptInStore`: `AppSettingEntries` keys
/// `telemetry_consent:crash:<uid>` and `telemetry_consent:usage:<uid>` with the
/// values `on` and `off` (no key is "unasked"). Two accounts on one device do
/// not share an answer. Sign-out keeps the keys, like every device setting;
/// [forget] drops them when the account is deleted.
///
/// The controller decides synchronously, so answers are cached in memory per
/// uid: [load] reads a uid's two keys (call it for the restored uid before the
/// first decision, and on every auth change), [setAll] updates the cache and
/// tells [changes] listeners FIRST, then saves, so a switch turned off stops
/// collection at once. A uid that is not loaded reads as unasked, so an
/// unloaded account never collects. 0 RPCs.
class TelemetryConsentStore implements TelemetryConsentSource {
  TelemetryConsentStore(this._database);

  final AppDatabase _database;
  final Map<String, Map<TelemetryKind, ConsentChoice>> _cache = {};
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );

  /// The `AppSettingEntries` key of [kind] for [uid].
  static String key(TelemetryKind kind, String uid) =>
      'telemetry_consent:${kind.keyName}:$uid';

  /// Reads both answers of [uid] into the cache and announces the change.
  Future<void> load(String uid) async {
    final read = <TelemetryKind, ConsentChoice>{};
    for (final kind in TelemetryKind.values) {
      read[kind] = ConsentChoice.parse(
        await _database.readSetting(key(kind, uid)),
      );
    }
    _cache[uid] = read;
    _changes.add(null);
  }

  /// The cached answer of [uid]; unasked until [load] ran for it.
  ConsentChoice choice(String uid, TelemetryKind kind) =>
      _cache[uid]?[kind] ?? ConsentChoice.unasked;

  /// Whether [load] ran for [uid] (the card stays hidden until then).
  bool isLoaded(String uid) => _cache.containsKey(uid);

  /// Records answers for [uid] in one step (one change event, so the card's
  /// "Save" is a single decision). Cache first, then disk; a failing disk
  /// surfaces as the returned future's error and the answer still lasts for
  /// the session.
  Future<void> setAll(String uid, Map<TelemetryKind, ConsentChoice> answers) {
    final cached = _cache.putIfAbsent(uid, () => {});
    answers.forEach((kind, choice) => cached[kind] = choice);
    _changes.add(null);
    return _persist(uid, answers);
  }

  Future<void> set(String uid, TelemetryKind kind, ConsentChoice choice) =>
      setAll(uid, {kind: choice});

  Future<void> _persist(
    String uid,
    Map<TelemetryKind, ConsentChoice> answers,
  ) async {
    for (final entry in answers.entries) {
      final k = key(entry.key, uid);
      switch (entry.value) {
        case ConsentChoice.unasked:
          await _database.deleteSetting(k);
        case ConsentChoice.on:
          await _database.writeSetting(k, 'on');
        case ConsentChoice.off:
          await _database.writeSetting(k, 'off');
      }
    }
  }

  /// Drops both answers of [uid], on disk and in memory. Called when that
  /// account is deleted (the uid must not outlive the account); a plain
  /// sign-out keeps them.
  Future<void> forget(String uid) async {
    _cache.remove(uid);
    _changes.add(null);
    for (final kind in TelemetryKind.values) {
      await _database.deleteSetting(key(kind, uid));
    }
  }

  @override
  bool crashConsented(String uid) =>
      choice(uid, TelemetryKind.crash) == ConsentChoice.on;

  @override
  bool usageConsented(String uid) =>
      choice(uid, TelemetryKind.usage) == ConsentChoice.on;

  @override
  Stream<void> get changes => _changes.stream;

  Future<void> dispose() => _changes.close();
}
