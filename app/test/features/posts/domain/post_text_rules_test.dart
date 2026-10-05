import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/features/posts/domain/post_text_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shared fixture normalise rows (ADR-0010 D9/D21 G2/G4)', () {
    final json =
        jsonDecode(
              File('../testdata/post_text_grammar.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final rows = (json['normalise'] as List).cast<Map<String, dynamic>>();

    test('runs every row: stored text, or Post disabled on error', () {
      var ran = 0;
      for (final row in rows) {
        final raw = row['raw'] as String;
        final draft = analyzePostDraft(raw);
        final reason = 'row: ${jsonEncode(raw)}';
        if (row['error'] == true) {
          expect(draft.canPost, isFalse, reason: reason);
        } else {
          expect(draft.canPost, isTrue, reason: reason);
          expect(draft.text, row['stored'], reason: reason);
        }
        ran++;
      }
      expect(ran, rows.length);
      expect(ran, greaterThan(0));
    });
  });

  group('counter and limits', () {
    test('280 code points is allowed, 281 shows -1 and disables Post', () {
      final ok = analyzePostDraft('a' * 280);
      expect(ok.canPost, isTrue);
      expect(ok.remaining, 0);
      final over = analyzePostDraft('a' * 281);
      expect(over.canPost, isFalse);
      expect(over.problem, PostDraftProblem.tooLong);
      expect(over.remaining, -1);
    });

    test('decomposed input counts after NFC (e + U+0301 x 280 -> 0 left)', () {
      final draft = analyzePostDraft('e\u0301' * 280);
      expect(draft.codePoints, 280);
      expect(draft.remaining, 0);
      expect(draft.canPost, isTrue);
    });

    test('an emoji ZWJ sequence counts every code point', () {
      expect(analyzePostDraft('\u{1F469}\u200d\u{1F4BB}').codePoints, 3);
    });

    test('11 lines disables Post, 10 is allowed', () {
      expect(analyzePostDraft(List.filled(10, 'x').join('\n')).canPost, isTrue);
      final eleven = analyzePostDraft(List.filled(11, 'x').join('\n'));
      expect(eleven.canPost, isFalse);
      expect(eleven.problem, PostDraftProblem.tooManyLines);
    });

    test('a post ending in the England flag counts every code point', () {
      const flag =
          '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}';
      final draft = analyzePostDraft('hi $flag');
      expect(draft.codePoints, 3 + 7);
      expect(draft.canPost, isTrue);
      expect(draft.text.endsWith(flag), isTrue);
    });

    test('empty and whitespace-only drafts are disabled', () {
      expect(analyzePostDraft('').problem, PostDraftProblem.empty);
      expect(analyzePostDraft(' \n\t ').problem, PostDraftProblem.empty);
    });
  });
}
