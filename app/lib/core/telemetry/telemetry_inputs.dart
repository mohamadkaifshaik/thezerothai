import '../storage/app_database.dart';

/// The two server flags of ADR-0032 F7 as exposed in `GetMe.enabled_features`
/// (client-only flags; a missing name means off). Never hardcode the strings
/// elsewhere.
const kFeatureCrashReporting = 'crash_reporting';
const kFeatureAnalytics = 'analytics';

/// What the person chose on this device, per account and per kind. TEL-7
/// implements it (`TelemetryConsentStore` over `AppSettingEntries`). The
/// controller only reads it, and re-reads when [changes] fires.
abstract interface class TelemetryConsentSource {
  /// True only for a stored "on" for [uid]; unasked and off are both false.
  bool crashConsented(String uid);
  bool usageConsented(String uid);

  /// Fires after any consent change (a Settings switch, "Save", "Not now").
  Stream<void> get changes;
}

/// No consent for anyone. TEL-4's stand-in until TEL-7, so nothing collects.
class NoTelemetryConsent implements TelemetryConsentSource {
  const NoTelemetryConsent();

  @override
  bool crashConsented(String uid) => false;

  @override
  bool usageConsented(String uid) => false;

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

/// The flag half of the last decision, per uid, so bootstrap can apply the
/// right state before the first `GetMe` (the native SDK keeps its own
/// collection state across launches, A6, so it can be stale).
class TelemetryFlags {
  const TelemetryFlags({this.crash = false, this.analytics = false});

  factory TelemetryFlags.fromFeatures(Set<String> enabledFeatures) =>
      TelemetryFlags(
        crash: enabledFeatures.contains(kFeatureCrashReporting),
        analytics: enabledFeatures.contains(kFeatureAnalytics),
      );

  static const off = TelemetryFlags();

  final bool crash;
  final bool analytics;

  @override
  bool operator ==(Object other) =>
      other is TelemetryFlags &&
      other.crash == crash &&
      other.analytics == analytics;

  @override
  int get hashCode => Object.hash(crash, analytics);
}

abstract interface class TelemetryFlagMemory {
  Future<TelemetryFlags?> read(String uid);
  Future<void> write(String uid, TelemetryFlags flags);

  /// Account deletion (TEL-8): the uid must not outlive the account.
  Future<void> forget(String uid);
}

/// In-memory memory, for tests.
class InMemoryTelemetryFlagMemory implements TelemetryFlagMemory {
  final Map<String, TelemetryFlags> _byUid = {};

  @override
  Future<TelemetryFlags?> read(String uid) async => _byUid[uid];

  @override
  Future<void> write(String uid, TelemetryFlags flags) async =>
      _byUid[uid] = flags;

  @override
  Future<void> forget(String uid) async => _byUid.remove(uid);
}

/// Keeps the flags in `AppSettingEntries` under a per-uid key. 0 RPCs.
class DatabaseTelemetryFlagMemory implements TelemetryFlagMemory {
  DatabaseTelemetryFlagMemory(this._database);

  final AppDatabase _database;

  static String key(String uid) => 'telemetry_flags:$uid';

  @override
  Future<TelemetryFlags?> read(String uid) async {
    final raw = await _database.readSetting(key(uid));
    if (raw == null) return null;
    final parts = raw.split(',');
    return TelemetryFlags(
      crash: parts.contains('crash'),
      analytics: parts.contains('analytics'),
    );
  }

  @override
  Future<void> write(String uid, TelemetryFlags flags) =>
      _database.writeSetting(
        key(uid),
        [if (flags.crash) 'crash', if (flags.analytics) 'analytics'].join(','),
      );

  @override
  Future<void> forget(String uid) => _database.deleteSetting(key(uid));
}

/// The uid that last signed in on this device (F11 / TEL-8), so the controller
/// can tell "a different account" from "the same account again" across
/// launches. Device-level, one value.
abstract interface class TelemetryLastUidStore {
  Future<String?> read();
  Future<void> write(String uid);

  /// Drops the record when it still names [uid] (the account was deleted).
  Future<void> forget(String uid);
}

/// In-memory store, for tests.
class InMemoryTelemetryLastUidStore implements TelemetryLastUidStore {
  InMemoryTelemetryLastUidStore([this.value]);

  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String uid) async => value = uid;

  @override
  Future<void> forget(String uid) async {
    if (value == uid) value = null;
  }
}

/// Keeps the last uid in `AppSettingEntries` under `telemetry_last_uid`. 0 RPCs.
class DatabaseTelemetryLastUidStore implements TelemetryLastUidStore {
  DatabaseTelemetryLastUidStore(this._database);

  final AppDatabase _database;

  static const key = 'telemetry_last_uid';

  @override
  Future<String?> read() => _database.readSetting(key);

  @override
  Future<void> write(String uid) => _database.writeSetting(key, uid);

  @override
  Future<void> forget(String uid) async {
    if (await _database.readSetting(key) == uid) {
      await _database.deleteSetting(key);
    }
  }
}
