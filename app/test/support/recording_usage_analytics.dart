import 'package:dzeroth/core/telemetry/analytics_event.dart';
import 'package:dzeroth/core/telemetry/telemetry_interfaces.dart';

/// A [UsageAnalytics] that remembers what reached it: the events, and the
/// screen names.
class RecordingUsageAnalytics implements UsageAnalytics {
  final List<AnalyticsEvent> events = [];
  final List<String> screens = [];

  /// `name{key=value,...}` (keys sorted) for each event, in order: the wire
  /// form the SDK adapter sends.
  List<String> get wire => [for (final e in events) _wire(e)];

  static String _wire(AnalyticsEvent e) {
    final pairs = [for (final p in e.parameters.entries) '${p.key}=${p.value}']
      ..sort();
    return '${e.name}{${pairs.join(',')}}';
  }

  @override
  Future<void> log(AnalyticsEvent event) async => events.add(event);

  @override
  Future<void> screen(String name) async => screens.add(name);

  @override
  Future<void> setCollecting(bool collecting) async {}

  @override
  Future<void> resetDevice() async {}
}
