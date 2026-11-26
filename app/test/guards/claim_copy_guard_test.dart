// Guard for the encryption claim's words (Plan 6 §4.5, Task 4.A).
//
// The app must never say any of the phrases below, in any string, comment or
// identifier of lib/ (generated code excluded). The scan is case-insensitive,
// reads curly apostrophes and quotes as straight ones, and joins whitespace
// runs, so a phrase split across lines of a string still counts when the
// break falls on a space ('...cut off ' 'immediately' does not, which is why
// adjacent-literal joins are removed first).
//
// Limits: §4.5 also bans "verified" as a lasting state, any claim for iOS and
// any claim that metadata is hidden. Those are meanings, not fixed words;
// the patterns below catch their usual spellings, and `claimVisible` (hidden
// on iOS, tested in test/features/messages/domain/e2ee/encryption_claim_test
// .dart) covers the iOS rule.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The phrases of §4.5, lower case.
const kBannedClaimPhrases = <String>[
  'nobody can read your messages',
  'not even us, ever',
  'not even us',
  'military-grade',
  'military grade',
  'recovers after a compromise',
  'a removed device is cut off immediately',
  'cut off immediately',
  "a stolen phone can't read your messages",
  'a stolen phone cannot read your messages',
  'private on every device',
  'encrypted backup',
  // "verified" as a lasting state.
  'always verified',
  'stays verified',
  'permanently verified',
  'verified forever',
  // A claim that metadata is hidden.
  'metadata is hidden',
  'metadata is encrypted',
  'hides your metadata',
  // Not "no metadata": a JPEG re-encode "with no metadata" (EXIF) is true.
];

/// [source] folded for the scan: lower case, straight apostrophes and
/// quotes, adjacent Dart string literals joined, whitespace runs as one
/// space.
String foldForClaimScan(String source) => source
    .toLowerCase()
    .replaceAll(RegExp('[‘’ʼ]'), "'")
    .replaceAll(RegExp('[“”]'), '"')
    // 'abc '\n    'def' and "abc " "def": the literal break goes.
    .replaceAll(RegExp(r"""(['"])\s*\n?\s*\1"""), '')
    .replaceAll(RegExp(r'\s+'), ' ');

/// The banned phrases found in each file of [sources] (path to content).
Map<String, List<String>> bannedClaimPhrases(Map<String, String> sources) {
  final found = <String, List<String>>{};
  for (final e in sources.entries) {
    final text = foldForClaimScan(e.value);
    final hits = [
      for (final p in kBannedClaimPhrases)
        if (text.contains(p)) p,
    ];
    if (hits.isNotEmpty) found[e.key] = hits;
  }
  return found;
}

Map<String, String> _libSources() => {
  for (final f in Directory('lib').listSync(recursive: true))
    if (f is File &&
        f.path.endsWith('.dart') &&
        !f.path.replaceAll(r'\', '/').startsWith('lib/gen/'))
      f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
};

void main() {
  test('lib/ never uses a banned claim phrase (Plan 6 §4.5)', () {
    final sources = _libSources();
    expect(sources.length, greaterThan(100), reason: 'the scan found lib/');
    expect(bannedClaimPhrases(sources), isEmpty);
  });

  test('the claim copy is in the scanned sources', () {
    final copy = _libSources().entries
        .where((e) => e.key.endsWith('encryption_copy.dart'))
        .single
        .value;
    expect(foldForClaimScan(copy), contains('we cannot read your messages.'));
  });

  group('the scan itself', () {
    test('finds a phrase whatever its case', () {
      expect(bannedClaimPhrases({'a.dart': "const x = 'Military-Grade';"}), {
        'a.dart': ['military-grade'],
      });
    });

    test('reads a curly apostrophe as a straight one', () {
      expect(
        bannedClaimPhrases({
          'a.dart': "const x = 'A stolen phone can’t read your messages';",
        }),
        {
          'a.dart': ["a stolen phone can't read your messages"],
        },
      );
    });

    test('finds a phrase split across adjacent string literals', () {
      expect(
        bannedClaimPhrases({
          'a.dart': "const x = 'Nobody can read '\n    'your messages';",
        }),
        {
          'a.dart': ['nobody can read your messages'],
        },
      );
    });

    test('finds a phrase split by a line break in a comment', () {
      expect(
        bannedClaimPhrases({'a.dart': '/// Private on every\n/// device.'}),
        isEmpty,
        reason: 'a comment break keeps its "///"; documented limit',
      );
      expect(
        bannedClaimPhrases({'a.dart': '/* Private on every\n   device. */'}),
        {
          'a.dart': ['private on every device'],
        },
      );
    });

    test('accepts the shipped claim words', () {
      expect(
        bannedClaimPhrases({
          'a.dart':
              "const h = 'We cannot read your messages.';\n"
              "const l = 'What this covers';",
        }),
        isEmpty,
      );
    });
  });
}
