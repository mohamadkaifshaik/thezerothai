import 'package:dzeroth/features/profile/domain/profile_extras_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `backend/internal/identity/validate.go` (ADR-0024 D2). Strings with
/// invisible characters are built from code points so no raw control or bidi
/// character sits in this file (a Trojan Source risk).
String cp(List<int> codePoints) => String.fromCharCodes(codePoints);

void main() {
  group('location', () {
    test('empty and plain text are fine', () {
      expect(locationIssue(''), isNull);
      expect(locationIssue('   '), isNull);
      expect(locationIssue('Mumbai, India'), isNull);
    });

    test('30 code points fit, 31 do not (trimmed first)', () {
      expect(locationIssue('a' * 30), isNull);
      expect(locationIssue('  ${'a' * 30}  '), isNull);
      expect(locationIssue('a' * 31), LocationIssue.tooLong);
      expect(locationRemaining('a' * 31), -1);
      expect(locationRemaining(''), 30);
    });

    test('counts code points, not UTF-16 units', () {
      final emoji = cp([0x1F600]); // 2 UTF-16 units, 1 code point
      expect(emoji.length, 2);
      expect(locationIssue(emoji * 30), isNull);
      expect(locationRemaining(emoji * 30), 0);
      expect(locationIssue(emoji * 31), LocationIssue.tooLong);
    });

    test('counts after NFC: e + combining acute is one code point', () {
      final decomposed = cp([0x65, 0x301]);
      expect(decomposed.runes.length, 2);
      expect(locationRemaining(decomposed * 30), 0);
      expect(locationIssue(decomposed * 30), isNull);
      expect(normalizeProfileLocation(decomposed), cp([0xE9]));
    });

    test('control characters and line breaks are refused', () {
      expect(
        locationIssue('Mum${cp([0x0A])}bai'),
        LocationIssue.forbiddenCharacter,
      );
      expect(
        locationIssue('a${cp([0x00])}b'),
        LocationIssue.forbiddenCharacter,
      );
      expect(
        locationIssue('a${cp([0x7F])}b'),
        LocationIssue.forbiddenCharacter,
      );
      expect(
        locationIssue('a${cp([0x85])}b'),
        LocationIssue.forbiddenCharacter,
      );
    });

    test('bidi formatting controls are refused', () {
      for (final bidi in [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, //
        0x2066, 0x2067, 0x2068, 0x2069,
      ]) {
        expect(
          locationIssue('a${cp([bidi])}b'),
          LocationIssue.forbiddenCharacter,
          reason: bidi.toRadixString(16),
        );
      }
    });
  });

  group('website', () {
    test('empty is a valid clear', () {
      expect(websiteIssue(''), isNull);
      expect(websiteIssue('   '), isNull);
    });

    test('http and https addresses with a host are fine', () {
      expect(websiteIssue('https://example.com'), isNull);
      expect(websiteIssue('http://example.com/a/b?x=1#y'), isNull);
      expect(websiteIssue('  HTTPS://Example.com  '), isNull);
      expect(websiteIssue('https://example.com:8443/'), isNull);
    });

    test('anything else is invalid', () {
      expect(websiteIssue('example.com'), WebsiteIssue.invalid);
      expect(websiteIssue('ftp://example.com'), WebsiteIssue.invalid);
      expect(websiteIssue('javascript:alert(1)'), WebsiteIssue.invalid);
      expect(websiteIssue('https://'), WebsiteIssue.invalid);
      expect(websiteIssue('https://user@example.com'), WebsiteIssue.invalid);
      expect(websiteIssue('https://exa mple.com'), WebsiteIssue.invalid);
      expect(
        websiteIssue('https://example.com/${cp([0x0A])}x'),
        WebsiteIssue.invalid,
      );
      expect(
        websiteIssue('https://example.com/${cp([0x202E])}'),
        WebsiteIssue.invalid,
      );
    });

    test('100 characters fit, 101 do not', () {
      const base = 'https://example.com/';
      expect(websiteIssue(base + 'a' * (100 - base.length)), isNull);
      expect(
        websiteIssue(base + 'a' * (101 - base.length)),
        WebsiteIssue.tooLong,
      );
      expect(websiteRemaining(base + 'a' * (101 - base.length)), -1);
      expect(websiteRemaining(''), 100);
    });

    test('the host preview is the ASCII host the profile will show', () {
      expect(websiteHostPreview('https://Example.com/path'), 'example.com');
      expect(
        websiteHostPreview('https://b${cp([0xFC])}cher.de'),
        'xn--bcher-kva.de',
      );
      expect(websiteHostPreview(''), isNull);
      expect(websiteHostPreview('nope'), isNull);
    });

    test('what is sent is the trimmed text', () {
      expect(normalizeProfileWebsite('  https://a.co  '), 'https://a.co');
    });
  });

  group('location line separators (W3-22 L-2a)', () {
    test('U+2028 and U+2029 are refused, a trailing one is trimmed', () {
      for (final sep in [0x2028, 0x2029]) {
        expect(
          locationIssue('a${cp([sep])}b'),
          LocationIssue.forbiddenCharacter,
          reason: sep.toRadixString(16),
        );
        expect(locationIssue('ab${cp([sep])}'), isNull);
      }
    });
  });

  group('display name (W3-22 L-2c)', () {
    test('1 to 50 code points after trim and NFC', () {
      expect(displayNameIssue(''), DisplayNameIssue.empty);
      expect(displayNameIssue('   '), DisplayNameIssue.empty);
      expect(displayNameIssue('a'), isNull);
      expect(displayNameIssue('a' * 50), isNull);
      expect(displayNameIssue('a' * 51), DisplayNameIssue.tooLong);
      // 50 decomposed e + acute are 50 code points once composed.
      expect(displayNameIssue(cp([0x65, 0x301]) * 50), isNull);
      expect(profileNameRemaining(cp([0x65, 0x301]) * 50), 0);
      expect(profileNameRemaining('a' * 51), -1);
    });

    test('control, line separator and bidi characters are refused', () {
      for (final bad in [
        0x0A, 0x0D, 0x09, 0x00, 0x7F, 0x85, 0x2028, 0x2029, //
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
      ]) {
        expect(
          displayNameIssue('a${cp([bad])}b'),
          DisplayNameIssue.forbiddenCharacter,
          reason: bad.toRadixString(16),
        );
      }
    });

    test('what is sent is trimmed, then NFC', () {
      expect(normalizeDisplayName('  ${cp([0x65, 0x301])} '), cp([0xE9]));
    });
  });

  group('bio (W3-22 L-2c)', () {
    test('0 to 160 code points after trim and NFC, empty is a clear', () {
      expect(bioIssue(''), isNull);
      expect(bioIssue('b' * 160), isNull);
      expect(bioIssue('b' * 161), BioIssue.tooLong);
      expect(profileBioRemaining('b' * 161), -1);
      expect(profileBioRemaining(''), 160);
    });

    test('LF is kept, every other control character is refused', () {
      expect(bioIssue('a${cp([0x0A])}b'), isNull);
      for (final bad in [0x0D, 0x09, 0x00, 0x7F, 0x85, 0x2028, 0x2029]) {
        expect(
          bioIssue('a${cp([bad])}b'),
          BioIssue.forbiddenCharacter,
          reason: bad.toRadixString(16),
        );
      }
      // CR is refused, not folded.
      expect(bioIssue('a${cp([0x0D, 0x0A])}b'), BioIssue.forbiddenCharacter);
    });

    test('bidi formatting controls are refused', () {
      for (final bidi in [0x202A, 0x202E, 0x2066, 0x2069]) {
        expect(
          bioIssue('a${cp([bidi])}b'),
          BioIssue.forbiddenCharacter,
          reason: bidi.toRadixString(16),
        );
      }
    });
  });

  group('website as stored', () {
    test('only the scheme is lower-cased, as the server stores it', () {
      expect(
        normalizeProfileWebsite('  HTTPS://Example.COM/Path  '),
        'https://Example.COM/Path',
      );
      expect(normalizeProfileWebsite('HtTp://a.co'), 'http://a.co');
      expect(normalizeProfileWebsite('FTP://A.co'), 'FTP://A.co');
    });

    test('a host on the viewer\'s own network is invalid (L-3)', () {
      expect(websiteIssue('http://192.168.1.1/'), WebsiteIssue.invalid);
      expect(websiteIssue('http://localhost:3000'), WebsiteIssue.invalid);
      expect(websiteIssue('https://printer.local'), WebsiteIssue.invalid);
      expect(websiteIssue('https://example.com:+80'), WebsiteIssue.invalid);
      expect(websiteHostPreview('http://192.168.1.1/'), isNull);
    });
  });
}
