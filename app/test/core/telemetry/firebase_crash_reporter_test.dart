import 'dart:convert';

import 'package:connectrpc/connect.dart' as connect;
import 'package:dzeroth/core/telemetry/firebase_crash_reporter.dart';
import 'package:dzeroth/gen/dzeroth/common/v1/common.pb.dart' as common;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/fake_crashlytics_port.dart';

const _canary = 'ZZCANARY123456789';
final RegExp _sixDigits = RegExp(r'\d{6,}');

(FirebaseCrashReporter, FakeCrashlyticsPort) _make() {
  final port = FakeCrashlyticsPort();
  return (
    FirebaseCrashReporter(
      crashlytics: port,
      keys: const CrashKeys(
        buildNumber: '42',
        firebaseEnv: 'dev',
        platform: 'android',
      ),
    ),
    port,
  );
}

void _expectClean(FakeCrashlyticsPort port) {
  expect(port.everything, isNot(contains(_canary)));
  expect(
    _sixDigits.hasMatch(port.everything),
    isFalse,
    reason: port.everything,
  );
}

Future<void> _recordThrown(
  FirebaseCrashReporter r,
  void Function() thrower,
) async {
  try {
    thrower();
  } catch (e, s) {
    await r.record(e, s);
  }
}

connect.ConnectException _connect(String message, common.ErrorReason reason) =>
    connect.ConnectException(
      connect.Code.failedPrecondition,
      message,
      details: [
        connect.ErrorDetail(
          'type.googleapis.com/dzeroth.common.v1.ErrorDetail',
          common.ErrorDetail(reason: reason, message: message).writeToBuffer(),
        ),
      ],
    );

void main() {
  group('canaries never reach the Crashlytics adapter', () {
    test('FlutterErrorDetails with context and collector', () async {
      final (r, port) = _make();
      final details = FlutterErrorDetails(
        exception: StateError('bad'),
        stack: StackTrace.current,
        context: ErrorDescription('building Text("$_canary")'),
        informationCollector: () => [ErrorDescription(_canary)],
      );
      // The controller forwards exception and stack; also survive the whole
      // details object being handed in.
      await r.record(details.exception, details.stack!);
      await r.record(details, details.stack!);
      _expectClean(port);
    });

    testWidgets('a real Text that throws in build', (tester) async {
      final seen = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = seen.add;
      addTearDown(() => FlutterError.onError = old);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(builder: (_) => throw Exception('Text($_canary)')),
        ),
      );
      final (r, port) = _make();
      for (final d in seen) {
        await r.record(d.exception, d.stack ?? StackTrace.empty);
        await r.record(d, d.stack ?? StackTrace.empty);
      }
      expect(seen, isNotEmpty);
      _expectClean(port);
    });

    test('jsonDecode input', () async {
      final (r, port) = _make();
      await _recordThrown(r, () => jsonDecode('{"a": $_canary'));
      _expectClean(port);
      expect(port.recordedTitles.single, 'FormatException');
    });

    test('NoSuchMethodError receiver', () async {
      final (r, port) = _make();
      await _recordThrown(r, () {
        final Object receiver = _canary;
        (receiver as dynamic).noSuchThing();
      });
      _expectClean(port);
      expect(port.recordedTitles.single, isNot(contains('Receiver')));
    });

    test('ArgumentError.value', () async {
      final (r, port) = _make();
      await _recordThrown(r, () => throw ArgumentError.value(_canary, 'name'));
      _expectClean(port);
      expect(port.recordedTitles.single, 'ArgumentError');
    });

    test('RangeError', () async {
      final (r, port) = _make();
      await _recordThrown(r, () => RangeError.checkValidIndex(123456789, [1]));
      await _recordThrown(r, () => throw RangeError.value(123456789, _canary));
      _expectClean(port);
    });

    test('PlatformException message and details', () async {
      final (r, port) = _make();
      await r.record(
        PlatformException(
          code: 'io',
          message: '/data/user/0/$_canary/files',
          details: {'path': _canary},
        ),
        StackTrace.current,
      );
      _expectClean(port);
      expect(port.recordedTitles.single, 'PlatformException');
    });

    test('ConnectException message', () async {
      final (r, port) = _make();
      await r.record(
        _connect(
          'user $_canary not found',
          common.ErrorReason.ERROR_REASON_FEATURE_DISABLED,
        ),
        StackTrace.current,
      );
      await r.record(
        connect.ConnectException(connect.Code.unavailable, _canary),
        StackTrace.current,
      );
      _expectClean(port);
      expect(
        port.recordedTitles.first,
        'ConnectException: failed_precondition ERROR_REASON_FEATURE_DISABLED',
      );
      expect(port.recordedTitles.last, 'ConnectException: unavailable');
    });

    test('GoRouter no-route location', () async {
      final (r, port) = _make();
      await r.record(
        GoException('no routes for location: /u/$_canary'),
        StackTrace.current,
      );
      _expectClean(port);
    });

    test('an email and an @handle in allowlisted types', () async {
      final (r, port) = _make();
      await r.record(
        StateError('failed for me@example.com / @alice $_canary'),
        StackTrace.current,
      );
      await r.record(AssertionError('check @bob $_canary'), StackTrace.current);
      _expectClean(port);
      expect(
        port.recordedTitles.first,
        startsWith('StateError: Bad state: failed for <email>'),
      );
    });

    test('a FlutterError keeps only its first line', () async {
      final (r, port) = _make();
      await r.record(
        FlutterError.fromParts([
          ErrorSummary('A RenderFlex overflowed by 12 pixels on the right.'),
          ErrorDescription('The text was $_canary'),
        ]),
        StackTrace.current,
      );
      _expectClean(port);
      expect(
        port.recordedTitles.single,
        startsWith('FlutterError: A RenderFlex overflowed'),
      );
    });

    test('a FlutterError that is not layout carries no message', () async {
      final (r, port) = _make();
      await r.record(
        FlutterError('Something about $_canary'),
        StackTrace.current,
      );
      _expectClean(port);
      expect(port.recordedTitles.single, 'FlutterError');
    });
  });

  group('payload rules', () {
    test('message is cut to 200 characters', () async {
      final (r, port) = _make();
      await r.record(StateError('x ' * 500), StackTrace.current);
      expect(
        port.recordedTitles.single.length,
        lessThanOrEqualTo('StateError: '.length + 200),
      );
    });

    test('type and stack are always sent', () async {
      final (r, port) = _make();
      final stack = StackTrace.fromString(
        '#0 main (package:dzeroth/m.dart:1:2)',
      );
      await r.record(ArgumentError('x'), stack, fatal: true);
      expect(port.recordedTitles.single, 'ArgumentError');
      expect(port.args, contains(stack.toString()));
      expect(port.args, contains(true));
    });

    test(
      'custom keys are exactly build number, FIREBASE_ENV, platform',
      () async {
        final (r, port) = _make();
        await r.setCollecting(true);
        await r.record(StateError('a'), StackTrace.empty);
        await r.record(StateError('b'), StackTrace.empty);
        expect(port.keys, {
          'build_number': '42',
          'FIREBASE_ENV': 'dev',
          'platform': 'android',
        });
        expect(port.calls.where((c) => c == 'setCustomKey').length, 3);
      },
    );

    test('collection and delete calls pass through', () async {
      final (r, port) = _make();
      await r.setCollecting(false);
      await r.deleteUnsentReports();
      expect(port.calls, ['setCollectionEnabled(false)', 'deleteUnsent']);
    });
  });
}
