import 'analytics_event.dart';

/// Crash and non-fatal reporting behind the seam (ADR-0032). Only
/// `firebase_crash_reporter.dart` talks to the SDK; a web or other-vendor
/// reporter replaces an implementation with no caller change.
///
/// Callers never use this directly: they go through `TelemetryController`,
/// which only forwards while collecting is on.
abstract interface class CrashReporter {
  /// Records [error]. [fatal] is true for an error that escaped every handler.
  /// The payload rules (type and stack only, scrubbed message) live in the
  /// implementation, not in callers.
  Future<void> record(Object error, StackTrace stack, {bool fatal = false});

  /// Turns SDK collection on or off at runtime.
  Future<void> setCollecting(bool collecting);

  /// Drops reports the SDK has stored but not sent. Called on every "off".
  Future<void> deleteUnsentReports();
}

/// Usage analytics behind the seam (ADR-0032). Same rules as
/// [CrashReporter].
abstract interface class UsageAnalytics {
  Future<void> log(AnalyticsEvent event);

  /// [name] comes from a fixed table, never a URL.
  Future<void> screen(String name);

  /// Turns SDK collection on or off at runtime.
  Future<void> setCollecting(bool collecting);

  /// Resets the device's app-instance id and clears local analytics data
  /// (F11: a different account on this device, or in-app deletion).
  Future<void> resetDevice();
}

/// Does nothing and touches no SDK: web, iOS (until it ships) and tests.
class NoopCrashReporter implements CrashReporter {
  const NoopCrashReporter();

  @override
  Future<void> record(Object error, StackTrace stack, {bool fatal = false}) =>
      Future<void>.value();

  @override
  Future<void> setCollecting(bool collecting) => Future<void>.value();

  @override
  Future<void> deleteUnsentReports() => Future<void>.value();
}

/// See [NoopCrashReporter].
class NoopUsageAnalytics implements UsageAnalytics {
  const NoopUsageAnalytics();

  @override
  Future<void> log(AnalyticsEvent event) => Future<void>.value();

  @override
  Future<void> screen(String name) => Future<void>.value();

  @override
  Future<void> setCollecting(bool collecting) => Future<void>.value();

  @override
  Future<void> resetDevice() => Future<void>.value();
}
