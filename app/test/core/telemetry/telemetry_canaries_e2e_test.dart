import 'dart:ui' show PlatformDispatcher;
import 'dart:convert';

import 'package:connectrpc/connect.dart' as connect;
import 'package:drift/native.dart';
import 'package:dzeroth/app/session_wiring.dart';
import 'package:dzeroth/core/storage/app_database.dart';
import 'package:dzeroth/core/telemetry/telemetry_consent_store.dart';
import 'package:dzeroth/core/telemetry/telemetry_inputs.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/telemetry_e2e_rig.dart';

/// The canaries end to end. Each leaky error is thrown for real
/// and handed to `reportUnexpectedError` (what ~20 repositories and cubits
/// call), which reaches the real error hook, the real controller, and the real
/// `FirebaseCrashReporter` payload rules. The fake Crashlytics port then holds
/// every argument that would leave the device.
const _canary = 'ZZCANARY123456789';
const _uid = 'uidQQuserQQ1234567890abcdefg'; // 28 chars, like a Firebase uid
final RegExp _sixDigits = RegExp(r'\d{6,}');
const _both = {kFeatureCrashReporting, kFeatureAnalytics};

void _expectClean(TelemetryE2eRig rig) {
  final all = rig.port.everything;
  expect(all, isNot(contains(_canary)), reason: all);
  expect(_sixDigits.hasMatch(all), isFalse, reason: all);
  expect(all, isNot(contains(_uid)), reason: 'the uid never leaves');
  expect(rig.calls.calls.join(), isNot(contains(_uid)));
}

/// Throws with [thrower], reports like the app does, returns the title the SDK
/// would show.
Future<String> _report(TelemetryE2eRig rig, void Function() thrower) async {
  final before = rig.port.recordedTitles.length;
  try {
    thrower();
  } catch (e, s) {
    reportUnexpectedError(e, s);
  }
  await pumpEventQueue();
  expect(
    rig.port.recordedTitles,
    hasLength(before + 1),
    reason: 'reported exactly once',
  );
  return rig.port.recordedTitles.last;
}

connect.ConnectException _connect(String message) => connect.ConnectException(
  connect.Code.failedPrecondition,
  message,
  details: [
    connect.ErrorDetail(
      'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
      common.ErrorDetail(
        reason: common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        message: message,
      ).writeToBuffer(),
    ),
  ],
);

void main() {
  late AppDatabase database;
  late TelemetryE2eRig rig;

  setUp(() async {
    TelemetryE2eRig.restoreHooksAfterTest();
    database = AppDatabase.forTesting(NativeDatabase.memory());
    rig = TelemetryE2eRig(database);
    await rig.consent.setAll(_uid, {
      TelemetryKind.crash: ConsentChoice.on,
      TelemetryKind.usage: ConsentChoice.on,
    });
    await rig.launch(restoredUid: _uid);
    await rig.getMe(_both);
  });

  tearDown(() async {
    await rig.dispose();
    await database.close();
  });

  test('jsonDecode input', () async {
    final title = await _report(rig, () => jsonDecode('{"a": $_canary'));
    expect(title, 'FormatException');
    _expectClean(rig);
  });

  test('NoSuchMethodError receiver', () async {
    final title = await _report(rig, () {
      final Object receiver = _canary;
      (receiver as dynamic).noSuchThing();
    });
    expect(title, isNot(contains('Receiver')));
    _expectClean(rig);
  });

  test('ArgumentError.value', () async {
    final title = await _report(
      rig,
      () => throw ArgumentError.value(_canary, 'name'),
    );
    expect(title, 'ArgumentError');
    _expectClean(rig);
  });

  test('RangeError', () async {
    await _report(rig, () => RangeError.checkValidIndex(123456789, [1]));
    await _report(rig, () => throw RangeError.value(123456789, _canary));
    _expectClean(rig);
  });

  test('PlatformException message and details', () async {
    final title = await _report(
      rig,
      () => throw PlatformException(
        code: 'io',
        message: '/data/user/0/$_canary/files',
        details: {'path': _canary},
      ),
    );
    expect(title, 'PlatformException');
    _expectClean(rig);
  });

  test('ConnectException message (code and reason only)', () async {
    final title = await _report(
      rig,
      () => throw _connect('user $_canary not found'),
    );
    expect(
      title,
      'ConnectException: failed_precondition ERROR_REASON_FEATURE_DISABLED',
    );
    final plain = await _report(
      rig,
      () => throw connect.ConnectException(connect.Code.unavailable, _canary),
    );
    expect(plain, 'ConnectException: unavailable');
    _expectClean(rig);
  });

  test('GoRouter no-route location', () async {
    await _report(
      rig,
      () => throw GoException('no routes for location: /u/$_canary'),
    );
    _expectClean(rig);
  });

  test('an email and an @handle', () async {
    final title = await _report(
      rig,
      () => throw StateError('for me@example.com / @alice $_canary'),
    );
    expect(title, startsWith('StateError: Bad state: for <email>'));
    await _report(rig, () => throw AssertionError('check @bob $_canary'));
    _expectClean(rig);
  });

  test('the uid as the message of an allowlisted type', () async {
    final title = await _report(rig, () => throw StateError('user $_uid'));
    expect(title, isNot(contains(_uid)));
    _expectClean(rig);
  });

  test(
    'a framework error with a context and an information collector',
    () async {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('bad'),
          stack: StackTrace.current,
          library: 'dzeroth',
          context: ErrorDescription('building Text("$_canary")'),
          informationCollector: () => [ErrorDescription(_canary)],
        ),
      );
      await pumpEventQueue();
      expect(rig.port.recordedTitles, hasLength(1));
      _expectClean(rig);
    },
  );

  test('an uncaught async error (fatal path) is clean too', () async {
    PlatformDispatcher.instance.onError!(
      ArgumentError.value(_canary, 'x'),
      StackTrace.current,
    );
    await pumpEventQueue();
    expect(rig.port.recordedTitles, ['ArgumentError']);
    expect(rig.port.args, contains(true), reason: 'reported as fatal');
    _expectClean(rig);
  });

  test(
    'only the three custom keys exist, with no id in their values',
    () async {
      await _report(rig, () => throw StateError('x'));
      expect(rig.port.keys.keys.toSet(), {
        'build_number',
        'FIREBASE_ENV',
        'platform',
      });
      expect(
        rig.port.keys.values.join(),
        allOf(isNot(contains(_uid)), isNot(contains(_canary))),
      );
      // No call other than record, key, collection and delete reached the SDK.
      expect(
        rig.port.calls.toSet().difference({
          'recordError',
          'setCustomKey',
          'setCollectionEnabled(true)',
          'setCollectionEnabled(false)',
          'deleteUnsent',
        }),
        isEmpty,
      );
    },
  );

  testWidgets('a Text that throws in build: the real framework details go '
      'through the installed hook', (tester) async {
    // Limit: testWidgets keeps its own zone, so the hook cannot run while the
    // widget builds. The real FlutterErrorDetails (with the framework's
    // context) are captured from the build, then reported in real time.
    final seen = <FlutterErrorDetails>[];
    final binding = FlutterError.onError;
    FlutterError.onError = seen.add;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (_) => throw Exception('Text($_canary)')),
      ),
    );
    FlutterError.onError = binding;
    expect(seen, isNotEmpty);
    expect(
      seen.first.toString(),
      contains(_canary),
      reason: 'the framework text really carries the canary',
    );

    final wired = TelemetryE2eRig(
      AppDatabase.forTesting(NativeDatabase.memory()),
    );
    await tester.runAsync(() async {
      await wired.consent.setAll(_uid, {
        TelemetryKind.crash: ConsentChoice.on,
        TelemetryKind.usage: ConsentChoice.on,
      });
      await wired.launch(restoredUid: _uid);
      await wired.getMe(_both);
      for (final details in seen) {
        FlutterError.reportError(details);
      }
      await pumpEventQueue();
      expect(wired.port.recordedTitles, hasLength(seen.length));
      _expectClean(wired);
      await wired.dispose();
      await wired.database.close();
    });
  });
}
