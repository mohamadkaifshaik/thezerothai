import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dzeroth/features/search/domain/search_feature_flags.dart';
import 'package:dzeroth/features/search/domain/search_query.dart';

SearchQuery _p(String s) => SearchQuery.parse(s);

void main() {
  test('flag names match the server flags', () {
    expect(kFeatureSearch, 'search');
    expect(kFeatureTrends, 'trends');
  });

  group('acceptance', () {
    test('#Launch is a tag with body launch', () {
      final q = _p('#Launch');
      expect(q.kind, SearchQueryKind.tag);
      expect(q.body, 'launch');
      expect(q.tagBody, 'launch');
      expect(q.postsRequest, '#launch');
      expect(q.canonical, '#launch');
      expect(q.isValid, isTrue);
      expect(q.canSearchPeople, isFalse);
    });

    test('@a is too short and makes no call', () {
      final q = _p('@a');
      expect(q.kind, SearchQueryKind.handle);
      expect(q.issue, SearchQueryIssue.tooShort);
      expect(q.peopleTooShort, isTrue);
      expect(q.canSearchPeople, isFalse);
      expect(q.canSearchPosts, isFalse);
    });

    test('a one-character word: people too short, tag a still searched', () {
      final q = _p('a');
      expect(q.isValid, isTrue);
      expect(q.peopleTooShort, isTrue);
      expect(q.canSearchPeople, isFalse);
      expect(q.tagBody, 'a');
      expect(q.postsRequest, '#a');
      final tag = _p('#a');
      expect(tag.tagBody, 'a');
      expect(tag.peopleTooShort, isFalse);
    });

    test('a 50-code-point tag with its # is valid (the sigil is free)', () {
      expect(_p('#${'a' * 50}').tagBody, 'a' * 50);
      expect(_p('#${'a' * 51}').issue, SearchQueryIssue.tooLong);
    });
  });

  group('handle', () {
    test('2 to 15 characters of [a-z0-9_], lower-cased', () {
      final q = _p('  @Bo_9 ');
      expect(q.kind, SearchQueryKind.handle);
      expect(q.peopleQuery, 'bo_9');
      expect(q.canonical, '@bo_9');
      expect(q.canSearchPosts, isFalse);
      expect(_p('@ab').isValid, isTrue);
      expect(_p('@${'a' * 15}').isValid, isTrue);
    });

    test('bare @ is empty; a handle over 15 characters is unsupported', () {
      expect(_p('@').issue, SearchQueryIssue.empty);
      expect(_p('@${'a' * 16}').issue, SearchQueryIssue.unsupported);
    });

    test('characters outside the charset are unsupported (server: empty)', () {
      expect(_p('@bo-b').issue, SearchQueryIssue.unsupported);
      expect(_p('@bob smith').issue, SearchQueryIssue.unsupported);
      expect(_p('@bob').canSearchPosts, isFalse);
    });

    test('only one sigil is removed', () {
      expect(_p('@@bob').issue, SearchQueryIssue.unsupported);
      expect(_p('@#bob').issue, SearchQueryIssue.unsupported);
      expect(_p('##go').issue, SearchQueryIssue.unsupported);
    });
  });

  group('tag', () {
    test('a one-character tag is valid, # alone is not', () {
      expect(_p('#a').tagBody, 'a');
      expect(_p('#').issue, SearchQueryIssue.empty);
    });

    test('digits only, spaces and nested # are not a tag body', () {
      expect(_p('#123').issue, SearchQueryIssue.unsupported);
      expect(_p('#go lang').issue, SearchQueryIssue.unsupported);
      expect(_p('#a#b').issue, SearchQueryIssue.unsupported);
      expect(_p('#go.').issue, SearchQueryIssue.unsupported);
      expect(_p('#go!').issue, SearchQueryIssue.unsupported);
    });

    test('non-ASCII letters are fine', () {
      expect(_p('#Ünïcode').tagBody, 'ünïcode');
      expect(_p('#नमस्ते').isValid, isTrue);
    });

    test('NFC is applied before the grammar', () {
      final decomposed = 'cafe${String.fromCharCode(0x301)}';
      final composed = 'caf${String.fromCharCode(0xE9)}';
      expect(decomposed, isNot(composed));
      expect(_p('#$decomposed').tagBody, composed);
    });
  });

  group('plain word (F4)', () {
    test('a handle-shaped word searches people and the tag', () {
      final q = _p('Launch');
      expect(q.kind, SearchQueryKind.word);
      expect(q.peopleQuery, 'launch');
      expect(q.tagBody, 'launch');
      expect(q.canonical, 'launch');
    });

    test('a long or non-ASCII word can only be a tag', () {
      final long = _p('a' * 16);
      expect(long.canSearchPeople, isFalse);
      expect(long.canSearchPosts, isTrue);
      final uni = _p('café');
      expect(uni.canSearchPeople, isFalse);
      expect(uni.tagBody, 'café');
    });

    test('digits only can still be a people prefix, not a tag', () {
      final q = _p('2024');
      expect(q.peopleQuery, '2024');
      expect(q.canSearchPosts, isFalse);
      expect(q.isValid, isTrue);
    });

    test('one digit is too short (no tag to fall back on)', () {
      expect(_p('7').issue, SearchQueryIssue.tooShort);
    });

    test('empty and blank are empty', () {
      expect(_p('').issue, SearchQueryIssue.empty);
      expect(_p('   ').issue, SearchQueryIssue.empty);
    });

    test('a phrase is unsupported (no full-text search), no call', () {
      final q = _p('hello world');
      expect(q.issue, SearchQueryIssue.unsupported);
      expect(q.canSearchPeople || q.canSearchPosts, isFalse);
      expect(_p('what?').issue, SearchQueryIssue.unsupported);
    });
  });

  group('limits and forbidden characters', () {
    test('50 code points pass, 51 are too long (the sigil is not counted)', () {
      expect(_p('a' * 50).isValid, isTrue);
      expect(_p('a' * 51).issue, SearchQueryIssue.tooLong);
      expect(_p('#${'a' * 50}').isValid, isTrue);
      expect(_p('@${'a' * 50}').issue, SearchQueryIssue.unsupported);
      expect(_p('@${'a' * 51}').issue, SearchQueryIssue.tooLong);
    });

    test('astral characters count as one code point', () {
      final astral = String.fromCharCode(0x1D4D0) * 50;
      expect(astral.runes.length, 50);
      expect(_p(astral).issue, isNot(SearchQueryIssue.tooLong));
    });

    test('control and bidi characters are invalid', () {
      String c(int r) => String.fromCharCode(r);
      expect(_p('go${c(0)}od').issue, SearchQueryIssue.invalid);
      expect(_p('go${c(10)}od').issue, SearchQueryIssue.invalid);
      expect(_p('#go${c(0x202E)}od').issue, SearchQueryIssue.invalid);
      expect(_p('@go${c(0x200F)}od').issue, SearchQueryIssue.invalid);
      expect(_p('${c(0x2066)}go').issue, SearchQueryIssue.invalid);
    });

    test('equal queries compare equal', () {
      expect(_p('#Go'), _p(' #go '));
      expect(_p('#Go').hashCode, _p('#go').hashCode);
      expect(_p('#go'), isNot(_p('go')));
    });
  });

  // The same fixture the post parser and the Go side run: a `#tag` query is
  // valid exactly when the post grammar reads `#tag` as one hashtag.
  group('shared post-text grammar fixtures', () {
    final file = File('../testdata/post_text_grammar.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final rows = (json['grammar'] as List).cast<Map<String, dynamic>>();

    test('every fixture hashtag is a valid tag query', () {
      var tags = 0;
      for (final row in rows) {
        for (final tag in (row['hashtags'] as List).cast<String>()) {
          tags++;
          final q = _p('#$tag');
          expect(q.kind, SearchQueryKind.tag, reason: tag);
          expect(q.tagBody, tag, reason: tag);
          // Without the marker the word is a tag too (F4).
          expect(_p(tag).tagBody ?? tag, tag, reason: tag);
        }
      }
      expect(tags, greaterThan(0));
    });

    test('a #token fixture row is a tag query iff it is its own hashtag', () {
      var checked = 0;
      for (final row in rows) {
        final text = row['text'] as String;
        if (!text.startsWith('#') || text.contains(RegExp(r'\s'))) continue;
        if (text.runes.length > SearchQuery.maxCodePoints) continue;
        final tags = (row['hashtags'] as List).cast<String>();
        final alone =
            tags.length == 1 && '#${tags.single}' == text.toLowerCase();
        checked++;
        expect(
          _p(text).tagBody != null,
          alone,
          reason: 'row: ${jsonEncode(text)}',
        );
      }
      expect(checked, greaterThan(0));
    });
  });

  group('shared fixture testdata/search_query_grammar.json', () {
    final cases =
        (jsonDecode(
              File('../testdata/search_query_grammar.json').readAsStringSync(),
            ) as Map<String, dynamic>)['cases']
            as List;

    test('row count (keep in step with the Go test)', () {
      expect(cases.length, 38);
    });

    for (final raw in cases) {
      final row = raw as Map<String, dynamic>;
      final query = row['query'] as String;
      test('${row['note']}', () {
        final q = _p(query);
        final invalid = const {
          SearchQueryIssue.empty,
          SearchQueryIssue.tooLong,
          SearchQueryIssue.invalid,
        }.contains(q.issue);
        final people = row['people'] as Map<String, dynamic>;
        final posts = row['posts'] as Map<String, dynamic>;
        final gotPeople = invalid
            ? 'invalid'
            : q.peopleQuery != null
            ? 'prefix'
            : q.peopleTooShort
            ? 'too_short'
            : 'unsupported';
        final gotPosts = invalid
            ? 'invalid'
            : q.tagBody != null
            ? 'tag'
            : 'unsupported';
        expect(gotPeople, people['result'], reason: jsonEncode(query));
        expect(q.peopleQuery ?? '', people['prefix'] ?? '');
        expect(gotPosts, posts['result'], reason: jsonEncode(query));
        expect(q.tagBody ?? '', posts['tag'] ?? '');
      });
    }
  });
}
