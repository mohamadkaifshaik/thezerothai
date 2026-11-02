import 'package:dzeroth/core/telemetry/firebase_crash_reporter.dart';

/// A [CrashlyticsPort] that remembers every argument that would leave the
/// device, as the SDK would see it. Shared by the payload tests and the TEL-9
/// end-to-end tests.
class FakeCrashlyticsPort implements CrashlyticsPort {
  /// Every argument, stringified in call order.
  final List<Object?> args = [];

  /// The method names called, in order (`setCollectionEnabled(true)` carries
  /// its value).
  final List<String> calls = [];
  final Map<String, Object> keys = {};
  final List<String> recordedTitles = [];

  @override
  Future<void> recordError(
    Object exception,
    StackTrace stack, {
    bool fatal = false,
  }) async {
    calls.add('recordError');
    recordedTitles.add(exception.toString());
    args
      ..add(exception.toString())
      ..add(stack.toString())
      ..add(fatal);
  }

  @override
  Future<void> setCustomKey(String key, Object value) async {
    calls.add('setCustomKey');
    keys[key] = value;
    args
      ..add(key)
      ..add(value);
  }

  @override
  Future<void> setCollectionEnabled(bool enabled) async =>
      calls.add('setCollectionEnabled($enabled)');

  @override
  Future<void> deleteUnsentReports() async => calls.add('deleteUnsent');

  String get everything => args.map((a) => '$a').join('\n');
}
