import 'package:flutter_test/flutter_test.dart';

import 'telemetry_scan.dart' show readTree;
import 'vault_scan.dart' show stripSource;

/// Plan 5a Task 13, fix round 1 (review n4): `E2eePipeline(budgetScale:)`
/// multiplies every sync budget's calls per minute. Only tests may raise
/// it (the rig clock stands still); production must always run at 1. The
/// annotation `@visibleForTesting` on a constructor parameter is weak, so
/// this guard checks that no code under lib/ passes `budgetScale:` at all
/// (bootstrap, step 13-ii, included), and that the parameter still exists
/// where the guard expects it (a guard that matches nothing proves nothing).
///
/// Run from app/ (like the other guards).

const _pipeline = 'lib/features/messages/domain/e2ee/e2ee_pipeline.dart';

/// Every `budgetScale:` named argument in [source] (comments and strings
/// stripped).
List<String> findViolations(String source) {
  final code = stripSource(source, keepStrings: false);
  return [
    for (final m in RegExp(r'\bbudgetScale\s*:').allMatches(code)) m.group(0)!,
  ];
}

void main() {
  final files = readTree('lib', {'.dart'});

  test('no code under lib/ passes budgetScale to the pipeline', () {
    final found = <String>[
      for (final e in files.entries)
        if (!e.key.startsWith('lib/gen/'))
          for (final hit in findViolations(e.value)) '${e.key}: $hit',
    ];
    expect(found, isEmpty);
    expect(
      RegExp(r'\bint budgetScale = 1\b').hasMatch(files[_pipeline]!),
      isTrue,
      reason: 'the parameter the guard watches moved or changed',
    );
  });

  group('self-tests', () {
    test('a named argument is flagged, wherever it is', () {
      for (final source in [
        'E2eePipeline(session: s, budgetScale: 50)',
        'final p = E2eePipeline(\n  budgetScale : 2,\n);',
      ]) {
        expect(findViolations(source), isNotEmpty, reason: source);
      }
    });

    test('the declaration, a comment or a string is not flagged', () {
      for (final source in [
        '@visibleForTesting int budgetScale = 1,',
        '_budgetScale = budgetScale,',
        '// E2eePipeline(budgetScale: 50)\n',
        "final s = 'budgetScale: 50';",
      ]) {
        expect(findViolations(source), isEmpty, reason: source);
      }
    });
  });
}
