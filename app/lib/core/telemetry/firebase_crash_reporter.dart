import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'telemetry_interfaces.dart';

/// Crashlytics behind [CrashReporter]. One of the only two files that import
/// an SDK (the other is `firebase_usage_analytics.dart`). Never constructed
/// on web or iOS (see `createTelemetry`).
///
/// TEL-5 puts the payload rules (scrubber, 200-character cap, custom keys)
/// here; until then only type and stack leave the device, because the error
/// object itself is passed to `recordError` and Crashlytics reads its type and
/// `toString`. No user identifier is ever set.
class FirebaseCrashReporter implements CrashReporter {
  FirebaseCrashReporter([FirebaseCrashlytics? crashlytics])
    : _crashlytics = crashlytics ?? FirebaseCrashlytics.instance;

  final FirebaseCrashlytics _crashlytics;

  @override
  Future<void> record(Object error, StackTrace stack, {bool fatal = false}) =>
      _crashlytics.recordError(error, stack, fatal: fatal);

  @override
  Future<void> setCollecting(bool collecting) =>
      _crashlytics.setCrashlyticsCollectionEnabled(collecting);

  @override
  Future<void> deleteUnsentReports() => _crashlytics.deleteUnsentReports();
}
