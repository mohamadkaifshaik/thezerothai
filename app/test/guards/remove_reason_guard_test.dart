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
/// `KeysRepository.removeDevice` takes the reason as a required parameter,
/// so the compiler already refuses a call without one. What the compiler
/// does not see (review M2, fix round 1): a `RemoveKeyDeviceRequest` built
/// anywhere else (its `reason` defaults to UNSPECIFIED), or the UNSPECIFIED
/// value named. So the request is built in [_repository] only, there with a
/// `reason:`, and UNSPECIFIED is named nowhere outside `lib/gen`.
///
/// Run from app/ (like the other guards).

const _repository = 'lib/features/keys/data/keys_repository.dart';

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

/// The constructions of [source] at [path] that break the rule: any one
/// outside [_repository], and one there without a `reason:` or with
/// UNSPECIFIED.
List<String> findBadRequests(String path, String source) => [
  for (final args in requestConstructions(source))
    if (path != _repository ||
        !RegExp(r'\breason\s*:').hasMatch(args) ||
        args.contains('REMOVE_REASON_UNSPECIFIED'))
      args.trim(),
];

/// Whether [source] names the UNSPECIFIED reason in code.
bool namesUnspecified(String source) => stripSource(
  source,
  keepStrings: false,
).contains('REMOVE_REASON_UNSPECIFIED');

void main() {
  final files = readTree('lib', {'.dart'});

  test('a RemoveKeyDeviceRequest is built only in the repository, with a '
      'reason', () {
    final found = <String>[];
    var built = 0;
    for (final e in files.entries) {
      if (e.key.startsWith('lib/gen/')) continue;
      built += requestConstructions(e.value).length;
      for (final hit in findBadRequests(e.key, e.value)) {
        found.add('${e.key}: RemoveKeyDeviceRequest($hit)');
      }
    }
    expect(found, isEmpty);
    // A guard that matches nothing proves nothing.
    expect(built, greaterThanOrEqualTo(1), reason: 'the scan found none');
  });

  test('no code outside lib/gen names REMOVE_REASON_UNSPECIFIED', () {
    final found = <String>[
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/') && namesUnspecified(e.value)) e.key,
    ];
    expect(found, isEmpty);
  });

  group('self-tests', () {
    test('a request built outside the repository is flagged, with or without '
        'a reason', () {
      const outside = 'lib/features/messages/domain/e2ee/x.dart';
      expect(
        findBadRequests(
          outside,
          '_api.keys.removeKeyDevice(pb.RemoveKeyDeviceRequest(deviceId: id));',
        ),
        hasLength(1),
      );
      expect(
        findBadRequests(
          outside,
          'pb.RemoveKeyDeviceRequest(deviceId: id, '
          'reason: pb.RemoveReason.REMOVE_REASON_REMOTE)',
        ),
        hasLength(1),
      );
    });

    test('in the repository, a request needs a reason other than '
        'UNSPECIFIED', () {
      expect(
        findBadRequests(_repository, 'pb.RemoveKeyDeviceRequest(deviceId: id)'),
        hasLength(1),
      );
      expect(
        findBadRequests(
          _repository,
          'pb.RemoveKeyDeviceRequest(deviceId: id, '
          'reason: pb.RemoveReason.REMOVE_REASON_UNSPECIFIED)',
        ),
        hasLength(1),
      );
      expect(
        findBadRequests(
          _repository,
          'pb.RemoveKeyDeviceRequest(idempotencyKey: k, deviceId: id, '
          'reason: reason)',
        ),
        isEmpty,
      );
      expect(
        findBadRequests(
          'lib/x.dart',
          '// pb.RemoveKeyDeviceRequest(deviceId: id)\n',
        ),
        isEmpty,
      );
    });

    test('the UNSPECIFIED value is seen in code, not in a comment', () {
      expect(
        namesUnspecified('final r = RemoveReason.REMOVE_REASON_UNSPECIFIED;'),
        isTrue,
      );
      expect(namesUnspecified('// REMOVE_REASON_UNSPECIFIED\n'), isFalse);
    });
  });
}
