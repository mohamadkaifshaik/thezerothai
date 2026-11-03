import 'firebase_crash_reporter.dart';
import 'firebase_usage_analytics.dart';
import 'telemetry_interfaces.dart';
import 'telemetry_platforms.dart';

/// The two adapters the app runs with.
class TelemetryAdapters {
  const TelemetryAdapters({required this.crash, required this.analytics});

  /// Both `Noop`: web, iOS (until it ships) and tests. No SDK is touched.
  const TelemetryAdapters.noop()
    : crash = const NoopCrashReporter(),
      analytics = const NoopUsageAnalytics();

  final CrashReporter crash;
  final UsageAnalytics analytics;
}

/// Platform selection. Call after `Firebase.initializeApp` (the SDK instances
/// need the default app); on an unsupported platform it never touches them.
TelemetryAdapters createTelemetryAdapters({bool? supported}) {
  if (!(supported ?? TelemetryPlatforms.current)) {
    return const TelemetryAdapters.noop();
  }
  return TelemetryAdapters(
    crash: FirebaseCrashReporter(),
    analytics: FirebaseUsageAnalytics(),
  );
}
