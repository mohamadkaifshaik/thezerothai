import 'package:dzeroth/shared/format/profile_website.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('punycodeEncode (RFC 3492 vectors)', () {
    test('known labels', () {
      expect(punycodeEncode('bücher'), 'bcher-kva');
      expect(punycodeEncode('münchen'), 'mnchen-3ya');
      expect(punycodeEncode('日本語'), 'wgv71a119e');
      expect(punycodeEncode('例え'), 'r8jz45g');
      expect(punycodeEncode('пример'), 'e1afmkfd');
      expect(punycodeEncode('ليهمابتكلموشعربي؟'), 'egbpdaj6bu4bxfgehfvwxn');
      expect(punycodeEncode('3年B組金八先生'), '3B-ww4c5e180e575a65lsy2b');
    });
  });

  group('parseProfileWebsite', () {
    test('plain https and http', () {
      final a = parseProfileWebsite('https://example.com/a?b=1#c')!;
      expect(a.host, 'example.com');
      expect(a.uri.toString(), 'https://example.com/a?b=1#c');
      expect(parseProfileWebsite('http://example.com')!.uri.scheme, 'http');
    });

    test(
      'the scheme and host are lower-cased, a port is kept off the host',
      () {
        final w = parseProfileWebsite('HTTPS://Example.COM:8443/Path')!;
        expect(w.host, 'example.com');
        expect(w.uri.toString(), 'https://example.com:8443/Path');
      },
    );

    test('a non-ASCII host is shown and opened as punycode', () {
      final w = parseProfileWebsite('https://bücher.de/straße')!;
      expect(w.host, 'xn--bcher-kva.de');
      expect(w.uri.host, 'xn--bcher-kva.de');
      expect(w.uri.path, '/stra%C3%9Fe');
      expect(
        parseProfileWebsite('https://MÜNCHEN.example')!.host,
        'xn--mnchen-3ya.example',
      );
      expect(parseProfileWebsite('https://日本語.jp')!.host, 'xn--wgv71a119e.jp');
    });

    test('a trailing root dot is dropped', () {
      expect(parseProfileWebsite('https://example.com./')!.host, 'example.com');
    });

    test('surrounding whitespace is trimmed', () {
      expect(
        parseProfileWebsite('  https://example.com  ')!.host,
        'example.com',
      );
    });

    test('anything that is not a plain http(s) URL is left out', () {
      for (final bad in [
        '',
        '   ',
        'example.com',
        'javascript:alert(1)',
        'ftp://example.com',
        'file:///etc/passwd',
        'mailto:a@example.com',
        'https://',
        'https:///path',
        'https://user@example.com',
        'https://user:pw@example.com',
        'https://[::1]/',
        'https://exa mple.com',
        'https://example.com/a b',
        'https://example.com\u202E/x',
        'https://example.com\u2066/x',
        'https://example.com\u200F/x',
        'https://example.com\u00A0/x',
        'https://example.com\u2028/x',
        'https://example.com\u0007/x',
        'https://example.com\n/x',
        'https://exa%6Dple.com',
        'https://.example.com',
        'https://a..b',
        'https://example.com:0',
        'https://example.com:70000',
        'https://example.com:abc',
        'https://exa!mple.com',
      ]) {
        expect(parseProfileWebsite(bad), isNull, reason: bad);
      }
    });

    test('a label over 63 characters is left out', () {
      expect(parseProfileWebsite('https://${'a' * 64}.com'), isNull);
    });
  });
}
