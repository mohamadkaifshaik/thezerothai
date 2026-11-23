import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart' show stripSource;

/// Plan 5a Task 13b, fix round (13b-i review M5): `E2eePipeline.parts` hands
/// out the open vault's parts (the sender, the starter, the known set, the
/// runner: mutating collaborators), and `E2eePipeline.reportPortError`
/// reports in the pipeline's name. Both are public only because the port
/// (`EncryptedMessagingImpl`) lives in its own library. `@internal` would
/// not help (one package), so this guard checks that under lib/ only the
/// pipeline (the declarations) and the port's three files use them, and
/// that the declarations still exist (a guard that matches nothing proves
/// nothing).
///
/// Run from app/ (like the other guards).

const _dir = 'lib/features/messages/domain/e2ee/';
const _pipeline = '${_dir}e2ee_pipeline.dart';

/// The files that may use the two members.
const allowed = {
  _pipeline,
  '${_dir}encrypted_messaging_impl.dart',
  '${_dir}encrypted_messaging_reads.dart',
  '${_dir}encrypted_messaging_threads.dart',
};

/// Every use of `.parts` or `reportPortError` in [source] (comments and
/// strings stripped).
List<String> findUses(String source) {
  final code = stripSource(source, keepStrings: false);
  return [
    for (final m in RegExp(
      r'(\?|\.)\.?parts\b|\breportPortError\b',
    ).allMatches(code))
      m.group(0)!,
  ];
}

void main() {
  final files = readTree('lib', {'.dart'});

  test('only the port uses E2eePipeline.parts and reportPortError', () {
    final found = <String>[
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/') && !allowed.contains(e.key))
          for (final hit in findUses(e.value)) '${e.key}: $hit',
    ];
    expect(found, isEmpty);
    final pipeline = files[_pipeline]!;
    expect(
      pipeline.contains('PipelineParts? get parts {') &&
          pipeline.contains('void reportPortError(String step, '),
      isTrue,
      reason: 'the members the guard watches moved or changed',
    );
    for (final f in allowed.skip(1)) {
      expect(files.containsKey(f), isTrue, reason: f);
    }
  });

  group('self-tests', () {
    test('a read through any receiver is flagged', () {
      for (final source in [
        'final p = pipeline.parts;',
        'final s = pipeline?.parts?.sender;',
        'pipeline\n    .parts!.known;',
        'x._pipeline.reportPortError("a", s);',
        'final f = p.reportPortError;',
      ]) {
        expect(findUses(source), isNotEmpty, reason: source);
      }
    });

    test('another name, a comment or a string is not flagged', () {
      for (final source in [
        'final parts = build();',
        'uri.pathSegments;',
        'final departs = 1;',
        '// pipeline.parts\n',
        "final s = 'pipeline.reportPortError';",
      ]) {
        expect(findUses(source), isEmpty, reason: source);
      }
    });
  });
}
