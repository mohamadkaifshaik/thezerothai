import 'dart:math';

import 'package:dzeroth/core/telemetry/crash_scrubber.dart';
import 'package:flutter_test/flutter_test.dart';

final RegExp _sixDigits = RegExp(r'\d{6,}');
final RegExp _longToken = RegExp(r'[A-Za-z0-9]{28,}');

void _expectSafe(String out) {
  expect(out.length, lessThanOrEqualTo(CrashScrubber.maxLength));
  expect(out, isNot(contains('@')));
  expect(_sixDigits.hasMatch(out), isFalse, reason: out);
  expect(_longToken.hasMatch(out), isFalse, reason: out);
}

void main() {
  group('CrashScrubber.scrub', () {
    test('replaces each shape', () {
      expect(CrashScrubber.scrub('id 123456 and 12345'), 'id <n> and 12345');
      expect(
        CrashScrubber.scrub('mail me a.b@example.com now'),
        'mail me <email> now',
      );
      expect(CrashScrubber.scrub('hi @alice_1!'), 'hi <handle>!');
      expect(
        CrashScrubber.scrub('see https://x.test/u/alice?q=1 ok'),
        'see <url> ok',
      );
      expect(CrashScrubber.scrub('uid ${'a' * 28} end'), 'uid <token> end');
    });

    test('keeps ordinary code strings', () {
      const s = "type 'String' is not a subtype of type 'int'";
      expect(CrashScrubber.scrub(s), s);
    });

    test('cuts at 200 characters', () {
      expect(CrashScrubber.scrub('x ' * 500).length, 200);
    });

    test('does not leave half a surrogate pair at the cut', () {
      final out = CrashScrubber.scrub('${'ab ' * 66}a\u{1F600}');
      expect(out, '${'ab ' * 66}a');
    });

    test('property: random strings with embedded ids, emails, handles', () {
      final rnd = Random(20261101);
      final runes = 'abcXYZ019 .,:;-_/@#<>\né\u{1F600}'.runes.toList();
      String noise(int n) => String.fromCharCodes([
        for (var i = 0; i < n; i++) runes[rnd.nextInt(runes.length)],
      ]);
      String digits(int n) =>
          [for (var i = 0; i < n; i++) rnd.nextInt(10)].join();
      final pieces = <String Function()>[
        () => digits(6 + rnd.nextInt(14)),
        () => '${noise(5)}@${noise(4)}.com',
        () => 'a${digits(3)}@mail.example.org',
        () => '@${noise(1 + rnd.nextInt(8))}',
        () => 'https://h.test/${noise(10)}',
        () => List.generate(
          28 + rnd.nextInt(10),
          (_) => 'aZ09'[rnd.nextInt(4)],
        ).join(),
        () => noise(rnd.nextInt(40)),
      ];
      for (var i = 0; i < 2000; i++) {
        final input = [
          for (var j = 0; j < 1 + rnd.nextInt(12); j++)
            pieces[rnd.nextInt(pieces.length)](),
        ].join(rnd.nextBool() ? ' ' : '');
        final out = CrashScrubber.scrub(input);
        _expectSafe(out);
        // Scrubbing twice changes nothing more.
        expect(CrashScrubber.scrub(out), out);
      }
    });
  });
}
