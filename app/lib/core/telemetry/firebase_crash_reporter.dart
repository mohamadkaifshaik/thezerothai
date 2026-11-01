import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'crash_breadcrumbs.dart';
import 'crash_payload.dart';
import 'telemetry_interfaces.dart';

/// The Crashlytics calls we use, so tests can see every argument that would
/// leave the device. [FirebaseCrashlyticsPort] is the only implementation that
/// touches the SDK.
abstract interface class CrashlyticsPort {
  Future<void> recordError(Object exception, StackTrace stack, {bool fatal});
  Future<void> setCustomKey(String key, Object value);
  Future<void> log(String message);
  Future<void> setCollectionEnabled(bool enabled);
  Future<void> deleteUnsentReports();
}

class FirebaseCrashlyticsPort implements CrashlyticsPort {
  FirebaseCrashlyticsPort([FirebaseCrashlytics? crashlytics])
    : _c = crashlytics ?? FirebaseCrashlytics.instance;

  final FirebaseCrashlytics _c;

  /// `reason` and `information` stay empty: they are never built from
  /// runtime strings (ADR-0032 D6).
  @override
  Future<void> recordError(
    Object exception,
    StackTrace stack, {
    bool fatal = false,
  }) => _c.recordError(exception, stack, fatal: fatal, printDetails: false);

  @override
  Future<void> setCustomKey(String key, Object value) =>
      _c.setCustomKey(key, value);

  @override
  Future<void> log(String message) => _c.log(message);

  @override
  Future<void> setCollectionEnabled(bool enabled) =>
      _c.setCrashlyticsCollectionEnabled(enabled);

  @override
  Future<void> deleteUnsentReports() => _c.deleteUnsentReports();
}

/// The only three custom keys that exist (ADR-0032 F6). No flag list.
@immutable
class CrashKeys {
  const CrashKeys({
    required this.buildNumber,
    required this.firebaseEnv,
    required this.platform,
  });

  /// Build number and environment come from `--dart-define=BUILD_NUMBER` and
  /// `FIREBASE_ENV` (release tooling sets both); platform from the device.
  factory CrashKeys.fromEnvironment() {
    const build = String.fromEnvironment('BUILD_NUMBER');
    const env = String.fromEnvironment('FIREBASE_ENV');
    return CrashKeys(
      buildNumber: build.isEmpty ? 'unknown' : build,
      firebaseEnv: env.isEmpty ? 'dev' : env,
      platform: defaultTargetPlatform.name,
    );
  }

  final String buildNumber;
  final String firebaseEnv;
  final String platform;
}

/// Crashlytics behind [CrashReporter]. One of the only two files that import
/// an SDK (the other is `firebase_usage_analytics.dart`). Never constructed
/// on web or iOS (see `createTelemetryAdapters`).
///
/// Payload rules (F6, `crash_payload.dart`): the type and stack always; the
/// message only for allowlisted types, scrubbed and cut to 200 characters;
/// `ConnectException` as code and `ErrorReason`; exception and stack only for
/// framework errors. No user identifier is ever set.
class FirebaseCrashReporter implements CrashReporter {
  FirebaseCrashReporter({CrashlyticsPort? crashlytics, CrashKeys? keys})
    : _crashlytics = crashlytics ?? FirebaseCrashlyticsPort(),
      _keys = keys ?? CrashKeys.fromEnvironment();

  final CrashlyticsPort _crashlytics;
  final CrashKeys _keys;
  bool _keysSet = false;

  Future<void> _ensureKeys() async {
    if (_keysSet) return;
    _keysSet = true;
    await _crashlytics.setCustomKey('build_number', _keys.buildNumber);
    await _crashlytics.setCustomKey('FIREBASE_ENV', _keys.firebaseEnv);
    await _crashlytics.setCustomKey('platform', _keys.platform);
  }

  @override
  Future<void> record(
    Object error,
    StackTrace stack, {
    bool fatal = false,
  }) async {
    await _ensureKeys();
    await _crashlytics.recordError(crashPayloadFor(error), stack, fatal: fatal);
  }

  /// Logs a fixed breadcrumb (a constant from `crash_breadcrumbs.dart`).
  Future<void> breadcrumb(CrashBreadcrumb crumb) =>
      _crashlytics.log(crumb.label);

  @override
  Future<void> setCollecting(bool collecting) async {
    await _crashlytics.setCollectionEnabled(collecting);
    if (collecting) await _ensureKeys();
  }

  @override
  Future<void> deleteUnsentReports() => _crashlytics.deleteUnsentReports();
}
