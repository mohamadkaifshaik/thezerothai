import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/firebase_crash_reporter.dart';
import 'package:dzeroth/core/telemetry/telemetry_adapters.dart';
import 'package:dzeroth/core/telemetry/telemetry_bootstrap.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_store.dart';
import 'package:dzeroth/core/telemetry/telemetry_controller.dart';
import 'package:dzeroth/core/telemetry/telemetry_device_forget.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/telemetry/fake_telemetry.dart';
import 'fake_crashlytics_port.dart';

/// One app launch with the real telemetry pieces and only the two SDK edges
/// faked: the real `startTelemetry`, `TelemetryController`, error
/// hooks, `FirebaseCrashReporter` (payload rules) over a [FakeCrashlyticsPort],
/// `TelemetryConsentStore` and the database-backed flag and last-uid stores.
/// The analytics edge is a fake [UsageAnalytics] (the SDK class has no port).
///
/// `bootstrap.dart` wires the same order inline (not callable from a test):
/// consent loaded for the restored uid inside `restoredUid`, `onAuthChanged`
/// from the auth bloc, `onEnabledFeatures` from each ready `GetMe`, and the
/// consent cubit loading a signed-in uid's answers. [signIn], [getMe] and
/// [signOut] copy that. A relaunch is a new rig over the same [database].
class TelemetryE2eRig {
  TelemetryE2eRig(this.database, {this.supported = true})
    : consent = TelemetryConsentStore(database);

  final AppDatabase database;
  final bool supported;
  final TelemetryConsentStore consent;
  final port = FakeCrashlyticsPort();
  final calls = CallLog();
  late final FakeUsageAnalytics usage = FakeUsageAnalytics(calls);
  late final TelemetryController controller;

  int get resets => calls.calls.where((c) => c == 'usage.reset').length;
  int get usageLogs => calls.calls.where((c) => c == 'usage.log').length;
  int get recordErrors => port.calls.where((c) => c == 'recordError').length;

  /// True when the last `setCollecting` the SDK edges saw was "on".
  bool? get crashSdkOn => _last(
    port.calls.where((c) => c.startsWith('setCollectionEnabled')),
    'setCollectionEnabled(',
  );
  bool? get usageSdkOn => _last(
    calls.calls.where((c) => c.startsWith('usage.setCollecting')),
    'usage.setCollecting(',
  );

  static bool? _last(Iterable<String> calls, String prefix) => calls.isEmpty
      ? null
      : calls.last.substring(prefix.length).startsWith('true');

  /// Restores the hooks a test replaced.
  static void restoreHooksAfterTest() {
    final flutter = FlutterError.onError;
    final dispatcher = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = flutter;
      PlatformDispatcher.instance.onError = dispatcher;
    });
  }

  /// `Firebase.initializeApp`, adapters, hooks, bootstrap decision.
  Future<void> launch({String? restoredUid}) async {
    controller = await startTelemetry(
      initializeFirebase: () async {},
      restoredUid: () async {
        if (restoredUid != null) await consent.load(restoredUid);
        return restoredUid;
      },
      memory: DatabaseTelemetryFlagMemory(database),
      consent: consent,
      lastUid: DatabaseTelemetryLastUidStore(database),
      supported: supported,
      adaptersFor: (isSupported) => isSupported
          ? TelemetryAdapters(
              crash: FirebaseCrashReporter(
                crashlytics: port,
                keys: const CrashKeys(
                  buildNumber: '42',
                  firebaseEnv: 'dev',
                  platform: 'android',
                ),
              ),
              analytics: usage,
            )
          : const TelemetryAdapters.noop(),
      debugLog: (_) {},
      installHooks: false,
    );
    installTelemetryErrorHooks(controller, debug: false);
  }

  /// An auth change to [uid], then that account's consent answers load (the
  /// consent cubit does this after every auth change).
  Future<void> signIn(String uid) async {
    controller.onAuthChanged(uid);
    await consent.load(uid);
    await pumpEventQueue();
  }

  Future<void> signOut() async {
    controller.onAuthChanged(null);
    await pumpEventQueue();
  }

  /// A fresh `GetMe` with these flag names.
  Future<void> getMe(Set<String> enabledFeatures) async {
    controller.onEnabledFeatures(enabledFeatures);
    await pumpEventQueue();
  }

  /// In-app Delete account of [uid], as `bootstrap.dart` wires it.
  Future<void> deleteAccount(String uid) async {
    await TelemetryDeviceForget.of(consent: consent, controller: controller)(
      uid,
    );
    await pumpEventQueue();
  }

  Future<void> dispose() async {
    await controller.dispose();
    await consent.dispose();
  }

  /// Every `AppSettingEntries` key this feature writes for [uid], and the
  /// device-level last-uid key.
  Future<Map<String, String?>> storedKeys(String uid) async => {
    for (final k in [
      TelemetryConsentStore.key(TelemetryKind.crash, uid),
      TelemetryConsentStore.key(TelemetryKind.usage, uid),
      DatabaseTelemetryFlagMemory.key(uid),
      DatabaseTelemetryLastUidStore.key,
    ])
      k: await database.readSetting(k),
  };
}
