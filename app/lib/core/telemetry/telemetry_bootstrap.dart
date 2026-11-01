import 'package:flutter/foundation.dart';

import 'telemetry_adapters.dart';
import 'telemetry_controller.dart';
import 'telemetry_inputs.dart';
import 'telemetry_platforms.dart';

/// Installs the error hooks (TEL-4), with no loop:
///
/// - [FlutterError.onError] is the single sink for framework errors AND for
///   `reportUnexpectedError` (which calls `FlutterError.reportError`). In debug
///   it prints through [FlutterError.presentError] first, then records. The
///   record path never calls `FlutterError.reportError`, so it cannot re-enter.
/// - [PlatformDispatcher.onError] (uncaught async errors) records directly, as
///   fatal; it returns true so the error counts as handled.
void installTelemetryErrorHooks(
  TelemetryController controller, {
  bool? debug,
  void Function(FlutterErrorDetails details)? presentError,
}) {
  final isDebug = debug ?? kDebugMode;
  final present = presentError ?? FlutterError.presentError;
  FlutterError.onError = (details) {
    if (isDebug) present(details);
    controller.recordFlutterError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    if (isDebug) {
      present(FlutterErrorDetails(exception: error, stack: stack));
    }
    controller.recordError(error, stack, fatal: true);
    return true;
  };
}

/// Starts telemetry in the one allowed order (tested):
/// 1. [initializeFirebase] (`Firebase.initializeApp`; the SDK instances need
///    the default app, so no adapter is built before it),
/// 2. build the adapters for this platform,
/// 3. install the error hooks (off until step 4 decides),
/// 4. apply the decision stored for the restored uid, which always reaches the
///    SDKs because their native state persists.
///
/// Returns the controller for `GetMe`, auth and consent wiring.
Future<TelemetryController> startTelemetry({
  required Future<void> Function() initializeFirebase,
  required Future<String?> Function() restoredUid,
  TelemetryFlagMemory? memory,
  TelemetryConsentSource consent = const NoTelemetryConsent(),
  bool? supported,
  TelemetryAdapters Function(bool supported)? adaptersFor,
  void Function(String message)? debugLog,
  bool installHooks = true,
}) async {
  await initializeFirebase();
  final isSupported = supported ?? TelemetryPlatforms.current;
  final adapters = adaptersFor != null
      ? adaptersFor(isSupported)
      : createTelemetryAdapters(supported: isSupported);
  final controller = TelemetryController(
    adapters: adapters,
    platformSupported: isSupported,
    consent: consent,
    memory: memory,
    debugLog: debugLog,
  );
  if (installHooks) installTelemetryErrorHooks(controller);
  await controller.applyAtBootstrap(await restoredUid());
  return controller;
}
