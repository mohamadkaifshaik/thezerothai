import 'dart:convert';
import 'dart:io';

import 'package:dzeroth/features/posts/domain/post_text_parser.dart';
import 'package:dzeroth/gen/dzeroth/posts/v1/posts.pb.dart' as pb;
import 'package:flutter_test/flutter_test.dart';

pb.Mention _m(String handle, [String userId = 'u-bob']) =>
    pb.Mention(handle: handle, userId: userId);

List<PostSpan> _tappable(List<PostSpan> spans) =>
    spans.where((s) => s.isTappable).toList();

void main() {
  test('spans always rebuild the original text', () {
    const text = 'hi @bob see https://x.y/p?q=1, #go! (https://a.b) end';
    final spans = parsePostText(text, [_m('bob')]);
    expect(spans.map((s) => s.text).join(), text);
  });

  test('"hi @bob see https://x.y #go" has exactly 3 tappable spans', () {
    final spans = parsePostText('hi @bob see https://x.y #go', [_m('bob')]);
    final tappable = _tappable(spans);
    expect(tappable.map((s) => s.kind), [
      PostSpanKind.mention,
      PostSpanKind.link,
      PostSpanKind.hashtag,
    ]);
    expect(tappable[1].url, Uri.parse('https://x.y'));
  });

  group('mentions', () {
    test('match case-insensitively and carry the user_id', () {
      final spans = parsePostText('@Bob', [_m('bob', 'u42')]);
      expect(spans, hasLength(1));
      expect(spans.single.kind, PostSpanKind.mention);
      expect(spans.single.text, '@Bob');
      expect(spans.single.userId, 'u42');
      expect(spans.single.handle, 'bob');
    });

    test('an upper-case mentions entry still matches', () {
      final spans = parsePostText('@bob', [_m('BOB', 'u1')]);
      expect(spans.single.kind, PostSpanKind.mention);
    });

    test('every returned mention renders alike: no block oracle (M2)', () {
      // The server returns a mention for a user who blocked the author just
      // like any other (it no longer drops them), so the client must not
      // render anything different. Both are tappable mention spans.
      final blocker = parsePostText('hi @bob', [_m('bob', 'u-blocker')]);
      final other = parsePostText('hi @bob', [_m('bob', 'u-other')]);
      expect(blocker.map((s) => s.kind), other.map((s) => s.kind));
      expect(blocker.map((s) => s.text), other.map((s) => s.text));
      expect(_tappable(blocker).single.kind, PostSpanKind.mention);
    });

    test('without a mentions entry it is plain text', () {
      final spans = parsePostText('@carol', [_m('bob')]);
      expect(spans.single.kind, PostSpanKind.plain);
      expect(parsePostText('@bob', const []).single.kind, PostSpanKind.plain);
    });

    test('a mention may follow punctuation and end the text', () {
      final spans = parsePostText('(@bob), @bob.', [_m('bob')]);
      expect(_tappable(spans), hasLength(2));
    });
  });

  group('links', () {
    test('javascript: is plain text', () {
      final spans = parsePostText('javascript:alert(1)', const []);
      expect(spans.single.kind, PostSpanKind.plain);
    });

    test('only http(s) is linkified', () {
      for (final text in [
        'ftp://x.y/file',
        'data:text/html;base64,AAAA',
        'file:///etc/passwd',
        'www.example.com',
        'https://',
      ]) {
        expect(_tappable(parsePostText(text, const [])), isEmpty, reason: text);
      }
    });

    test('scheme is case-insensitive and the text is preserved', () {
      final spans = parsePostText('HTTPS://Example.com/A', const []);
      expect(spans.single.kind, PostSpanKind.link);
      expect(spans.single.text, 'HTTPS://Example.com/A');
      expect(spans.single.url!.scheme, 'https');
    });

    test('trailing punctuation is not part of the link', () {
      final spans = parsePostText('see https://x.y/a.', const []);
      expect(spans[1].text, 'https://x.y/a');
      expect(spans.last.text, '.');
    });

    test('@ and # inside a link stay part of the link', () {
      final spans = parsePostText('https://x.y/@bob#go', [_m('bob')]);
      expect(spans, hasLength(1));
      expect(spans.single.kind, PostSpanKind.link);
    });
  });

  group('hashtags', () {
    test('a plain hashtag is tappable', () {
      expect(parsePostText('#go', const []).single.kind, PostSpanKind.hashtag);
    });
  });

  test('empty text yields no spans', () {
    expect(parsePostText('', const []), isEmpty);
  });

  group('D7/D8 edge cases', () {
    test('mention grammar rejects look-alikes', () {
      final m = [_m('bob'), _m('al'), _m('alice')];
      for (final text in ['@@bob', '@bob@host', '@al-ice', 'x@bob', '_@bob']) {
        expect(_tappable(parsePostText(text, m)), isEmpty, reason: text);
      }
      expect(_tappable(parsePostText('(@bob)', m)), hasLength(1));
      expect(_tappable(parsePostText('@alice-x', m)), hasLength(1));
    });

    test('51-rune hashtag is rejected, 50 is accepted', () {
      expect(_tappable(parsePostText('#${'a' * 50}', const [])), hasLength(1));
      expect(_tappable(parsePostText('#${'a' * 51}', const [])), isEmpty);
    });

    test('an astral-letter run past 50 runes is rejected whole', () {
      // U+1D400 MATHEMATICAL BOLD CAPITAL A is a letter outside the BMP.
      final astral = String.fromCharCode(0x1D400);
      expect(
        _tappable(parsePostText('#${astral * 50}', const [])),
        hasLength(1),
      );
      expect(_tappable(parsePostText('#${astral * 51}', const [])), isEmpty);
    });

    test('Devanagari digits alone are not a hashtag, a Devanagari word is', () {
      expect(
        _tappable(parsePostText('#\u0967\u0968\u0969', const [])),
        isEmpty,
      );
      expect(
        _tappable(parsePostText('#\u092d\u093e\u0930\u0924', const [])),
        hasLength(1),
      );
    });
  });

  group('deceptive links are plain text', () {
    test('userinfo, IDN/homograph hosts and bidi controls', () {
      for (final text in [
        'https://google.com@evil.com/x',
        'https://user:pw@example.com',
        'https://\u0430pple.com/login', // Cyrillic a
        'https://exa%6Dple.com',
        'https://\u202eevil.com',
        'https://example.com/\u202etxt.exe',
        'https://[::1]/x',
        // A bidi override BEFORE the link reorders how it is displayed.
        '\u202ehttps://evil.com/?moc.elgoog//:sptth',
        'look \u2067 https://evil.com/x',
        'arabic mark \u061c https://evil.com/x',
      ]) {
        expect(_tappable(parsePostText(text, const [])), isEmpty, reason: text);
      }
    });

    test('ordinary links with ports, paths and unicode paths still work', () {
      for (final text in [
        'https://example.com:8080/a?b=c#d',
        'http://sub.example.co.uk/path/\u00fc',
        'https://1.2.3.4/x',
      ]) {
        final spans = parsePostText(text, const []);
        expect(spans.single.kind, PostSpanKind.link, reason: text);
      }
    });

    test('a balanced closing bracket stays, an unbalanced one is trimmed', () {
      final wiki = parsePostText(
        'https://en.wikipedia.org/wiki/Foo_(bar)',
        const [],
      );
      expect(wiki.single.text, 'https://en.wikipedia.org/wiki/Foo_(bar)');
      final paren = parsePostText('(see https://x.y/a)', const []);
      expect(paren[1].text, 'https://x.y/a');
      expect(paren.last.text, ')');
    });
  });

  group('D21 G1: exclusion runs over every syntactic URL span', () {
    test('an unsafe span is plain text with nothing tappable inside', () {
      final spans = parsePostText('https://ex.café/?r=@bob', [_m('bob')]);
      expect(spans, hasLength(1));
      expect(spans.single.kind, PostSpanKind.plain);
    });

    test('userinfo span is plain, only the later mention is tappable', () {
      final spans = parsePostText('https://google.com@evil.com/x @bob', [
        _m('bob'),
      ]);
      expect(_tappable(spans).map((s) => s.text), ['@bob']);
    });

    test('a bidi control keeps span detection but drops every link', () {
      final spans = parsePostText(
        '؜ https://ex.com/?r=@bob',
        [_m('bob')],
      );
      expect(_tappable(spans), isEmpty);
    });
  });

  group('shared fixture testdata/post_text_grammar.json', () {
    // The repo-root fixture is the single source of grammar rows (ADR-0010
    // D21 G1); tests run from app/.
    final file = File('../testdata/post_text_grammar.json');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final rows = (json['grammar'] as List).cast<Map<String, dynamic>>();

    List<String> strings(Object? v) => (v as List).cast<String>();

    test('runs every grammar row', () {
      var ran = 0;
      for (final row in rows) {
        final text = row['text'] as String;
        final wantMentions = strings(row['mentions']);
        final wantHashtags = strings(row['hashtags']);
        final wantLinks = strings(row['tappable_links']);

        // Feed the server's mentions back as resolved mentions.
        final mentions = [
          for (final h in wantMentions) _m(h, 'uid-$h'),
        ];
        final spans = parsePostText(text, mentions);
        final reason = 'row: ${jsonEncode(text)}';

        expect(spans.map((s) => s.text).join(), text, reason: reason);

        // The server dedupes and caps at 10; the client shows every span.
        List<String> stored(Iterable<String> all) =>
            all.toSet().take(10).toList();
        expect(
          stored(
            spans
                .where((s) => s.kind == PostSpanKind.mention)
                .map((s) => s.text.substring(1).toLowerCase()),
          ),
          wantMentions,
          reason: reason,
        );
        expect(
          stored(
            spans
                .where((s) => s.kind == PostSpanKind.hashtag)
                .map((s) => s.text.substring(1).toLowerCase()),
          ),
          wantHashtags,
          reason: reason,
        );
        expect(
          spans
              .where((s) => s.kind == PostSpanKind.link)
              .map((s) => s.text)
              .toList(),
          wantLinks,
          reason: reason,
        );
        ran++;
      }
      expect(ran, rows.length);
      expect(ran, greaterThan(0));
    });
  });
}
