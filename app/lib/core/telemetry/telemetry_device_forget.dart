import 'package:flutter/widgets.dart';

import 'telemetry_consent_store.dart';
import 'telemetry_controller.dart';

/// What the in-app Delete account flow calls once the account is gone
/// (ADR-0032 F11, TEL-8): the uid's consent keys, the crash reports not yet
/// sent and the analytics ID all go from this device. Never throws; a failing
/// step never keeps the others from running. 0 RPCs.
class TelemetryDeviceForget {
  const TelemetryDeviceForget(this._forget);

  /// Forgets nothing: tests, web and any tree without a [TelemetryForgetScope].
  const TelemetryDeviceForget.none() : _forget = _nothing;

  /// Consent keys through the store, the rest through the controller's queue.
  factory TelemetryDeviceForget.of({
    required TelemetryConsentStore consent,
    required TelemetryController controller,
  }) => TelemetryDeviceForget((uid) async {
    try {
      await consent.forget(uid);
    } catch (_) {
      // The device reset below must still run.
    }
    await controller.forgetDevice(uid);
  });

  final Future<void> Function(String uid) _forget;

  static Future<void> _nothing(String uid) => Future<void>.value();

  Future<void> call(String uid) async {
    try {
      await _forget(uid);
    } catch (_) {
      // Telemetry never blocks the final page.
    }
  }
}

/// Puts a [TelemetryDeviceForget] in the widget tree; without one, [of]
/// answers a no-op.
class TelemetryForgetScope extends InheritedWidget {
  const TelemetryForgetScope({
    super.key,
    required this.forget,
    required super.child,
  });

  final TelemetryDeviceForget forget;

  static TelemetryDeviceForget of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TelemetryForgetScope>()?.forget ??
      const TelemetryDeviceForget.none();

  @override
  bool updateShouldNotify(TelemetryForgetScope oldWidget) =>
      forget != oldWidget.forget;
}
