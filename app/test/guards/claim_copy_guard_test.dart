// Guard for the encryption claim's words (Plan 6 §4.5, Task 4.A; widened in
// PR 6-6 fix round 1, security M2).
//
// None of the phrases below may appear in any string, comment or identifier
// of lib/ (generated code excluded), nor in app/web/**/*.html or *.json (the
// static pages and the manifest). Before matching, each source is folded:
// - HTML entities decoded (&rsquo; &lsquo; &apos; &quot; &nbsp; &mdash;
//   &ndash;, every numeric &#NN; / &#xNN;, then &amp;) and Dart escapes
//   decoded (\' \" \uXXXX \u{X...});
// - lower case;
// - curly apostrophes and quotes become straight ones;
// - Unicode dashes (U+2010-U+2015, U+2212) become '-';
// - zero-width characters (U+200B-U+200D, U+FEFF) are removed;
// - adjacent Dart string literals are joined, whatever their quote types, a
//   raw `r` prefix, or a `+` between them;
// - whitespace runs become one space.
// So a phrase split across literals, or hidden with a look-alike dash or an
// invisible character, still counts.
//
// Limits: §4.5 also bans "verified" as a lasting state, any claim for iOS
// and any claim that metadata is hidden. Those are meanings, not fixed words.
// The patterns below catch their usual wordings, and `claimVisible` (hidden
// on iOS, tested in test/features/messages/domain/e2ee/encryption_claim_test
// .dart) enforces the iOS rule. A phrase broken across `///` comment lines
// is not caught (a self-test records this).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The phrases of §4.5, lower case.
const kBannedClaimPhrases = <String>[
  'nobody can read your messages',
  'no one can read your messages',
  'nobody, not even',
  'not even us, ever',
  'not even us',
  "even we can't read",
  'even we cannot read',
  'military-grade',
  'military grade',
  'recovers after a compromise',
  'a removed device is cut off immediately',
  'cut off immediately',
  'cut off at once',
  'locks it out',
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

/// [code] as a character, or null when it is not a valid code point.
String? _char(int? code) =>
    code == null ||
        code < 0 ||
        code > 0x10ffff ||
        (code >= 0xd800 && code <= 0xdfff)
    ? null
    : String.fromCharCode(code);

const _namedEntities = {
  'rsquo': '\u2019',
  'lsquo': '\u2018',
  'apos': "'",
  'quot': '"',
  'nbsp': ' ',
  'mdash': '\u2014',
  'ndash': '\u2013',
};

/// HTML entities decoded: the named ones above and every numeric `&#NN;` /
/// `&#xNN;`, then `&amp;` last (so `&amp;#39;` stays text, as a browser
/// shows it).
String decodeHtmlEntities(String s) => s
    .replaceAllMapped(RegExp(r'&#(x[0-9a-f]+|[0-9]+);', caseSensitive: false), (
      m,
    ) {
      final v = m.group(1)!;
      final code = v[0] == 'x' || v[0] == 'X'
          ? int.tryParse(v.substring(1), radix: 16)
          : int.tryParse(v);
      return _char(code) ?? m.group(0)!;
    })
    .replaceAllMapped(
      RegExp(
        r'&(rsquo|lsquo|apos|quot|nbsp|mdash|ndash);',
        caseSensitive: false,
      ),
      (m) => _namedEntities[m.group(1)!.toLowerCase()]!,
    )
    .replaceAll(RegExp('&amp;', caseSensitive: false), '&');

/// Dart string escapes decoded: `\'`, `\"`, `\uXXXX` and `\u{X…}`.
String decodeDartEscapes(String s) => s
    .replaceAllMapped(
      RegExp(r'\\u\{([0-9a-fA-F]{1,6})\}|\\u([0-9a-fA-F]{4})'),
      (m) =>
          _char(int.tryParse(m.group(1) ?? m.group(2)!, radix: 16)) ??
          m.group(0)!,
    )
    .replaceAll(r"\'", "'")
    .replaceAll(r'\"', '"');

/// [source] folded for the scan (see the header). Entities and escapes are
/// decoded first, so `can&#x27;t`, `can\'t` and `military\u2014grade` reach
/// the folds below as the characters they stand for (PR 6-6, security L1).
String foldForClaimScan(String source) =>
    decodeDartEscapes(decodeHtmlEntities(source))
        .toLowerCase()
        .replaceAll(RegExp('[​‌‍﻿]'), '')
        .replaceAll(RegExp('[‘’ʼ]'), "'")
        .replaceAll(RegExp('[“”]'), '"')
        .replaceAll(RegExp('[‐-―−]'), '-')
        // A literal's end, optional `+`, an optional raw prefix, the next
        // literal's start, with any quote types: 'a ' "b", 'a ' + r'b'.
        .replaceAll(RegExp(r"""['"]\s*\+?\s*r?['"]"""), '')
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

Map<String, String> _sources(String dir, bool Function(String path) keep) => {
  for (final f in Directory(dir).listSync(recursive: true))
    if (f is File && keep(f.path.replaceAll(r'\', '/')))
      f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
};

Map<String, String> _libSources() =>
    _sources('lib', (p) => p.endsWith('.dart') && !p.startsWith('lib/gen/'));

Map<String, String> _webSources() =>
    _sources('web', (p) => p.endsWith('.html') || p.endsWith('.json'));

void main() {
  test('lib/ never uses a banned claim phrase (Plan 6 §4.5)', () {
    final sources = _libSources();
    expect(sources.length, greaterThan(100), reason: 'the scan found lib/');
    expect(bannedClaimPhrases(sources), isEmpty);
  });

  test('web/ pages and JSON never use a banned claim phrase', () {
    final sources = _webSources();
    expect(
      sources.keys,
      containsAll(['web/privacy.html', 'web/manifest.json']),
      reason: 'the scan found web/',
    );
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
    Map<String, List<String>> scan(String text) =>
        bannedClaimPhrases({'a.dart': text});

    test('finds a phrase whatever its case', () {
      expect(scan("const x = 'Military-Grade';"), {
        'a.dart': ['military-grade'],
      });
    });

    test('reads a curly apostrophe as a straight one', () {
      expect(scan("const x = 'A stolen phone can’t read your messages';"), {
        'a.dart': ["a stolen phone can't read your messages"],
      });
    });

    test('folds Unicode dashes to a hyphen', () {
      for (final dash in ['‐', '‑', '‒', '–', '—', '―', '−']) {
        expect(scan("const x = 'military${dash}grade';"), {
          'a.dart': ['military-grade'],
        }, reason: 'U+${dash.codeUnitAt(0).toRadixString(16)}');
      }
    });

    test('strips zero-width characters', () {
      for (final zw in ['​', '‌', '‍', '﻿']) {
        expect(scan("const x = 'locks i${zw}t out';"), {
          'a.dart': ['locks it out'],
        }, reason: 'U+${zw.codeUnitAt(0).toRadixString(16)}');
      }
    });

    test('joins adjacent literals with the same quotes', () {
      expect(scan("const x = 'Nobody can read '\n    'your messages';"), {
        'a.dart': ['nobody can read your messages'],
      });
    });

    test('joins adjacent literals across quote types', () {
      expect(scan('const x = \'No one can read \' "your messages";'), {
        'a.dart': ['no one can read your messages'],
      });
    });

    test('joins across a raw prefix', () {
      expect(scan("const x = 'Cut off ' r'at once';"), {
        'a.dart': ['cut off at once'],
      });
    });

    test('joins across + concatenation', () {
      expect(scan("final x = 'Even we ' +\n    \"can't read\";"), {
        'a.dart': ["even we can't read"],
      });
      expect(scan("final x = 'Nobody, ' + r'not even';"), {
        'a.dart': ['nobody, not even'],
      });
    });

    test('a phrase split by a comment line break', () {
      expect(
        scan('/// Private on every\n/// device.'),
        isEmpty,
        reason: 'a comment break keeps its "///"; documented limit',
      );
      expect(scan('/* Private on every\n   device. */'), {
        'a.dart': ['private on every device'],
      });
    });

    test('scans HTML and JSON text the same way', () {
      expect(
        bannedClaimPhrases({
          'web/x.html': '<p>Nobody can read your messages</p>',
          'web/x.json': '{"d": "Military‑grade"}',
        }),
        {
          'web/x.html': ['nobody can read your messages'],
          'web/x.json': ['military-grade'],
        },
      );
    });

    test('decodes an HTML numeric apostrophe: can&#x27;t', () {
      const want = {
        'web/x.html': ["a stolen phone can't read your messages"],
      };
      for (final entity in ['&#x27;', '&#X27;', '&#39;', '&apos;', '&rsquo;']) {
        expect(
          bannedClaimPhrases({
            'web/x.html':
                '<p>A stolen phone can${entity}t read your messages</p>',
          }),
          want,
          reason: entity,
        );
      }
    });

    test('decodes &nbsp; &quot; and &amp; (last, once)', () {
      expect(
        bannedClaimPhrases({
          'web/x.html': '<p>Nobody&nbsp;can read your messages</p>',
        }),
        {
          'web/x.html': ['nobody can read your messages'],
        },
      );
      // &amp;#39; is the text "&#39;" on the page, not an apostrophe.
      expect(foldForClaimScan("can&amp;#39;t"), 'can&#39;t');
    });

    test(r"decodes a Dart escaped apostrophe: can\'t", () {
      expect(scan(r"const x = 'A stolen phone can\'t read your messages';"), {
        'a.dart': ["a stolen phone can't read your messages"],
      });
      expect(scan(r'const x = "Even we can\"t"; // no phrase'), isEmpty);
    });

    test('decodes an em dash however it is written', () {
      for (final dash in [
        'military—grade',
        r'military—grade',
        r'military\u{2014}grade',
        'military&mdash;grade',
        'military&#8212;grade',
        'military&#x2014;grade',
      ]) {
        expect(bannedClaimPhrases({'x': "'$dash'"}), {
          'x': ['military-grade'],
        }, reason: dash);
      }
    });

    test('decodes \\u escapes to letters and quotes', () {
      expect(scan(r"const x = 'Locks it out';"), {
        'a.dart': ['locks it out'],
      });
      expect(scan(r"const x = 'Even we can’t read';"), {
        'a.dart': ["even we can't read"],
      });
    });

    test('accepts the shipped claim words', () {
      expect(
        scan(
          "const h = 'We cannot read your messages.';\n"
          "const l = 'What this covers';",
        ),
        isEmpty,
      );
    });
  });
}
