import 'dart:async';

import 'package:flutter/widgets.dart';

import 'analytics_event.dart';
import 'telemetry_controller.dart';
import 'telemetry_interfaces.dart';

/// What call sites use to report usage (ADR-0032): fire and forget,
/// never throws, never awaited. Behind it the [TelemetryController] drops
/// everything while collection is off.
class UsageReporter {
  const UsageReporter({
    required Future<void> Function(AnalyticsEvent event) log,
    required Future<void> Function(String name) screen,
  }) : _log = log,
       _screen = screen;

  /// Reports nothing: tests, web and any widget tree without a [UsageScope].
  const UsageReporter.none() : _log = _dropEvent, _screen = _dropScreen;

  /// Straight to an adapter (tests); the app uses [UsageReporter.controller].
  factory UsageReporter.analytics(UsageAnalytics analytics) =>
      UsageReporter(log: analytics.log, screen: analytics.screen);

  /// Through the one collection decision.
  factory UsageReporter.controller(TelemetryController controller) =>
      UsageReporter(log: controller.logEvent, screen: controller.logScreen);

  final Future<void> Function(AnalyticsEvent event) _log;
  final Future<void> Function(String name) _screen;

  static Future<void> _dropEvent(AnalyticsEvent event) => Future<void>.value();
  static Future<void> _dropScreen(String name) => Future<void>.value();

  /// Call on a success path only.
  void log(AnalyticsEvent event) => unawaited(_safely(() => _log(event)));

  /// [name] comes from the fixed table in `screen_names.dart`.
  void screen(String name) => unawaited(_safely(() => _screen(name)));

  static Future<void> _safely(Future<void> Function() call) async {
    try {
      await call();
    } catch (_) {
      // Telemetry never breaks the app.
    }
  }
}

/// Puts a [UsageReporter] in the widget tree. Without one, [of] answers a
/// reporter that drops everything, so widgets need no setup in tests.
class UsageScope extends InheritedWidget {
  const UsageScope({super.key, required this.reporter, required super.child});

  final UsageReporter reporter;

  static UsageReporter of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<UsageScope>()?.reporter ??
      const UsageReporter.none();

  @override
  bool updateShouldNotify(UsageScope oldWidget) =>
      reporter != oldWidget.reporter;
}
