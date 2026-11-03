import 'package:dzeroth/features/communities/domain/community_text_rules.dart';
import 'package:dzeroth/features/lists/domain/list_text_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Description and rule text keep `identity.BioText`'s rule (LF kept,
/// no invisible format character or filler); names and titles stay one line.
void main() {
  const refused = {
    'zero width space': 'a\u200Bb',
    'word joiner': 'a\u2060b',
    'interior BOM': 'a\uFEFFb',
    'Hangul filler': 'a\u3164b',
    'joiner at the end': 'a\u200D',
    'lone tag': 'a\u{E0067}b',
    'soft hyphen': 'a\u00ADb',
    'CR': 'a\rb',
  };
  for (final e in refused.entries) {
    test('description and rule text refuse ${e.key}', () {
      expect(
        communityDescriptionIssue(e.value),
        CommunityTextIssue.notPlainText,
      );
      expect(communityRuleTextIssue(e.value), CommunityTextIssue.notPlainText);
    });
  }

  test('sequences, line breaks and an empty value stay valid', () {
    const text =
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467} \u0915\u094D\u200D\u0937\nline two';
    expect(communityDescriptionIssue(text), isNull);
    expect(communityRuleTextIssue(text), isNull);
    expect(communityDescriptionIssue(''), isNull);
    expect(communityDescriptionIssue('a\u200D\nb'), isNotNull);
  });

  test('the length limit still wins', () {
    expect(communityDescriptionIssue('x' * 1000), CommunityTextIssue.tooLong);
  });

  test('list description refuses the same characters (W5-55)', () {
    for (final v in refused.values) {
      expect(listDescriptionIssue(v), isNotNull, reason: v.runes.toString());
    }
  });
}
