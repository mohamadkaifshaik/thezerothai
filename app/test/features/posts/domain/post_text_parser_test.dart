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

    test('without a mentions entry it is plain text', () {
      final spans = parsePostText('@carol', [_m('bob')]);
      expect(spans.single.kind, PostSpanKind.plain);
      expect(parsePostText('@bob', const []).single.kind, PostSpanKind.plain);
    });

    test('an email address is not a mention', () {
      final spans = parsePostText('mail a@bob.com', [_m('bob')]);
      expect(_tappable(spans), isEmpty);
    });

    test('a handle longer than 15 is not a mention', () {
      final spans = parsePostText('@abcdefghijklmnop', [_m('abcdefghijklmno')]);
      expect(_tappable(spans), isEmpty);
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
    test('basic, unicode and invalid forms', () {
      expect(parsePostText('#go', const []).single.kind, PostSpanKind.hashtag);
      expect(parsePostText('#भारत', const []).single.text, '#भारत');
      expect(_tappable(parsePostText('#123', const [])), isEmpty);
      expect(_tappable(parsePostText('a#b', const [])), isEmpty);
      expect(_tappable(parsePostText('#', const [])), isEmpty);
      expect(_tappable(parsePostText('#${'a' * 51}', const [])), isEmpty);
    });
  });

  test('empty text yields no spans', () {
    expect(parsePostText('', const []), isEmpty);
  });
}
