import 'dart:async';

import 'package:flutter/foundation.dart';

import 'analytics_event.dart';
import 'telemetry_adapters.dart';
import 'telemetry_inputs.dart';
import 'telemetry_interfaces.dart';

/// The one place that decides whether crash reports and usage statistics are
/// collected.
///
/// Collecting a kind is on only when ALL of these hold:
/// 1. the platform is supported (Android),
/// 2. a uid is signed in,
/// 3. that kind's flag is in `GetMe.enabled_features`, and
/// 4. consent is stored "on" for that uid and kind.
///
/// The decision is a synchronous in-memory value ([crashCollecting],
/// [usageCollecting]); [recordError] and the other entry points read it before
/// touching an adapter, so nothing is reported while it is off. Every adapter
/// call (each "off" included, with `deleteUnsentReports`) runs on one queue, in
/// the order it was decided. Flags belong to the signed-in account: any uid
/// change drops them until that account's next `GetMe`, so an A to B switch is
/// off at once.
///
/// Apply at bootstrap right after `Firebase.initializeApp`
/// ([applyAtBootstrap]), then call [onAuthChanged] and [onEnabledFeatures]
/// (every `GetMe`); consent changes arrive through the consent source. 0 RPCs.
class TelemetryController {
  TelemetryController({
    required TelemetryAdapters adapters,
    required bool platformSupported,
    TelemetryConsentSource consent = const NoTelemetryConsent(),
    TelemetryFlagMemory? memory,
    TelemetryLastUidStore? lastUid,
    void Function(String message)? debugLog,
  }) : _crash = adapters.crash,
       _analytics = adapters.analytics,
       _platformSupported = platformSupported,
       _consent = consent,
       _memory = memory ?? InMemoryTelemetryFlagMemory(),
       _lastUid = lastUid ?? InMemoryTelemetryLastUidStore(),
       _debugLog = debugLog ?? _defaultDebugLog {
    _consentSub = _consent.changes.listen((_) => _decide());
  }

  final CrashReporter _crash;
  final UsageAnalytics _analytics;
  final bool _platformSupported;
  final TelemetryConsentSource _consent;
  final TelemetryFlagMemory _memory;
  final TelemetryLastUidStore _lastUid;
  final void Function(String message) _debugLog;
  late final StreamSubscription<void> _consentSub;

  String? _uid;
  TelemetryFlags _flags = TelemetryFlags.off;

  // What the adapters were last told; null until the first (bootstrap) apply,
  // so that apply always reaches the SDK.
  bool? _appliedCrash;
  bool? _appliedUsage;

  // Every adapter call runs after the previous one.
  Future<void> _queue = Future<void>.value();

  bool get crashCollecting =>
      _platformSupported &&
      _uid != null &&
      _flags.crash &&
      _consent.crashConsented(_uid!);

  bool get usageCollecting =>
      _platformSupported &&
      _uid != null &&
      _flags.analytics &&
      _consent.usageConsented(_uid!);

  /// Applies the stored decision of the account the auth SDK restored (null
  /// when nobody is signed in) and always reaches the SDKs, because their
  /// native state persists across launches. Call right after
  /// `Firebase.initializeApp`, before the first frame.
  Future<void> applyAtBootstrap(String? restoredUid) async {
    _uid = restoredUid;
    _flags = restoredUid == null
        ? TelemetryFlags.off
        : await _memory.read(restoredUid) ?? TelemetryFlags.off;
    // The reset goes first here: stored flags and consent can switch usage
    // on right away, and the SDK's own automatic events must not run under
    // the previous account's ID.
    if (restoredUid != null) _noteSignIn(restoredUid);
    _decide(force: true);
    await _queue;
  }

  /// The signed-in uid changed (null is a sign-out). A different uid drops the
  /// previous account's flags until its own `GetMe`.
  void onAuthChanged(String? uid) {
    if (uid == _uid) return;
    _uid = uid;
    _flags = TelemetryFlags.off;
    _decide();
    if (uid != null) _noteSignIn(uid);
  }

  /// A fresh `GetMe` of the current account.
  void onEnabledFeatures(Set<String> enabledFeatures) {
    _flags = TelemetryFlags.fromFeatures(enabledFeatures);
    final uid = _uid;
    if (uid != null) {
      final flags = _flags;
      unawaited(_enqueue(() => _memory.write(uid, flags)));
    }
    _decide();
  }

  /// Reports through the crash adapter, only while collecting. Completes when
  /// the adapter has it (immediately when dropped).
  Future<void> recordError(
    Object error,
    StackTrace stack, {
    bool fatal = false,
  }) {
    if (!crashCollecting) return Future<void>.value();
    return _enqueue(() => _crash.record(error, stack, fatal: fatal));
  }

  /// [FlutterErrorDetails] carry a `context` and an information collector that
  /// can hold text; only the exception and stack are forwarded.
  Future<void> recordFlutterError(FlutterErrorDetails details) =>
      recordError(details.exception, details.stack ?? StackTrace.empty);

  /// Usage statistics, only while collecting.
  Future<void> logEvent(AnalyticsEvent event) {
    if (!usageCollecting) return Future<void>.value();
    return _enqueue(() => _analytics.log(event));
  }

  Future<void> logScreen(String name) {
    if (!usageCollecting) return Future<void>.value();
    return _enqueue(() => _analytics.screen(name));
  }

  /// F11 /: reset the device's analytics id. Allowed while off, because
  /// deletion and account switches happen then too.
  Future<void> resetDevice() => _enqueue(_analytics.resetDevice);

  /// In-app deletion of [uid] (the consent keys go through the consent
  /// store): drop the reports not yet sent, reset the analytics ID and forget
  /// the uid's flags and last-uid record. Allowed while off.
  Future<void> forgetDevice(String uid) async {
    await _enqueue(_crash.deleteUnsentReports);
    await _enqueue(_analytics.resetDevice);
    await _enqueue(() => _memory.forget(uid));
    await _enqueue(() => _lastUid.forget(uid));
  }

  Future<void> dispose() => _consentSub.cancel();

  /// F11: a different account than the last one on this device gets a fresh
  /// analytics ID. Queued right after the "off" decision of the switch and ahead
  /// of anything the new uid can log (its flags are off until its own `GetMe`),
  /// so the reset runs before that account's first event. No record yet (F12)
  /// or an unreadable one counts as a different account and resets; the
  /// same uid again resets nothing.
  void _noteSignIn(String uid) {
    unawaited(
      _enqueue(() async {
        String? last;
        var readFailed = false;
        try {
          last = await _lastUid.read();
        } catch (_) {
          readFailed = true; // fail closed: reset below
        }
        if (readFailed || last != uid) {
          try {
            await _analytics.resetDevice();
          } catch (_) {
            // Never breaks sign-in; the uid is recorded below anyway.
          }
          try {
            await _lastUid.write(uid);
          } catch (_) {
            // The next sign-in finds no record and resets again.
          }
        }
      }),
    );
  }

  void _decide({bool force = false}) {
    final crash = crashCollecting;
    final usage = usageCollecting;
    if (force || crash != _appliedCrash) {
      _appliedCrash = crash;
      _debugLog('telemetry: crash reports ${crash ? 'on' : 'off'}');
      // Step 1 (L-1): reports from before consent never
      // upload. A no-op once native collection is on, so safe in every state.
      if (crash) unawaited(_enqueue(_crash.deleteUnsentReports));
      unawaited(_enqueue(() => _crash.setCollecting(crash)));
      if (!crash) unawaited(_enqueue(_crash.deleteUnsentReports));
    }
    if (force || usage != _appliedUsage) {
      _appliedUsage = usage;
      _debugLog('telemetry: usage statistics ${usage ? 'on' : 'off'}');
      unawaited(_enqueue(() => _analytics.setCollecting(usage)));
    }
  }

  Future<void> _enqueue(Future<void> Function() call) {
    final next = _queue.then((_) => call()).catchError((Object _) {
      // A failing SDK call must never break the app or loop back into the
      // error hooks; the next decision applies again.
    });
    _queue = next;
    return next;
  }

  static void _defaultDebugLog(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
