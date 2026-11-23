import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart' show stripSource;

/// Plan 5a Task 12, removal design section 4 (security audit L3): every
/// RemoveKeyDevice names its reason. SIGN_OUT for this device's own
/// sign-out, REMOTE for the removal of another device (which the server
/// remembers). UNSPECIFIED is what shipped builds send and the server reads
/// it as SIGN_OUT, so new code must never send it: a REMOTE removal sent
/// without its reason would leave no mark.
///
/// `KeysRepository.removeDevice` takes the reason as a required parameter
/// and refuses UNSPECIFIED at run time (fix wave 8). What the compiler does
/// not see (review M2, fix round 1; security audit L4, fix wave 8): a
/// request built or sent anywhere else (a constructor, `.create()`,
/// `.fromBuffer`, `.clone()`; its `reason` defaults to UNSPECIFIED), a
/// direct `removeKeyDevice(` call that bypasses the repository, a reason
/// computed from the enum (`RemoveReason.valueOf(0)`,
/// `RemoveReason.values.first`), or the UNSPECIFIED value named. So outside
/// [_repository] (and lib/gen) the code names none of
/// `RemoveKeyDeviceRequest`, `removeKeyDevice(`, `RemoveReason.valueOf`,
/// `RemoveReason.values` or `REMOVE_REASON_UNSPECIFIED`; inside it, every
/// request construction carries a `reason:` other than UNSPECIFIED.
///
/// Run from app/ (like the other guards).

const _repository = 'lib/features/keys/data/keys_repository.dart';

/// What no file outside [_repository] may name in code.
final List<RegExp> _forbiddenOutside = [
  RegExp(r'\bRemoveKeyDeviceRequest\b'),
  RegExp(r'\bremoveKeyDevice\s*\('),
  RegExp(r'\bRemoveReason\s*\.\s*valueOf\b'),
  RegExp(r'\bRemoveReason\s*\.\s*values\b'),
  RegExp(r'\bREMOVE_REASON_UNSPECIFIED\b'),
];

/// The argument text of every `RemoveKeyDeviceRequest(...)` construction in
/// [source] (comments and strings stripped), parentheses matched.
List<String> requestConstructions(String source) {
  final code = stripSource(source, keepStrings: false);
  final out = <String>[];
  for (final m in RegExp(r'\bRemoveKeyDeviceRequest\s*\(').allMatches(code)) {
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

/// What [source] at [path] names against the rule (empty: nothing).
List<String> findViolations(String path, String source) {
  final code = stripSource(source, keepStrings: false);
  if (path != _repository) {
    return [
      for (final p in _forbiddenOutside)
        for (final m in p.allMatches(code)) m.group(0)!,
    ];
  }
  return [
    for (final args in requestConstructions(source))
      if (!RegExp(r'\breason\s*:').hasMatch(args) ||
          args.contains('REMOVE_REASON_UNSPECIFIED'))
        'RemoveKeyDeviceRequest(${args.trim()})',
    for (final p in [
      RegExp(r'\bRemoveReason\s*\.\s*valueOf\b'),
      RegExp(r'\bRemoveReason\s*\.\s*values\b'),
      RegExp(r'\bRemoveKeyDeviceRequest\s*\.\s*\w+'),
    ])
      for (final m in p.allMatches(code)) m.group(0)!,
  ];
}

void main() {
  final files = readTree('lib', {'.dart'});

  test('outside the repository no code names the removal request, the '
      'RPC, a computed reason or UNSPECIFIED; the repository builds each '
      'request with a reason', () {
    final found = <String>[
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/'))
          for (final hit in findViolations(e.key, e.value)) '${e.key}: $hit',
    ];
    expect(found, isEmpty);
    // A guard that matches nothing proves nothing.
    expect(
      requestConstructions(files[_repository]!),
      isNotEmpty,
      reason: 'the scan found no request in the repository',
    );
  });

  group('self-tests', () {
    const outside = 'lib/features/messages/domain/e2ee/x.dart';

    test('outside the repository every way to build or send a request is '
        'flagged', () {
      for (final source in [
        'pb.RemoveKeyDeviceRequest(deviceId: id)',
        'pb.RemoveKeyDeviceRequest(deviceId: id, '
            'reason: pb.RemoveReason.REMOVE_REASON_REMOTE)',
        'final r = pb.RemoveKeyDeviceRequest.create()..deviceId = id;',
        'pb.RemoveKeyDeviceRequest.fromBuffer(bytes)',
        '_apiClient.keys.removeKeyDevice(r)',
        'reason: pb.RemoveReason.valueOf(0)!',
        'reason: pb.RemoveReason.values.first',
        'final r = RemoveReason.REMOVE_REASON_UNSPECIFIED;',
      ]) {
        expect(findViolations(outside, source), isNotEmpty, reason: source);
      }
    });

    test('the repository call with a reason passes; a comment or string '
        'is not code', () {
      expect(
        findViolations(
          _repository,
          '_apiClient.keys.removeKeyDevice(pb.RemoveKeyDeviceRequest('
          'idempotencyKey: k, deviceId: id, reason: reason))',
        ),
        isEmpty,
      );
      expect(
        findViolations(
          _repository,
          'if (reason == pb.RemoveReason.REMOVE_REASON_UNSPECIFIED) throw x;',
        ),
        isEmpty,
      );
      expect(
        findViolations(outside, '// pb.RemoveKeyDeviceRequest(deviceId: id)\n'),
        isEmpty,
      );
      expect(findViolations(outside, "const s = 'removeKeyDevice(';"), isEmpty);
    });

    test('in the repository a request without a reason, with UNSPECIFIED, '
        'built another way or with a computed reason is flagged', () {
      for (final source in [
        'pb.RemoveKeyDeviceRequest(deviceId: id)',
        'pb.RemoveKeyDeviceRequest(deviceId: id, '
            'reason: pb.RemoveReason.REMOVE_REASON_UNSPECIFIED)',
        'pb.RemoveKeyDeviceRequest.create()',
        'reason: pb.RemoveReason.valueOf(0)!',
      ]) {
        expect(findViolations(_repository, source), isNotEmpty, reason: source);
      }
    });
  });
}
