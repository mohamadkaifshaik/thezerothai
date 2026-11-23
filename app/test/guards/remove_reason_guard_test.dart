import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart' show stripSource;

/// Plan 5a Task 12, removal design section 4 (security audit L3): every
/// `KeysRepository.removeDevice` call names its reason. SIGN_OUT for this
/// device's own sign-out, REMOTE for the removal of another device (which
/// the server remembers). UNSPECIFIED is what shipped builds send and the
/// server reads it as SIGN_OUT, so new code must never send it: a REMOTE
/// removal sent without its reason would leave no mark.
///
/// A repository call is told from the other `removeDevice(` methods (the
/// port's and the removal queue's take one positional id) by its named
/// `deviceId:` argument.
///
/// Run from app/ (like the other guards).

/// The argument text of every `removeDevice(...)` call or declaration in
/// [source] (comments and strings stripped), parentheses matched.
List<String> removeDeviceArguments(String source) {
  final code = stripSource(source, keepStrings: false);
  final out = <String>[];
  for (final m in RegExp(r'\bremoveDevice\s*\(').allMatches(code)) {
    var depth = 1;
    var i = m.end;
    while (i < code.length && depth > 0) {
      final c = code[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      i++;
    }
    out.add(code.substring(m.end, i - 1));
  }
  return out;
}

/// The repository calls among [removeDeviceArguments] that send no reason or
/// UNSPECIFIED. A declaration (`required String deviceId`) is not a call.
List<String> findCallsWithoutReason(String source) => [
  for (final args in removeDeviceArguments(source))
    if (RegExp(r'\bdeviceId\s*:').hasMatch(args) &&
        !RegExp(r'\brequired\b').hasMatch(args) &&
        (!RegExp(r'\breason\s*:').hasMatch(args) ||
            args.contains('REMOVE_REASON_UNSPECIFIED')))
      args.trim(),
];

/// The repository calls among [removeDeviceArguments] (declarations left
/// out).
int countRepositoryCalls(String source) => [
  for (final args in removeDeviceArguments(source))
    if (RegExp(r'\bdeviceId\s*:').hasMatch(args) &&
        !RegExp(r'\brequired\b').hasMatch(args))
      args,
].length;

void main() {
  final files = readTree('lib', {'.dart'});

  test('every KeysRepository.removeDevice call names a reason other than '
      'UNSPECIFIED', () {
    final found = <String>[];
    var calls = 0;
    for (final e in files.entries) {
      if (e.key.startsWith('lib/gen/')) continue;
      calls += countRepositoryCalls(e.value);
      for (final hit in findCallsWithoutReason(e.value)) {
        found.add('${e.key}: removeDevice($hit)');
      }
    }
    expect(found, isEmpty);
    // The sign-out removal and the removal queue: a guard that matches
    // nothing proves nothing.
    expect(calls, greaterThanOrEqualTo(2), reason: 'the scan found no calls');
  });

  test('no code outside lib/gen names REMOVE_REASON_UNSPECIFIED', () {
    final found = <String>[
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/') &&
            stripSource(
              e.value,
              keepStrings: false,
            ).contains('REMOVE_REASON_UNSPECIFIED'))
          e.key,
    ];
    expect(found, isEmpty);
  });

  group('self-tests', () {
    test('a call without a reason, or with UNSPECIFIED, is flagged', () {
      expect(
        findCallsWithoutReason(
          'await _repo.removeDevice(deviceId: id, idempotencyKey: k());',
        ),
        hasLength(1),
      );
      expect(
        findCallsWithoutReason(
          'await _repo.removeDevice(deviceId: id, idempotencyKey: k(), '
          'reason: pb.RemoveReason.REMOVE_REASON_UNSPECIFIED);',
        ),
        hasLength(1),
      );
    });

    test('a call with a reason, a declaration and the positional methods '
        'pass', () {
      expect(
        findCallsWithoutReason(
          'await _keys.removeDevice(deviceId: f(id), idempotencyKey: k, '
          'reason: pb.RemoveReason.REMOVE_REASON_REMOTE);',
        ),
        isEmpty,
      );
      expect(
        findCallsWithoutReason(
          'Future<X> removeDevice({required String deviceId, '
          'required String idempotencyKey}) => y;',
        ),
        isEmpty,
      );
      expect(findCallsWithoutReason('await runner.removeDevice(id);'), isEmpty);
      expect(
        findCallsWithoutReason(
          '// _repo.removeDevice(deviceId: id, idempotencyKey: k)\n',
        ),
        isEmpty,
      );
    });
  });
}
