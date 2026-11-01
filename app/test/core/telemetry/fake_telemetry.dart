import 'dart:async';

import 'package:dzeroth/core/telemetry/analytics_event.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:dzeroth/core/telemetry/telemetry_interfaces.dart';

/// Shared call log so tests can assert the order across both adapters.
class CallLog {
  final List<String> calls = [];
  void add(String c) => calls.add(c);
  void clear() => calls.clear();
}

class FakeCrashReporter implements CrashReporter {
  FakeCrashReporter(this.log);
  final CallLog log;
  final List<Object> recorded = [];

  @override
  Future<void> record(
    Object error,
    StackTrace stack, {
    bool fatal = false,
  }) async {
    recorded.add(error);
    log.add('crash.record(${fatal ? 'fatal' : 'nonfatal'})');
  }

  @override
  Future<void> setCollecting(bool collecting) async =>
      log.add('crash.setCollecting($collecting)');

  @override
  Future<void> deleteUnsentReports() async => log.add('crash.deleteUnsent');
}

class FakeUsageAnalytics implements UsageAnalytics {
  FakeUsageAnalytics(this.calls);
  final CallLog calls;

  @override
  Future<void> log(AnalyticsEvent event) async => calls.add('usage.log');

  @override
  Future<void> screen(String name) async => calls.add('usage.screen($name)');

  @override
  Future<void> setCollecting(bool collecting) async =>
      calls.add('usage.setCollecting($collecting)');

  @override
  Future<void> resetDevice() async => calls.add('usage.reset');
}

class FakeConsent implements TelemetryConsentSource {
  final Set<String> crash = {};
  final Set<String> usage = {};
  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );

  @override
  bool crashConsented(String uid) => crash.contains(uid);

  @override
  bool usageConsented(String uid) => usage.contains(uid);

  @override
  Stream<void> get changes => _changes.stream;

  void notify() => _changes.add(null);
}
